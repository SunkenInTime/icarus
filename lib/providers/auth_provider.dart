import 'dart:async';
import 'dart:developer';

import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/cloud_startup.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/auth_callback_uri.dart';
import 'package:icarus/services/guarded_sign_out.dart';
import 'package:icarus/services/product_metrics.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final authProvider =
    NotifierProvider<AuthProvider, AppAuthState>(AuthProvider.new);

enum ConvexAuthStatus {
  signedOut,
  configuring,
  ready,

  /// Signed in, but the cloud can't be reached (no network, or the server
  /// is down). The session itself is fine: setup retries by itself, and the
  /// library shows what this computer kept of the cloud.
  offline,
  incident,
}

/// Signed in, and the cloud is out of reach for network reasons. Cloud
/// reads should go to this computer's copy instead of waiting to time out.
final cloudOfflineProvider = Provider<bool>((ref) {
  return ref.watch(
    authProvider.select(
      (auth) =>
          auth.isAuthenticated &&
          auth.user?.id != null &&
          auth.convexAuthStatus == ConvexAuthStatus.offline,
    ),
  );
});

const _sensitiveAuthKeys = {
  'access_token',
  'refresh_token',
  'provider_token',
  'provider_refresh_token',
  'code',
  'code_verifier',
};

bool isConvexUnauthenticatedError(Object error) {
  return isTypedConvexUnauthenticatedError(error);
}

/// Credentials a deep link can carry besides [_sensitiveAuthKeys]: a legacy
/// share link's `?token=`. (A share `?code=` is already covered.)
const _sensitiveLinkKeys = {..._sensitiveAuthKeys, 'token'};

/// [uri] safe to log: sign-in secrets and share codes (query, fragment, and
/// the `/share/<code>` path) replaced with `<redacted>`. A share code is a
/// credential: anyone holding it can redeem the shared strategy or folder.
String redactDeepLinkUri(Uri uri) {
  Map<String, String> redactParameters(Map<String, String> params) => {
        for (final entry in params.entries)
          entry.key: _sensitiveLinkKeys.contains(entry.key.toLowerCase())
              ? '<redacted>'
              : entry.value,
      };

  String? redactFragment(String fragment) {
    if (fragment.isEmpty) {
      return null;
    }
    try {
      final params = Uri.splitQueryString(fragment);
      if (params.isEmpty) {
        return '<redacted>';
      }
      final hasSecret = params.keys
          .any((key) => _sensitiveLinkKeys.contains(key.toLowerCase()));
      // Leave a harmless fragment (a Flutter `#/route`) exactly as it was.
      return hasSecret
          ? Uri(queryParameters: redactParameters(params)).query
          : fragment;
    } on FormatException {
      return '<redacted>';
    }
  }

  Map<String, String>? redactQuery() {
    if (!uri.hasQuery) {
      return null;
    }
    try {
      final params = uri.queryParameters;
      return params.isEmpty ? null : redactParameters(params);
    } on FormatException {
      return const {'<redacted>': ''};
    }
  }

  // Everything after a `share` segment (or in an `icarus://share/…` path)
  // is the code.
  final List<String> segments;
  try {
    segments = uri.pathSegments;
  } on FormatException {
    // A path that does not decode (e.g. `/share/%FF`) cannot be redacted
    // piece by piece, so none of it is logged.
    return unparseableLinkPlaceholder;
  }
  var afterShare =
      uri.scheme.toLowerCase() == 'icarus' && uri.host.toLowerCase() == 'share';
  final pathSegments = <String>[];
  for (final segment in segments) {
    pathSegments.add(afterShare ? '<redacted>' : segment);
    afterShare = afterShare || segment.toLowerCase() == 'share';
  }

  return uri
      .replace(
        pathSegments: segments.isEmpty ? null : pathSegments,
        queryParameters: redactQuery(),
        fragment: redactFragment(uri.fragment),
      )
      .toString();
}

/// Logged in place of a link that cannot be parsed or decoded.
const unparseableLinkPlaceholder = '<unparseable link>';

/// A launch argument safe to log. Anything shaped like a link goes through
/// [redactDeepLinkUri] (or becomes [unparseableLinkPlaceholder] if it does not
/// parse); anything else, such as a file path, is logged as is.
String redactLaunchArgument(String argument) {
  final looksLikeLink = argument.contains('://') ||
      argument.trimLeft().toLowerCase().startsWith('icarus:');
  if (!looksLikeLink) {
    return argument;
  }
  final uri = Uri.tryParse(argument.trim());
  return uri == null ? unparseableLinkPlaceholder : redactDeepLinkUri(uri);
}

String redactAuthDiagnosticText(Object value) {
  var redacted = value.toString();

  for (final key in _sensitiveAuthKeys) {
    final escapedKey = RegExp.escape(key);
    final keyValuePattern = RegExp(
      "([\"']?$escapedKey[\"']?\\s*(?:=|:)\\s*)([\"']?)"
      "([^&#,;\\s}\\]\"']+)([\"']?)",
      caseSensitive: false,
    );
    redacted = redacted.replaceAllMapped(
      keyValuePattern,
      (match) => '${match.group(1)}${match.group(2)}'
          '<redacted>${match.group(4)}',
    );

    final encodedKeyValuePattern = RegExp(
      '($escapedKey%3D)(.*?)(?=%26|\\s|\$)',
      caseSensitive: false,
    );
    redacted = redacted.replaceAllMapped(
      encodedKeyValuePattern,
      (match) => '${match.group(1)}%3Credacted%3E',
    );
  }

  return redacted;
}

class AppAuthState {
  const AppAuthState({
    required this.isLoading,
    required this.isAuthenticated,
    required this.isConvexUserReady,
    required this.convexAuthStatus,
    required this.user,
    this.errorMessage,
    this.activeAuthIncidentId,
    this.lastAuthIncidentSource,
    this.isAuthIncidentPromptOpen = false,
  });

