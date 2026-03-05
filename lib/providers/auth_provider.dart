import 'dart:async';
import 'dart:developer';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final authProvider =
    NotifierProvider<AuthProvider, AppAuthState>(AuthProvider.new);

class AppAuthState {
  const AppAuthState({
    required this.isLoading,
    required this.isAuthenticated,
    required this.user,
    this.errorMessage,
  });

  factory AppAuthState.fromSession(
    Session? session, {
    bool isLoading = false,
    String? errorMessage,
  }) {
    return AppAuthState(
      isLoading: isLoading,
      isAuthenticated: session != null,
      user: session?.user,
      errorMessage: errorMessage,
    );
  }

  final bool isLoading;
  final bool isAuthenticated;
  final User? user;
  final String? errorMessage;

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
    User? user,
    String? errorMessage,
    bool clearError = false,
  }) {
    return AppAuthState(
      isLoading: isLoading ?? this.isLoading,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      user: user ?? this.user,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class AuthProvider extends Notifier<AppAuthState> {
  static final Uri _discordRedirectUri = Uri(
    scheme: 'icarus',
    host: 'auth',
    path: '/callback',
  );

  StreamSubscription<AuthState>? _supabaseAuthSub;
  AuthHandleWrapper? _convexAuthHandle;
  bool _isConfiguringConvexAuth = false;
  bool _isEnsuringConvexUser = false;

  SupabaseClient get _supabase => Supabase.instance.client;
  ConvexClient get _convex => ConvexClient.instance;

  @override
  AppAuthState build() {
    final session = _supabase.auth.currentSession;
    _supabaseAuthSub ??= _supabase.auth.onAuthStateChange.listen(
      (event) {
        final currentSession = event.session;
        state = AppAuthState.fromSession(currentSession, isLoading: false);
        unawaited(_configureConvexAuth());
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
          errorMessage: 'Auth stream error: $error',
        );
      },
    );

    ref.onDispose(() {
      _supabaseAuthSub?.cancel();
      _convexAuthHandle?.dispose();
    });

    unawaited(_configureConvexAuth());
    return AppAuthState.fromSession(session);
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
    state = state.copyWith(isLoading: true, clearError: true);

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
        errorMessage: 'Discord sign-in failed: $error',
      );
      return;
    }

    state = state.copyWith(isLoading: false);
  }

  Future<void> signOut() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      await _supabase.auth.signOut();
      await _convex.clearAuth();
      state = AppAuthState.fromSession(null, isLoading: false);
    } catch (error, stackTrace) {
      log(
        'Sign out failed: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Sign out failed: $error',
      );
    }
  }

  Future<bool> handleAuthCallbackUri(Uri uri, {required String source}) async {
    if (!isAuthCallbackUri(uri)) {
      return false;
    }

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _supabase.auth.getSessionFromUrl(uri);
      unawaited(_configureConvexAuth());
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
        errorMessage: 'Failed to complete login: $error',
      );
      return true;
    }
  }

  Future<String?> _fetchSupabaseAccessToken() async {
    final session = _supabase.auth.currentSession;
    if (session == null) return null;

    final expiresAt = session.expiresAt;
    if (expiresAt != null) {
      final expiresAtUtc = DateTime.fromMillisecondsSinceEpoch(
        expiresAt * 1000,
        isUtc: true,
      );
      final shouldRefresh = expiresAtUtc.isBefore(
        DateTime.now().toUtc().add(const Duration(minutes: 1)),
      );

      if (shouldRefresh) {
        final refreshed = await _supabase.auth.refreshSession();
        return refreshed.session?.accessToken;
      }
    }

    return session.accessToken;
  }

  Future<void> _configureConvexAuth() async {
    if (_isConfiguringConvexAuth) return;
    _isConfiguringConvexAuth = true;

    try {
      _convexAuthHandle?.dispose();
      _convexAuthHandle = await _convex.setAuthWithRefresh(
        fetchToken: _fetchSupabaseAccessToken,
        onAuthChange: (isAuthenticated) {
          if (isAuthenticated) {
            unawaited(_ensureCurrentConvexUser());
          }
        },
      );
      if (_supabase.auth.currentSession != null) {
        unawaited(_ensureCurrentConvexUser());
      }
    } catch (error, stackTrace) {
      log(
        'Failed configuring Convex auth: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        errorMessage: 'Failed to configure Convex auth: $error',
      );
    } finally {
      _isConfiguringConvexAuth = false;
    }
  }

  Future<void> _ensureCurrentConvexUser() async {
    if (_isEnsuringConvexUser) return;
    if (_supabase.auth.currentSession == null) return;
    _isEnsuringConvexUser = true;

    try {
      const maxAttempts = 6;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          await _convex.mutation(name: 'users:ensureCurrentUser', args: {});
          return;
        } catch (error, stackTrace) {
          final isLastAttempt = attempt == maxAttempts;
          final isUnauthenticated = error.toString().contains('Unauthenticated');
          if (isUnauthenticated && !isLastAttempt) {
            // Convex auth may still be attaching/refeshing the Supabase token.
            await Future<void>.delayed(const Duration(milliseconds: 350));
            continue;
          }
          log(
            'Failed to ensure Convex user: $error',
            name: 'auth',
            error: error,
            stackTrace: stackTrace,
          );
          return;
        }
      }
    } catch (error, stackTrace) {
      log(
        'Failed to ensure Convex user: $error',
        name: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isEnsuringConvexUser = false;
    }
  }
}
