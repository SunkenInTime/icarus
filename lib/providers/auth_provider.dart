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

class AuthProvider extends Notifier<AppAuthState> {
  static final Uri _discordRedirectUri = Uri(
    scheme: 'icarus',
    host: 'auth',
    path: '/callback',
  );

  StreamSubscription<AuthState>? _supabaseAuthSub;
  AuthHandleWrapper? _convexAuthHandle;
  Future<void>? _inFlightConvexSetup;
  bool _queuedConvexSetup = false;
  bool _showingIncidentPrompt = false;
  int _incidentCounter = 0;

  SupabaseClient get _supabase => Supabase.instance.client;
  ConvexClient get _convex => ConvexClient.instance;

  @override
  AppAuthState build() {
    final session = _supabase.auth.currentSession;

    _supabaseAuthSub ??= _supabase.auth.onAuthStateChange.listen(
      (event) {
        final currentSession = event.session;
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

        unawaited(_configureConvexAuth(trigger: 'supabase:${event.event}'));
      },
      onError: (Object error, StackTrace stackTrace) {
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
      },
    );

    ref.onDispose(() {
      _supabaseAuthSub?.cancel();
      _convexAuthHandle?.dispose();
    });

    unawaited(_configureConvexAuth(trigger: 'build'));

    return AppAuthState.fromSession(
      session,
      isConvexUserReady: false,
      convexAuthStatus:
          session == null ? ConvexAuthStatus.signedOut : ConvexAuthStatus.configuring,
    );
  }

  bool isAuthCallbackUri(Uri uri) {
    final isIcarusScheme = uri.scheme.toLowerCase() == 'icarus';
    final isAuthCallback =
        uri.host.toLowerCase() == 'auth' && uri.path.toLowerCase() == '/callback';
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
      final launched = await _supabase.auth.signInWithOAuth(
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
      await _supabase.auth.signOut();
      _convexAuthHandle?.dispose();
      _convexAuthHandle = null;
      await _convex.clearAuth();
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
      await _supabase.auth.getSessionFromUrl(uri);
      await _configureConvexAuth(trigger: 'callback:$source');
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
      final session = _supabase.auth.currentSession;
      if (session == null) return null;

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
            final refreshed = await _supabase.auth.refreshSession();
            final refreshedToken = refreshed.session?.accessToken;
            if (refreshedToken != null && refreshedToken.isNotEmpty) {
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

    if (_supabase.auth.currentSession == null) {
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

  Future<void> _configureConvexAuth({required String trigger}) async {
    if (_inFlightConvexSetup != null) {
      _queuedConvexSetup = true;
      await _inFlightConvexSetup;
      return;
    }

    final completer = Completer<void>();
    _inFlightConvexSetup = completer.future;

    try {
      await _runConvexAuthSetup(trigger: trigger);
    } finally {
      completer.complete();
      _inFlightConvexSetup = null;

      if (_queuedConvexSetup) {
        _queuedConvexSetup = false;
        unawaited(_configureConvexAuth(trigger: 'queued'));
      }
    }
  }

  Future<void> _runConvexAuthSetup({required String trigger}) async {
    final session = _supabase.auth.currentSession;
    if (session == null) {
      _convexAuthHandle?.dispose();
      _convexAuthHandle = null;
      await _convex.clearAuth();
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
      _convexAuthHandle = await _convex.setAuthWithRefresh(
        fetchToken: _fetchSupabaseAccessToken,
        onAuthChange: (isAuthenticated) {
          if (isAuthenticated) {
            return;
          }
          if (_supabase.auth.currentSession == null) {
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

      await _convex.reconnect();
      await _convex.mutation(name: 'users:ensureCurrentUser', args: {});

      _clearAuthIncident();
      state = state.copyWith(
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        clearError: true,
      );
    } catch (error, stackTrace) {
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