  factory AppAuthState.fromSession(
    Session? session, {
    bool isLoading = false,
    bool isConvexUserReady = false,
    ConvexAuthStatus? convexAuthStatus,
    String? errorMessage,
    int? activeAuthIncidentId,
    String? lastAuthIncidentSource,
    bool isAuthIncidentPromptOpen = false,
  }) {
    final status = convexAuthStatus ??
        (session == null
            ? ConvexAuthStatus.signedOut
            : (isConvexUserReady
                ? ConvexAuthStatus.ready
                : ConvexAuthStatus.configuring));

    return AppAuthState(
      isLoading: isLoading,
      isAuthenticated: session != null,
      isConvexUserReady: session != null && isConvexUserReady,
      convexAuthStatus: status,
      user: session?.user,
      errorMessage: errorMessage,
      activeAuthIncidentId: activeAuthIncidentId,
      lastAuthIncidentSource: lastAuthIncidentSource,
      isAuthIncidentPromptOpen: isAuthIncidentPromptOpen,
    );
  }

  final bool isLoading;
  final bool isAuthenticated;
  final bool isConvexUserReady;
  final ConvexAuthStatus convexAuthStatus;
  final User? user;
  final String? errorMessage;
  final int? activeAuthIncidentId;
  final String? lastAuthIncidentSource;
  final bool isAuthIncidentPromptOpen;

  bool get hasActiveAuthIncident => activeAuthIncidentId != null;

  String get displayName {
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    // Metadata values are user/provider controlled — tolerate non-string
    // entries instead of crashing the widget build.
    String? stringEntry(String key) {
      final value = metadata[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final name = stringEntry('full_name') ??
        stringEntry('name') ??
        stringEntry('user_name') ??
        user?.email;
    return (name?.isNotEmpty ?? false) ? name! : 'Discord user';
  }

  String? get avatarUrl {
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    final value = metadata['avatar_url'];
    return value is String && value.isNotEmpty ? value : null;
  }

  AppAuthState copyWith({
    bool? isLoading,
    bool? isAuthenticated,
    bool? isConvexUserReady,
    ConvexAuthStatus? convexAuthStatus,
    User? user,
    String? errorMessage,
    bool clearError = false,
    int? activeAuthIncidentId,
    bool clearAuthIncident = false,
    String? lastAuthIncidentSource,
    bool clearLastAuthIncidentSource = false,
    bool? isAuthIncidentPromptOpen,
  }) {
    return AppAuthState(
      isLoading: isLoading ?? this.isLoading,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      isConvexUserReady: isConvexUserReady ?? this.isConvexUserReady,
      convexAuthStatus: convexAuthStatus ?? this.convexAuthStatus,
      user: user ?? this.user,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      activeAuthIncidentId: clearAuthIncident
          ? null
          : (activeAuthIncidentId ?? this.activeAuthIncidentId),
      lastAuthIncidentSource: clearLastAuthIncidentSource
          ? null
          : (lastAuthIncidentSource ?? this.lastAuthIncidentSource),
      isAuthIncidentPromptOpen:
          isAuthIncidentPromptOpen ?? this.isAuthIncidentPromptOpen,
    );
  }
}

enum _AuthIncidentAction {
  retry,
  signOut,
  dismiss,
}

abstract class AuthProviderAuthHandle {
  void dispose();
}

abstract class AuthProviderConvexApi {
  Future<AuthProviderAuthHandle> setAuthWithRefresh({
    required Future<String?> Function() fetchToken,
    void Function(bool isAuthenticated)? onAuthChange,
  });

  Stream<bool> get authState;
  bool get isAuthenticated;
  String? get currentConnectionStateLabel;

  /// Whether the Convex socket is connected right now.
  bool get isConnected;

  /// Each change of [isConnected].
  Stream<bool> get connectedChanges;
  Future<void> clearAuth();
  Future<bool> reconnect();
  Future<void> ensureCurrentUser();
}

abstract class AuthProviderSupabaseApi {
  Session? get currentSession;
  Stream<AuthState> get onAuthStateChange;

  Future<bool> signInWithOAuth(
    OAuthProvider provider, {
    required String redirectTo,
    required LaunchMode authScreenLaunchMode,
    required String scopes,
  });

  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  });

  Future<AuthResponse> signUp({
    required String email,
    required String password,
  });

  Future<void> signOut();
  Future<void> getSessionFromUrl(Uri uri);
  Future<AuthResponse> refreshSession();
}

class _DefaultAuthProviderAuthHandle implements AuthProviderAuthHandle {
  _DefaultAuthProviderAuthHandle(this._inner);

  final AuthHandleWrapper _inner;

  @override
  void dispose() => _inner.dispose();
}

class _DefaultAuthProviderConvexApi implements AuthProviderConvexApi {
  const _DefaultAuthProviderConvexApi();

  ConvexClient get _client => ConvexClient.instance;

  @override
  Future<AuthProviderAuthHandle> setAuthWithRefresh({
    required Future<String?> Function() fetchToken,
    void Function(bool p1)? onAuthChange,
  }) async {
    final handle = await _client.setAuthWithRefresh(
      fetchToken: fetchToken,
      onAuthChange: onAuthChange,
    );
    return _DefaultAuthProviderAuthHandle(handle);
  }

  @override
  Stream<bool> get authState => _client.authState;

  @override
  bool get isAuthenticated => _client.isAuthenticated;

  @override
  String? get currentConnectionStateLabel =>
      _client.currentConnectionState.name;

  @override
  bool get isConnected => _client.isConnected;

  @override
  Stream<bool> get connectedChanges => _client.connectionState
      .map((state) => state == WebSocketConnectionState.connected);

  @override
  Future<void> clearAuth() => _client.clearAuth();

  @override
  Future<bool> reconnect() => _client.reconnect();

  @override
  Future<void> ensureCurrentUser() async {
    await ConvexStrategyRepository.fromClient(_client).ensureCurrentUser();
  }
}

class _DefaultAuthProviderSupabaseApi implements AuthProviderSupabaseApi {
  const _DefaultAuthProviderSupabaseApi();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Session? get currentSession => _client.auth.currentSession;

  @override
  Stream<AuthState> get onAuthStateChange => _client.auth.onAuthStateChange;

  @override
  Future<bool> signInWithOAuth(
    OAuthProvider provider, {
    required String redirectTo,
    required LaunchMode authScreenLaunchMode,
    required String scopes,
  }) {
    return _client.auth.signInWithOAuth(
      provider,
      redirectTo: redirectTo,
      authScreenLaunchMode: authScreenLaunchMode,
      scopes: scopes,
    );
  }

