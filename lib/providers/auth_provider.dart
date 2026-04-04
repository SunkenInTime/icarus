import 'dart:async';
import 'dart:developer';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final authProvider =
    NotifierProvider<AuthProvider, AppAuthState>(AuthProvider.new);

enum ConvexAuthStatus {
  signedOut,
  configuring,
  ready,
  incident,
}

final RegExp _convexCodeRegex = RegExp(r'"code"\s*:\s*"([A-Z_]+)"');

String? _extractConvexErrorCodeFromText(String text) {
  final match = _convexCodeRegex.firstMatch(text);
  final code = match?.group(1);
  if (code == null || code.isEmpty) {
    return null;
  }
  return code;
}

bool isConvexUnauthenticatedMessage(String message) {
  final normalized = message.toUpperCase();
  final code = _extractConvexErrorCodeFromText(normalized);
  if (code == 'UNAUTHENTICATED') {
    return true;
  }

  return normalized.contains('UNAUTHENTICATED');
}

bool isConvexUnauthenticatedError(Object error) {
  if (error is Map) {
    final code = error['code']?.toString().toUpperCase();
    if (code == 'UNAUTHENTICATED') {
      return true;
    }
  }

  return isConvexUnauthenticatedMessage(error.toString());
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
    final String? name = metadata['full_name'] as String? ??
        metadata['name'] as String? ??
        metadata['user_name'] as String? ??
        user?.email;
    return (name?.isNotEmpty ?? false) ? name! : 'Discord user';
  }

  String? get avatarUrl {
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    return metadata['avatar_url'] as String?;
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
  Future<void> clearAuth();
  Future<bool> reconnect();
  Future<String> mutation({
    required String name,
    required Map<String, dynamic> args,
  });
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
  Future<void> clearAuth() => _client.clearAuth();

  @override
  Future<bool> reconnect() => _client.reconnect();

  @override
  Future<String> mutation({
    required String name,
    required Map<String, dynamic> args,
  }) =>
      _client.mutation(name: name, args: args);
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

class AuthProvider extends Notifier<AppAuthState> {
  static final Uri _discordRedirectUri = Uri(
    scheme: 'icarus',
    host: 'auth',
    path: '/callback',
  );

  StreamSubscription<AuthState>? _supabaseAuthSub;
  AuthProviderAuthHandle? _convexAuthHandle;
  Future<void>? _inFlightConvexSetup;
  bool _queuedConvexSetup = false;
  String? _queuedConvexTrigger;
  bool _showingIncidentPrompt = false;
  int _incidentCounter = 0;
  int _authGeneration = 0;

  @visibleForTesting
  static AuthProviderSupabaseApi? debugSupabaseApi;

  @visibleForTesting
  static AuthProviderConvexApi? debugConvexApi;

  @visibleForTesting
  static Duration? debugConvexAuthReadyTimeout;

  late final AuthProviderSupabaseApi _supabaseApi;
  late final AuthProviderConvexApi _convexApi;

  @visibleForTesting
  static void resetTestOverrides() {
    debugSupabaseApi = null;
    debugConvexApi = null;
    debugConvexAuthReadyTimeout = null;
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
    _supabaseApi = debugSupabaseApi ?? const _DefaultAuthProviderSupabaseApi();
    _convexApi = debugConvexApi ?? const _DefaultAuthProviderConvexApi();
    final session = _supabaseApi.currentSession;
    final initialGeneration = _advanceAuthGeneration();

    _supabaseAuthSub ??= _supabaseApi.onAuthStateChange.listen(
      _handleSupabaseAuthStateChange,
      onError: _handleSupabaseAuthStreamError,
    );

    ref.onDispose(() {
      _supabaseAuthSub?.cancel();
      _convexAuthHandle?.dispose();
    });

    Future<void>.microtask(() async {
      await _configureConvexAuth(
        trigger: 'build',
        generation: initialGeneration,
        sessionFingerprint: _sessionFingerprint(session),
      );
    });

    return AppAuthState.fromSession(
      session,
      isConvexUserReady: false,
      convexAuthStatus: session == null
          ? ConvexAuthStatus.signedOut
          : ConvexAuthStatus.configuring,
    );
  }

  void _handleSupabaseAuthStateChange(AuthState event) {
    final currentSession = event.session;
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

    state = state.copyWith(
      isLoading: false,
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.incident,
      errorMessage: 'Auth stream error: $error',
    );
  }

  bool isAuthCallbackUri(Uri uri) {
    final isIcarusScheme = uri.scheme.toLowerCase() == 'icarus';
    final isAuthCallback = uri.host.toLowerCase() == 'auth' &&
        uri.path.toLowerCase() == '/callback';
    if (!isIcarusScheme || !isAuthCallback) {
      return false;
    }

    final hasAuthPayload = uri.fragment.contains('access_token') ||
        uri.queryParameters.containsKey('code') ||
        uri.fragment.contains('error_description') ||
        uri.queryParameters.containsKey('error_description');
    return hasAuthPayload;
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
        redirectTo: _discordRedirectUri.toString(),
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
        errorMessage: 'Discord sign-in failed: $error',
      );
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
        const message = 'Sign in did not return a session.';
        state = state.copyWith(
          isLoading: false,
          isConvexUserReady: false,
          convexAuthStatus: ConvexAuthStatus.incident,
          errorMessage: message,
        );
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
      final message = 'Email/password sign-in failed: $error';
      state = state.copyWith(
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: message,
      );
      return message;
    }
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

      if (response.session == null) {
        const message =
            'Account created, but email confirmation is required before sign in.';
        state = state.copyWith(
          isLoading: false,
          isConvexUserReady: false,
          convexAuthStatus: ConvexAuthStatus.signedOut,
          errorMessage: message,
        );
        return message;
      }

      state = state.copyWith(isLoading: false);
      return null;
    } catch (error, stackTrace) {
      log(
        'Email/password sign-up failed: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      final message = 'Email/password sign-up failed: $error';
      state = state.copyWith(
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: message,
      );
      return message;
    }
  }

  Future<void> signOut() async {
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
      _convexAuthHandle?.dispose();
      _convexAuthHandle = null;
      await _convexApi.clearAuth();
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
      state = state.copyWith(
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: 'Sign out failed: $error',
      );
    }
  }

  Future<bool> handleAuthCallbackUri(Uri uri, {required String source}) async {
    if (!isAuthCallbackUri(uri)) {
      return false;
    }

    state = state.copyWith(
      isLoading: true,
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.configuring,
      clearError: true,
    );

    try {
      await _supabaseApi.getSessionFromUrl(uri);
      state = state.copyWith(isLoading: false);
      log('Handled auth callback [$source]: $uri', name: 'auth');
      return true;
    } catch (error, stackTrace) {
      log(
        'Failed auth callback [$source]: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        isLoading: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: 'Failed to complete login: $error',
      );
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
          'Cloud authentication expired. Retry Convex auth or sign out.',
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

      if (_queuedConvexSetup) {
        _queuedConvexSetup = false;
        final queuedTrigger = _queuedConvexTrigger ?? 'queued';
        _queuedConvexTrigger = null;
        unawaited(_configureConvexAuth(trigger: queuedTrigger));
      }
    }
  }

  Duration get _convexAuthReadyTimeout =>
      debugConvexAuthReadyTimeout ?? const Duration(seconds: 5);

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
      await _convexApi.clearAuth();
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

    state = state.copyWith(
      isLoading: false,
      isAuthenticated: true,
      isConvexUserReady: false,
      convexAuthStatus: ConvexAuthStatus.configuring,
      clearError: true,
    );

    try {
      _convexAuthHandle?.dispose();
      final wasAuthenticatedBeforeSetup = _convexApi.isAuthenticated;
      bool? reconnectResult;
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
          if (state.convexAuthStatus == ConvexAuthStatus.configuring) {
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
        reconnectResult = await _convexApi.reconnect();
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
      await _convexApi.mutation(name: 'users:ensureCurrentUser', args: {});
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
    } catch (error, stackTrace) {
      if (!_isAuthContextCurrent(
        generation: generation,
        sessionFingerprint: sessionFingerprint,
      )) {
        return;
      }

      log(
        'Failed configuring Convex auth [$trigger]: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );

      if (isConvexUnauthenticatedError(error)) {
        await reportConvexUnauthenticated(
          source: 'setup:$trigger',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }

      if (error is TimeoutException) {
        log(
          'Convex auth readiness timed out [$trigger]: $error',
          name: 'auth',
          error: error,
          stackTrace: stackTrace,
        );
      } else {
        log(
          'Convex auth setup failed after readiness or mutation [$trigger]: $error',
          name: 'auth',
          error: error,
          stackTrace: stackTrace,
        );
      }

      state = state.copyWith(
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.incident,
        errorMessage: 'Failed to configure Convex auth: $error',
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

    try {
      final action = await showDialog<_AuthIncidentAction>(
        context: navCtx,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            title: const Text('Cloud Session Needs Attention'),
            content: const Text(
              'Convex reported your session as unauthenticated while Supabase is signed in. '
              'Retry Convex auth, sign out, or dismiss to keep cloud features paused.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(_AuthIncidentAction.dismiss);
                },
                child: const Text('Dismiss'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(_AuthIncidentAction.signOut);
                },
                child: const Text('Sign Out'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pop(_AuthIncidentAction.retry);
                },
                child: const Text('Retry Convex Auth'),
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
          await signOut();
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