  @override
  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) {
    return _client.auth.signUp(email: email, password: password);
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  @override
  Future<void> getSessionFromUrl(Uri uri) =>
      _client.auth.getSessionFromUrl(uri);

  @override
  Future<AuthResponse> refreshSession() => _client.auth.refreshSession();
}

/// Supabase in a run where cloud sync did not start: nobody is signed in,
/// and every sign-in fails with the reason, which the sign-in dialog shows.
class _UnavailableAuthProviderSupabaseApi implements AuthProviderSupabaseApi {
  const _UnavailableAuthProviderSupabaseApi(this.reason);

  final String reason;

  Future<Never> _refuse() => Future.error(CloudUnavailableException(reason));

  @override
  Session? get currentSession => null;

  @override
  Stream<AuthState> get onAuthStateChange => const Stream.empty();

  @override
  Future<bool> signInWithOAuth(
    OAuthProvider provider, {
    required String redirectTo,
    required LaunchMode authScreenLaunchMode,
    required String scopes,
  }) =>
      _refuse();

  @override
  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) =>
      _refuse();

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) =>
      _refuse();

  @override
  Future<void> signOut() => _refuse();

  @override
  Future<void> getSessionFromUrl(Uri uri) => _refuse();

  @override
  Future<AuthResponse> refreshSession() => _refuse();
}

/// The redirect this build asks Supabase to return to after Discord sign-in:
/// the `icarus://` deep link on desktop, the page's own origin on web.
Uri currentAuthRedirectUri() {
  return kIsWeb ? webAuthRedirectUri(Uri.base) : nativeAuthRedirectUri;
}

class AuthProvider extends Notifier<AppAuthState> {
  StreamSubscription<AuthState>? _supabaseAuthSub;
  AuthProviderAuthHandle? _convexAuthHandle;

  /// Whether this run ever gave Convex a token. Until it has, there is no
  /// auth to clear, and clearing it would open the Convex socket for a
  /// signed-out user who never asked for the cloud.
  bool _convexMayHoldAuth = false;
  Future<void>? _inFlightConvexSetup;
  bool _queuedConvexSetup = false;
  bool _disposed = false;
  String? _queuedConvexTrigger;
  bool _showingIncidentPrompt = false;
  int _incidentCounter = 0;
  int _authGeneration = 0;

  /// Counts sign-ins, so a sign-out still finishing when someone signs in
  /// again can tell, and leaves the new session alone.
  int _signIns = 0;

  /// The session [build] started Convex setup for.
  String? _buildSessionFingerprint;

  @visibleForTesting
  static AuthProviderSupabaseApi? debugSupabaseApi;

  @visibleForTesting
  static AuthProviderConvexApi? debugConvexApi;

  @visibleForTesting
  static Duration? debugConvexAuthReadyTimeout;

  @visibleForTesting
  static Duration? debugReconnectTimeout;

  @visibleForTesting
  static Duration Function(int attempt)? debugOfflineRetryDelay;

  /// While offline: the next timed retry, how many have run, and the
  /// connection listener that retries the moment the socket is back.
  Timer? _offlineRetryTimer;
  int _offlineRetryAttempts = 0;

  /// Retries that reached a connected server which then didn't confirm the
  /// session in time. A server that has just come back can be slow to; past
  /// [_maxSlowServerRetries] the session is treated as refused, as today.
  int _slowServerRetries = 0;
  static const _maxSlowServerRetries = 3;

  /// Whether Supabase's last token refresh couldn't reach it. Convex can't
  /// confirm a session whose token can't be refreshed, so a timeout then is
  /// the outage, not a refusal, however many times it repeats. Any word
  /// from Supabase (a new session, a refresh) ends it.
  bool _supabaseUnreachable = false;
  StreamSubscription<bool>? _offlineConnectionSub;

  late final AuthProviderSupabaseApi _supabaseApi;
  late final AuthProviderConvexApi _convexApi;

  @visibleForTesting
  static void resetTestOverrides() {
    debugSupabaseApi = null;
    debugConvexApi = null;
    debugConvexAuthReadyTimeout = null;
    debugReconnectTimeout = null;
    debugOfflineRetryDelay = null;
  }

  /// How long an offline session waits before setup tries again: 5 s,
  /// doubling to a minute.
  static Duration offlineRetryDelay(int attempt) {
    final debugDelay = debugOfflineRetryDelay;
    if (debugDelay != null) return debugDelay(attempt);
    final seconds = 5 * (1 << attempt.clamp(0, 4));
    return Duration(seconds: seconds > 60 ? 60 : seconds);
  }

  int _advanceAuthGeneration() {
    _authGeneration += 1;
    return _authGeneration;
  }

  String _sessionFingerprint(Session? session) {
    if (session == null) {
      return 'signed_out';
    }

    return '${session.user.id}:${session.accessToken}';
  }

  bool _isAuthContextCurrent({
    required int generation,
    required String sessionFingerprint,
  }) {
    return generation == _authGeneration &&
        _sessionFingerprint(_supabaseApi.currentSession) == sessionFingerprint;
  }

  @override
  AppAuthState build() {
    final cloudUnavailableReason =
        ref.read(cloudStartupProvider).unavailableReason;
    _supabaseApi = debugSupabaseApi ??
        (cloudUnavailableReason == null
            ? const _DefaultAuthProviderSupabaseApi()
            : _UnavailableAuthProviderSupabaseApi(cloudUnavailableReason));
    _convexApi = debugConvexApi ?? const _DefaultAuthProviderConvexApi();
    final session = _supabaseApi.currentSession;
    final initialGeneration = _advanceAuthGeneration();
    _buildSessionFingerprint = _sessionFingerprint(session);

    _supabaseAuthSub ??= _supabaseApi.onAuthStateChange.listen(
      _handleSupabaseAuthStateChange,
      onError: _handleSupabaseAuthStreamError,
    );

    ref.onDispose(() {
      _supabaseAuthSub?.cancel();
      _convexAuthHandle?.dispose();
      _stopOfflineRetries();
      // A setup still running, or queued behind it, belongs to a provider
      // that is gone: it must finish without reading or changing anything.
      _disposed = true;
      _queuedConvexSetup = false;
      _advanceAuthGeneration();
    });
    // Retries belong to the offline state only; any way out of it (ready,
    // signed out, an incident) ends them.
    listenSelf((previous, next) {
      if (next.convexAuthStatus != ConvexAuthStatus.offline) {
        _stopOfflineRetries();
      }
      if (next.convexAuthStatus == ConvexAuthStatus.ready) {
        _supabaseUnreachable = false;
      }
      // The signed-in account changed: signed out here, signed out by
      // Supabase (a revoked or expired refresh token), another account, or
      // a sign-in. Whatever the account that ended kept goes, and its late
      // answers can't write it back.
      final previousAccountId = previous?.user?.id;
      // (The first state, with no previous one, is the startup sweep's.)
      if (previous != null && previousAccountId != next.user?.id) {
        if (previousAccountId != null) _endCopySessions(previousAccountId);
        unawaited(_keepOnlyAccountCopies(next.user?.id));
      }
    });
    // The server accepts this build again (a rolled-back deploy): the
    // setup it refused can now succeed.
    ref.listen<bool>(clientUpgradeRequiredProvider, (previous, next) {
      if (previous == true &&
          !next &&
          state.convexAuthStatus == ConvexAuthStatus.incident) {
        unawaited(reinitializeConvexAuth(source: 'protocol_accepted'));
      }
    });

    Future<void>.microtask(() async {
      await _configureConvexAuth(
        trigger: 'build',
        generation: initialGeneration,
        sessionFingerprint: _buildSessionFingerprint,
      );
    });
    // The account is known from the session Supabase restored from disk,
    // offline too: finish any deletion a crash interrupted last time.
    Future<void>.microtask(() => _keepOnlyAccountCopies(session?.user.id));

    return AppAuthState.fromSession(
      session,
      isConvexUserReady: false,
      convexAuthStatus: session == null
          ? ConvexAuthStatus.signedOut
          : ConvexAuthStatus.configuring,
    );
  }

  void _handleSupabaseAuthStateChange(AuthState event) {
    _supabaseUnreachable = false;
    final currentSession = event.session;
    // Supabase replays the session it restored at startup to every new
    // listener as `initialSession`. [build] already started Convex setup for
    // that session; a second setup would tear down the first one's auth under
    // the library's live queries.
    if (event.event == AuthChangeEvent.initialSession &&
        _sessionFingerprint(currentSession) == _buildSessionFingerprint) {
      return;
    }

    final generation = _advanceAuthGeneration();
    state = AppAuthState.fromSession(
      currentSession,
      isLoading: false,
      isConvexUserReady: false,
      convexAuthStatus: currentSession == null
          ? ConvexAuthStatus.signedOut
          : ConvexAuthStatus.configuring,
    );

    if (currentSession == null) {
      _clearAuthIncident();
    }
    if (event.event == AuthChangeEvent.signedIn) _signIns++;

    unawaited(
      _configureConvexAuth(
        trigger: 'supabase:${event.event}',
        generation: generation,
        sessionFingerprint: _sessionFingerprint(currentSession),
      ),
    );
  }

  void _handleSupabaseAuthStreamError(Object error, StackTrace stackTrace) {
    log(
      'Supabase auth state stream error: $error',
      name: 'auth',
      error: error,
      stackTrace: stackTrace,
    );

    // The token refresh couldn't reach Supabase (offline, or Supabase is
    // down): nothing judged the session, and Supabase tries the refresh
    // again by itself. Setting up is out of reach, so it is offline and
    // retries; a session already offline stays so; any other state is left
    // as it is. Only a real refusal is an incident.
    if (!kIsWeb &&
        _supabaseApi.currentSession?.user.id != null &&
        (error is AuthRetryableFetchException || error is TimeoutException)) {
      _supabaseUnreachable = true;
      if (state.convexAuthStatus == ConvexAuthStatus.configuring) {
        _enterOffline();
      }
      return;
    }

    state = state.copyWith(
      isLoading: false,
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.incident,
      errorMessage: 'Auth stream error: $error',
    );
  }

  Future<void> signInWithDiscord() async {
    state = state.copyWith(
      isLoading: true,
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.configuring,
      clearError: true,
    );

    try {
      final launched = await _supabaseApi.signInWithOAuth(
        OAuthProvider.discord,
        redirectTo: currentAuthRedirectUri().toString(),
        authScreenLaunchMode: LaunchMode.externalApplication,
        scopes: 'identify email',
      );

      if (!launched) {
        throw StateError('Discord OAuth browser launch failed');
      }
    } catch (error, stackTrace) {
      log(
        'Discord sign-in failed: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: error is CloudUnavailableException
            ? error.message
            : 'Discord sign-in failed: $error',
      );
      ProductMetrics.instance.signIn(method: 'discord', succeeded: false);
      return;
    }

    state = state.copyWith(isLoading: false);
  }

  Future<String?> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    state = state.copyWith(
      isLoading: true,
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.configuring,
      clearError: true,
    );

    try {
      final response = await _supabaseApi.signInWithPassword(
        email: email,
        password: password,
      );

      if (response.session == null) {
        const message = "Sign in didn't complete. Please try again.";
        state = state.copyWith(
          isLoading: false,
          isConvexUserReady: false,
          convexAuthStatus: ConvexAuthStatus.incident,
          errorMessage: message,
        );
        ProductMetrics.instance.signIn(method: 'email', succeeded: false);
        return message;
      }

      state = state.copyWith(isLoading: false);
      return null;
    } catch (error, stackTrace) {
      log(
        'Email/password sign-in failed: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      final message = _friendlySignInError(error);
      state = state.copyWith(
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: message,
      );
      ProductMetrics.instance.signIn(method: 'email', succeeded: false);
      return message;
    }
  }

  static String _friendlySignInError(Object error) {
    if (error is CloudUnavailableException) return error.message;
    final message = error.toString().toLowerCase();
    if (message.contains('invalid login credentials') ||
        message.contains('invalid_credentials')) {
      return 'Incorrect email or password.';
    }
    if (message.contains('email not confirmed')) {
      return 'Confirm your email first — check your inbox for the '
          'confirmation link.';
    }
    if (message.contains('rate limit') || message.contains('too many')) {
      return 'Too many attempts. Wait a moment and try again.';
    }
    if (message.contains('socket') ||
        message.contains('network') ||
        message.contains('timed out') ||
        message.contains('failed host lookup')) {
      return "Couldn't reach the server. Check your connection and try again.";
    }
    return 'Sign in failed. Please try again.';
  }

  static String _friendlySignUpError(Object error) {
    if (error is CloudUnavailableException) return error.message;
    final message = error.toString().toLowerCase();
    if (message.contains('already registered') ||
        message.contains('already exists')) {
      return 'An account with this email already exists. Try signing in '
          'instead.';
    }
    // Supabase hit its project-wide email limit or its mail server failed.
    // No account is created until the confirmation email goes out, and
    // waiting "a moment" doesn't bring the limit back, so say so.
    if (message.contains('over_email_send_rate_limit') ||
        message.contains('error sending confirmation email')) {
      return "We couldn't send your confirmation email right now. Try again "
          'later, or continue with Discord.';
    }
    if (message.contains('rate limit') || message.contains('too many')) {
      return 'Too many attempts. Wait a moment and try again.';
    }
    if (message.contains('socket') ||
        message.contains('network') ||
        message.contains('timed out') ||
        message.contains('failed host lookup')) {
      return "Couldn't reach the server. Check your connection and try again.";
    }
    return 'Sign up failed. Please try again.';
  }

  Future<String?> signUpWithEmailPassword({
    required String email,
    required String password,
  }) async {
    state = state.copyWith(
      isLoading: true,
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.configuring,
      clearError: true,
    );

    try {
      final response = await _supabaseApi.signUp(
        email: email,
        password: password,
      );

      // Supabase answers a sign-up for an email that already has an account
      // with success, sends no email, and returns a user with no identities,
      // so strangers can't probe which emails are registered. The account
      // may have been made with Discord, so name both ways back in.
      if (response.user?.identities?.isEmpty ?? false) {
        const message = 'An account with this email already exists. Sign in '
            'instead, or continue with Discord if you signed up that way.';
        state = state.copyWith(
          isLoading: false,
          isConvexUserReady: false,
          convexAuthStatus: ConvexAuthStatus.signedOut,
          errorMessage: message,
        );
        ProductMetrics.instance.signUp('already_registered');
        return message;
      }

      if (response.session == null) {
        const message =
            'Account created! Check your inbox for the confirmation link, '
            'then sign in.';
        state = state.copyWith(
          isLoading: false,
          isConvexUserReady: false,
          convexAuthStatus: ConvexAuthStatus.signedOut,
          errorMessage: message,
        );
        ProductMetrics.instance.signUp('confirmation_sent');
        return message;
      }

      state = state.copyWith(isLoading: false);
      ProductMetrics.instance.signUp('signed_in');
      return null;
    } catch (error, stackTrace) {
      log(
        'Email/password sign-up failed: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      final message = _friendlySignUpError(error);
      state = state.copyWith(
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: message,
      );
      ProductMetrics.instance.signUp('failed');
      return message;
    }
  }

  Future<void> signOut() async {
    final signedOutAccountId = state.user?.id;
    // Supabase reports the sign-out before its request finishes, and the
    // user can sign in again meanwhile. Then the rest of this belongs to a
    // session that is over, and must touch nothing of the new one.
    final signIns = _signIns;
    bool signedInAgain() => _signIns != signIns;
    // Invalidate any setup that is currently awaiting a Convex auth handle
    // before the Supabase auth-state event has a chance to arrive. Otherwise a
    // stale setup can resume during sign-out and surface a false auth incident.
    _advanceAuthGeneration();
    state = state.copyWith(
      isLoading: true,
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.signedOut,
      clearError: true,
      clearAuthIncident: true,
      clearLastAuthIncidentSource: true,
      isAuthIncidentPromptOpen: false,
    );

    try {
      await _supabaseApi.signOut();
      if (signedInAgain()) return;
      // Signed out of Supabase: the account is gone from this computer even
      // if a later step fails.
      if (signedOutAccountId != null) _endCopySessions(signedOutAccountId);
      await _keepOnlyAccountCopies(null);
      if (signedInAgain()) return;
      _convexAuthHandle?.dispose();
      _convexAuthHandle = null;
      await _convexApi.clearAuth();
      if (signedInAgain()) return;
      state = AppAuthState.fromSession(
        null,
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
      );
    } catch (error, stackTrace) {
      log(
        'Sign out failed: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      if (signedInAgain()) return;
      state = state.copyWith(
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: 'Sign out failed. Please try again.',
      );
      return;
    }

    try {
      Settings.showToast(
        message: ref.read(platformPolicyProvider).allowsLocalLibrary
            ? 'Signed out. Your local strategies stay on this device.'
            : 'Signed out.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    } catch (error, stackTrace) {
      log(
        'Signed out, but the confirmation toast could not be shown: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Ends [accountId]'s copy sessions, at once and before anything else
  /// runs: an answer its live queries receive after this can no longer
  /// write its copy back.
  void _endCopySessions(String accountId) {
    CloudCopyScope(
      deploymentUrl: ref.read(cloudCopyDeploymentUrlProvider),
      accountId: accountId,
    ).endSessions();
  }

  /// Keeps on this computer only [accountId]'s copy of its cloud library,
  /// or none when signed out (null), so a signed-out computer doesn't keep
  /// someone's library. Unsent work stays in its outboxes, and image files
  /// are never touched. A copy that can't be deleted is reported, never a
  /// reason a sign-out fails.
  Future<void> _keepOnlyAccountCopies(String? accountId) async {
    final keep = accountId == null
        ? null
        : CloudCopyScope(
            deploymentUrl: ref.read(cloudCopyDeploymentUrlProvider),
            accountId: accountId,
          );
    for (final copy in ref.read(cloudAccountCopiesProvider)) {
      try {
        await copy.deleteAllExcept(keep);
      } catch (error, stackTrace) {
        AppErrorReporter.reportWarning(
          "This computer's copy of a cloud library that isn't signed in "
          "couldn't be deleted",
          source: 'auth',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// Returns true when [uri] was an auth callback, including one rejected for
  /// carrying session tokens, so the caller can scrub it from the address bar.
  Future<bool> handleAuthCallbackUri(Uri uri, {required String source}) async {
    switch (
        classifyAuthCallbackUri(uri, redirectUri: currentAuthRedirectUri())) {
      case AuthCallback.none:
        AppErrorReporter.reportInfo(
          'Deep link was not an auth callback [$source]: ${redactDeepLinkUri(uri)}',
          source: 'auth',
        );
        return false;
      case AuthCallback.injectedTokens:
        AppErrorReporter.reportInfo(
          'Rejected auth callback carrying session tokens [$source]: '
          '${redactDeepLinkUri(uri)}',
          source: 'auth',
        );
        return true;
      case AuthCallback.signInResult:
        break;
    }

    AppErrorReporter.reportInfo(
      'Handling auth callback [$source]: ${redactDeepLinkUri(uri)}',
      source: 'auth',
    );

    state = state.copyWith(
      isLoading: true,
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.configuring,
      clearError: true,
    );

    try {
      await _supabaseApi.getSessionFromUrl(uri);
      state = state.copyWith(isLoading: false);
      log(
        'Handled auth callback [$source]: ${redactDeepLinkUri(uri)}',
        name: 'auth',
      );
      AppErrorReporter.reportInfo(
        'Handled auth callback [$source]',
        source: 'auth',
      );
      return true;
    } catch (error, stackTrace) {
      final safeError = redactAuthDiagnosticText(error);
      final safeStackTrace = StackTrace.fromString(
        redactAuthDiagnosticText(stackTrace),
      );
      log(
        'Failed auth callback [$source]: $safeError',
        name: 'auth',
        error: safeError,
        stackTrace: safeStackTrace,
      );
      AppErrorReporter.reportError(
        'Failed auth callback [$source]: ${redactDeepLinkUri(uri)}',
        source: 'auth',
        error: safeError,
        stackTrace: safeStackTrace,
      );
      state = state.copyWith(
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: 'Failed to complete login. Please try again.',
      );
      ProductMetrics.instance.signIn(method: 'discord', succeeded: false);
      return true;
    }
  }

  Future<String?> _fetchSupabaseAccessToken() async {
    try {
      final session = _supabaseApi.currentSession;
      if (session == null) {
        log(
          'Convex token fetch skipped: no active Supabase session.',
          name: 'auth',
        );
        return null;
      }

      final expiresAt = session.expiresAt;
      if (expiresAt != null) {
        final expiresAtUtc = DateTime.fromMillisecondsSinceEpoch(
          expiresAt * 1000,
          isUtc: true,
        );
        final shouldRefresh = expiresAtUtc
            .isBefore(DateTime.now().toUtc().add(const Duration(minutes: 1)));

        if (shouldRefresh) {
          try {
            final refreshed = await _supabaseApi.refreshSession();
            final refreshedToken = refreshed.session?.accessToken;
            if (refreshedToken != null && refreshedToken.isNotEmpty) {
              log(
                'Convex token fetch returning refreshed Supabase token.',
                name: 'auth',
              );
              return refreshedToken;
            }
          } catch (error, stackTrace) {
            log(
              'Supabase refresh failed while fetching Convex token: $error',
              name: 'auth',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
      }

      log(
        'Convex token fetch returning current Supabase token '
        '(nonEmpty: ${session.accessToken.isNotEmpty}).',
        name: 'auth',
      );
      return session.accessToken;
    } catch (error, stackTrace) {
      log(
        'Failed fetching Supabase access token for Convex: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> reinitializeConvexAuth({String source = 'manual'}) async {
    await _configureConvexAuth(trigger: 'reinitialize:$source');
  }

  /// Signed in, but setup failed because the cloud is out of reach. Setup
  /// tries again when the socket connects, and on a timer that backs off
  /// from 5 s to a minute.
  void _enterOffline() {
    state = state.copyWith(
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.offline,
      clearError: true,
    );
    _offlineConnectionSub ??= _convexApi.connectedChanges.listen(
      (connected) {
        if (connected) _retryOffline('connected');
      },
      onError: (Object _) {},
    );
    _offlineRetryTimer?.cancel();
    _offlineRetryTimer = Timer(
      // Connected already: the server is back but was slow to confirm the
      // session, so ask again soon rather than back off.
      _convexApi.isConnected
          ? offlineRetryDelay(0) * 0.4
          : offlineRetryDelay(_offlineRetryAttempts++),
      () => _retryOffline('timer'),
    );
  }

  void _retryOffline(String reason) {
    if (_disposed || state.convexAuthStatus != ConvexAuthStatus.offline) {
      return;
    }
    // A setup already running ends ready, or offline with the next timer.
    if (_inFlightConvexSetup != null) return;
    _offlineRetryTimer?.cancel();
    _offlineRetryTimer = null;
    unawaited(_configureConvexAuth(trigger: 'offline_retry:$reason'));
  }

  void _stopOfflineRetries() {
    _offlineRetryTimer?.cancel();
    _offlineRetryTimer = null;
    _offlineConnectionSub?.cancel();
    _offlineConnectionSub = null;
    _offlineRetryAttempts = 0;
    _slowServerRetries = 0;
  }

  /// Whether a setup failure came from the cloud being out of reach, not
  /// from anything the server said: the socket is down, and the error is
  /// not a server function's answer.
  bool _isOfflineFailure(Object error) {
    if (error is _ConvexUnreachable) return true;
    if (isConvexFunctionError(error)) return false;
    return !_convexApi.isConnected;
  }

  Future<void> reportConvexUnauthenticated({
    required String source,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    if (error != null && !isConvexUnauthenticatedError(error)) {
      return;
    }

    if (_supabaseApi.currentSession == null) {
      return;
    }

    if (state.activeAuthIncidentId != null) {
      return;
    }

    final incidentId = ++_incidentCounter;
    state = state.copyWith(
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.incident,
      activeAuthIncidentId: incidentId,
      lastAuthIncidentSource: source,
      errorMessage:
          'Your cloud session expired. Reconnect to resume syncing, or '
          'sign out.',
    );

    log(
      'Convex unauthenticated incident #$incidentId from $source: ${error ?? 'no error payload'}',
      name: 'auth',
      error: error,
      stackTrace: stackTrace,
    );

    unawaited(_showAuthIncidentPrompt(incidentId));
  }

  Future<void> _configureConvexAuth({
    required String trigger,
    int? generation,
    String? sessionFingerprint,
  }) async {
    await Future<void>.value();
    if (_disposed) return;

    final targetGeneration = generation ?? _authGeneration;
    final targetFingerprint =
        sessionFingerprint ?? _sessionFingerprint(_supabaseApi.currentSession);

    if (_inFlightConvexSetup != null) {
      _queuedConvexSetup = true;
      _queuedConvexTrigger = trigger;
      await _inFlightConvexSetup;
      return;
    }

    final completer = Completer<void>();
    _inFlightConvexSetup = completer.future;

    try {
      await _runConvexAuthSetup(
        trigger: trigger,
        generation: targetGeneration,
        sessionFingerprint: targetFingerprint,
      );
    } finally {
      completer.complete();
      _inFlightConvexSetup = null;

      if (_queuedConvexSetup && !_disposed) {
        _queuedConvexSetup = false;
        final queuedTrigger = _queuedConvexTrigger ?? 'queued';
        _queuedConvexTrigger = null;
        unawaited(_configureConvexAuth(trigger: queuedTrigger));
      }
    }
  }

  Duration get _convexAuthReadyTimeout =>
      debugConvexAuthReadyTimeout ?? const Duration(seconds: 5);

  Duration get _reconnectTimeout =>
      debugReconnectTimeout ?? const Duration(seconds: 8);

  Future<String> _waitForConvexAuthenticated({
    required String trigger,
    required bool? reconnectResult,
  }) async {
    if (_convexApi.isAuthenticated) {
      return 'immediate';
    }

    final authenticated = await _convexApi.authState
        .firstWhere(
      (isAuthenticated) => isAuthenticated,
    )
        .timeout(
      _convexAuthReadyTimeout,
      onTimeout: () {
        final connectionState = _convexApi.currentConnectionStateLabel;
        throw TimeoutException(
          'Convex auth did not become ready within '
          '${_convexAuthReadyTimeout.inSeconds} seconds '
          'for trigger "$trigger" '
          '(reconnectResult: ${reconnectResult?.toString() ?? 'unknown'}, '
          'isAuthenticated: ${_convexApi.isAuthenticated}, '
          'connectionState: ${connectionState ?? 'unavailable'}).',
        );
      },
    );

    if (!authenticated) {
      throw StateError('Convex auth stream completed without authentication.');
    }

    return 'stream';
  }

  Future<void> _runConvexAuthSetup({
    required String trigger,
    required int generation,
    required String sessionFingerprint,
  }) async {
    final session = _supabaseApi.currentSession;
    if (!_isAuthContextCurrent(
      generation: generation,
      sessionFingerprint: sessionFingerprint,
    )) {
      return;
    }

    log(
      'Starting Convex auth setup [$trigger] (hasSession: ${session != null})',
      name: 'auth',
    );
    if (session == null) {
      _convexAuthHandle?.dispose();
      _convexAuthHandle = null;
      if (_convexMayHoldAuth) {
        await _convexApi.clearAuth();
        _convexMayHoldAuth = false;
      }
      if (!_isAuthContextCurrent(
        generation: generation,
        sessionFingerprint: sessionFingerprint,
      )) {
        return;
      }
      _clearAuthIncident();
      state = AppAuthState.fromSession(
        null,
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
      );
      return;
    }

    // An automatic retry stays offline on screen until it succeeds, so the
    // library doesn't flicker to "connecting" every few seconds.
    final quietRetry = trigger.startsWith('offline_retry:') &&
        state.convexAuthStatus == ConvexAuthStatus.offline;
    state = state.copyWith(
      isLoading: false,
      isAuthenticated: true,
      isConvexUserReady: false,
      convexAuthStatus:
          quietRetry ? ConvexAuthStatus.offline : ConvexAuthStatus.configuring,
      clearError: true,
    );

    try {
      _convexAuthHandle?.dispose();
      final wasAuthenticatedBeforeSetup = _convexApi.isAuthenticated;
      bool? reconnectResult;
      _convexMayHoldAuth = true;
      final authHandle = await _convexApi.setAuthWithRefresh(
        fetchToken: _fetchSupabaseAccessToken,
        onAuthChange: (isAuthenticated) {
          if (!_isAuthContextCurrent(
            generation: generation,
            sessionFingerprint: sessionFingerprint,
          )) {
            return;
          }
          if (isAuthenticated) {
            return;
          }
          if (_supabaseApi.currentSession == null) {
            return;
          }
          // Still setting up, or out of reach: the server hasn't judged
          // the session, so this is no incident.
          if (state.convexAuthStatus == ConvexAuthStatus.configuring ||
              state.convexAuthStatus == ConvexAuthStatus.offline) {
            return;
          }

          unawaited(
            reportConvexUnauthenticated(
              source: 'convex:onAuthChange',
              error: Exception('Convex auth state changed to unauthenticated'),
            ),
          );
        },
      );
      _convexAuthHandle = authHandle;

      if (!_isAuthContextCurrent(
        generation: generation,
        sessionFingerprint: sessionFingerprint,
      )) {
        authHandle.dispose();
        if (identical(_convexAuthHandle, authHandle)) {
          _convexAuthHandle = null;
        }
        return;
      }

      log(
        'Convex auth handle configured [$trigger] (wasAuthenticatedBeforeSetup: '
        '$wasAuthenticatedBeforeSetup, isAuthenticatedNow: ${_convexApi.isAuthenticated})',
        name: 'auth',
      );
      try {
        // Offline, a reconnect waits out the client's whole operation
        // timeout; this decides sooner, and the retries take over.
        reconnectResult = await _convexApi.reconnect().timeout(
              _reconnectTimeout,
              onTimeout: () => false,
            );
        log(
          'Convex reconnect attempted [$trigger] (result: $reconnectResult, '
          'isAuthenticatedAfterReconnect: ${_convexApi.isAuthenticated}, '
          'connectionState: '
          '${_convexApi.currentConnectionStateLabel ?? 'unavailable'})',
          name: 'auth',
        );
      } catch (error, stackTrace) {
        log(
          'Convex reconnect threw [$trigger]: $error',
          name: 'auth',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (reconnectResult == false && !_convexApi.isConnected) {
        throw const _ConvexUnreachable();
      }
      final readinessSource = await _waitForConvexAuthenticated(
        trigger: trigger,
        reconnectResult: reconnectResult,
      );
      if (!_isAuthContextCurrent(
        generation: generation,
        sessionFingerprint: sessionFingerprint,
      )) {
        authHandle.dispose();
        if (identical(_convexAuthHandle, authHandle)) {
          _convexAuthHandle = null;
        }
        return;
      }
      log(
        'Convex auth ready [$trigger] via $readinessSource',
        name: 'auth',
      );
      await _convexApi.ensureCurrentUser();
      if (!_isAuthContextCurrent(
        generation: generation,
        sessionFingerprint: sessionFingerprint,
      )) {
        authHandle.dispose();
        if (identical(_convexAuthHandle, authHandle)) {
          _convexAuthHandle = null;
        }
        return;
      }
      log(
        'Convex current user ensured [$trigger]',
        name: 'auth',
      );

      _clearAuthIncident();
      state = state.copyWith(
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        clearError: true,
      );
      // A fresh sign-in, by either method, reaches here once ready; a
      // session restored at start or a reconnect comes by other triggers.
      if (trigger.contains('signedIn')) {
        final provider = session.user.appMetadata['provider'];
        ProductMetrics.instance.signIn(
          method: provider == 'discord' ? 'discord' : 'email',
          succeeded: true,
        );
      }
    } catch (error, stackTrace) {
      if (!_isAuthContextCurrent(
        generation: generation,
        sessionFingerprint: sessionFingerprint,
      )) {
        return;
      }

      // Desktop only: the web app needs the network to load at all, so a
      // failed setup there stays the incident it always was.
      // Judged by where the session is now, not where it was when this
      // setup began: the session may have gone offline meanwhile (Supabase
      // unreachable), and then a timeout is more of the same.
      final offlineNow = state.convexAuthStatus == ConvexAuthStatus.offline;
      final offlineFailure = !kIsWeb &&
          _supabaseApi.currentSession?.user.id != null &&
          (_isOfflineFailure(error) ||
              (offlineNow &&
                  error is TimeoutException &&
                  (_supabaseUnreachable ||
                      _slowServerRetries++ < _maxSlowServerRetries)));
      // An automatic retry that is still offline was reported when the
      // session first went offline.
      if (!offlineFailure ||
          state.convexAuthStatus != ConvexAuthStatus.offline) {
        AppErrorReporter.reportWarning(
          error is TimeoutException
              ? 'Convex auth readiness timed out [$trigger]'
              : 'Convex auth setup failed [$trigger]',
          source: 'auth',
          error: redactAuthDiagnosticText(error),
          stackTrace:
              StackTrace.fromString(redactAuthDiagnosticText(stackTrace)),
        );
      }

      if (isConvexUnauthenticatedError(error)) {
        await reportConvexUnauthenticated(
          source: 'setup:$trigger',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }

      final upgradeRequired =
          ref.read(clientUpgradeRequiredProvider.notifier).noteError(error);
      if (!upgradeRequired && offlineFailure) {
        _enterOffline();
        return;
      }
      state = state.copyWith(
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: upgradeRequired
            ? clientUpgradeRequiredMessage()
            : "Couldn't connect to cloud sync. Please retry.",
      );
    }
  }

  void _clearAuthIncident() {
    state = state.copyWith(
      clearAuthIncident: true,
      clearLastAuthIncidentSource: true,
      isAuthIncidentPromptOpen: false,
    );
  }

  Future<void> _showAuthIncidentPrompt(int incidentId) async {
    if (_showingIncidentPrompt) {
      return;
    }

    final navCtx = appNavigatorKey.currentContext ??
        appNavigatorKey.currentState?.overlay?.context;
    if (navCtx == null) {
      log(
        'Unable to show Convex auth incident prompt; navigator context unavailable.',
        name: 'auth',
      );
      return;
    }

    _showingIncidentPrompt = true;
    state = state.copyWith(isAuthIncidentPromptOpen: true);
    final localStrategiesNote =
        ref.read(platformPolicyProvider).allowsLocalLibrary
            ? ' Local strategies are unaffected.'
            : '';

    try {
      final action = await showShadDialog<_AuthIncidentAction>(
        context: navCtx,
        barrierDismissible: false,
        builder: (context) {
          return ShadDialog.alert(
            title: const Text('Cloud connection lost'),
            description: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Your cloud session is no longer valid, so syncing is '
                'paused. Reconnect to keep your cloud strategies up to '
                'date, or sign out.$localStrategiesNote',
              ),
            ),
            actions: [
              ShadButton.ghost(
                onPressed: () {
                  Navigator.of(context).pop(_AuthIncidentAction.dismiss);
                },
                child: const Text('Not Now'),
              ),
              ShadButton.secondary(
                onPressed: () {
                  Navigator.of(context).pop(_AuthIncidentAction.signOut);
                },
                child: const Text('Sign Out'),
              ),
              ShadButton(
                onPressed: () {
                  Navigator.of(context).pop(_AuthIncidentAction.retry);
                },
                child: const Text('Reconnect'),
              ),
            ],
          );
        },
      );

      if (state.activeAuthIncidentId != incidentId) {
        return;
      }

      switch (action) {
        case _AuthIncidentAction.retry:
          await reinitializeConvexAuth(source: 'incident_prompt_retry');
          break;
        case _AuthIncidentAction.signOut:
          if (navCtx.mounted) {
            await ref.read(guardedSignOutRequestProvider)(navCtx);
          }
          break;
        case _AuthIncidentAction.dismiss:
        case null:
          break;
      }
    } finally {
      _showingIncidentPrompt = false;
      if (state.activeAuthIncidentId == incidentId) {
        state = state.copyWith(isAuthIncidentPromptOpen: false);
      }
    }
  }
}

/// Setup found the socket down after trying to reconnect.
class _ConvexUnreachable implements Exception {
  const _ConvexUnreachable();

  @override
  String toString() => 'The Convex socket did not connect.';
}
