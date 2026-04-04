import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSupabaseApi supabaseApi;
  late FakeConvexApi convexApi;

  setUp(() {
    supabaseApi = FakeSupabaseApi();
    convexApi = FakeConvexApi();
    AuthProvider.debugSupabaseApi = supabaseApi;
    AuthProvider.debugConvexApi = convexApi;
    AuthProvider.debugConvexAuthReadyTimeout = const Duration(milliseconds: 50);
  });

  tearDown(() async {
    AuthProvider.resetTestOverrides();
    await supabaseApi.dispose();
  });

  test('build with existing Supabase session does not throw', () async {
    supabaseApi.currentSession = fakeSession();
    supabaseApi.emitInitialSessionOnListen = true;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(() => container.read(authProvider), returnsNormally);

    final state = container.read(authProvider);
    expect(state.isAuthenticated, isTrue);
    await pumpMicrotasks();
  });

  test('build queues Convex auth setup without gating auth events', () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.setAuthCompleter = Completer<AuthProviderAuthHandle>();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final initialState = container.read(authProvider);

    expect(initialState.isAuthenticated, isTrue);
    expect(initialState.convexAuthStatus, ConvexAuthStatus.configuring);
    expect(convexApi.setAuthCalls, 0);

    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(convexApi.setAuthCalls, 1);
    expect(state.convexAuthStatus, ConvexAuthStatus.configuring);
    expect(state.activeAuthIncidentId, isNull);
    expect(convexApi.reconnectCalls, 0);

    convexApi.setAuthCompleter!.complete(FakeAuthHandle());
  });

  test('startup auth calls reconnect before waiting for readiness', () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.autoAuthenticateOnSetAuth = false;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    expect(convexApi.setAuthCalls, 1);
    expect(convexApi.reconnectCalls, 1);
    expect(convexApi.mutationCalls, 0);
  });

  test(
      'does not call ensureCurrentUser before Convex auth becomes authenticated',
      () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.autoAuthenticateOnSetAuth = false;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    expect(convexApi.setAuthCalls, 1);
    expect(convexApi.reconnectCalls, 1);
    expect(convexApi.mutationCalls, 0);

    convexApi.emitAuthState(true);
    await pumpMicrotasks();

    expect(convexApi.mutationCalls, 1);
    expect(convexApi.lastMutationName, 'users:ensureCurrentUser');
    final state = container.read(authProvider);
    expect(state.convexAuthStatus, ConvexAuthStatus.ready);
  });

  test(
      'callback login relies on auth-state listener and does not schedule duplicate setup',
      () async {
    supabaseApi.sessionFromUrlSession = fakeSession();
    convexApi.autoAuthenticateOnSetAuth = false;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    final handled =
        await container.read(authProvider.notifier).handleAuthCallbackUri(
              Uri.parse('icarus://auth/callback#access_token=test-token'),
              source: 'test',
            );
    await pumpMicrotasks();

    expect(handled, isTrue);
    expect(supabaseApi.getSessionFromUrlCalls, 1);
    expect(convexApi.setAuthCalls, 1);
    expect(convexApi.mutationCalls, 0);

    convexApi.emitAuthState(true);
    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(state.isAuthenticated, isTrue);
    expect(state.convexAuthStatus, ConvexAuthStatus.ready);
  });

  test(
      'existing session on startup waits for Convex auth readiness before ensuring user',
      () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.autoAuthenticateOnSetAuth = false;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    expect(convexApi.setAuthCalls, 1);
    expect(convexApi.reconnectCalls, 1);
    expect(convexApi.mutationCalls, 0);

    convexApi.emitAuthState(true);
    await pumpMicrotasks();

    expect(convexApi.mutationCalls, 1);
    final state = container.read(authProvider);
    expect(state.convexAuthStatus, ConvexAuthStatus.ready);
    expect(state.isConvexUserReady, isTrue);
  });

  test('reconnect false still waits for authState and can recover', () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.autoAuthenticateOnSetAuth = false;
    convexApi.reconnectResult = false;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    expect(convexApi.reconnectCalls, 1);
    expect(convexApi.mutationCalls, 0);

    convexApi.emitAuthState(true);
    await pumpMicrotasks();

    expect(convexApi.mutationCalls, 1);
    expect(
        container.read(authProvider).convexAuthStatus, ConvexAuthStatus.ready);
  });

  test(
      'email password sign-in relies on auth-state listener and does not duplicate setup',
      () async {
    supabaseApi.currentSession = fakeSession();
    supabaseApi.emitSignedInEventOnPasswordSignIn = true;
    convexApi.autoAuthenticateOnSetAuth = false;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();
    expect(convexApi.setAuthCalls, 1);

    final error = await container.read(authProvider.notifier).signInWithEmailPassword(
          email: 'test@example.com',
          password: 'password',
        );
    await pumpMicrotasks();

    expect(error, isNull);
    expect(convexApi.setAuthCalls, 1);
    expect(convexApi.reconnectCalls, 1);
    expect(convexApi.mutationCalls, 0);

    convexApi.emitAuthState(true);
    await pumpMicrotasks();

    expect(convexApi.mutationCalls, 1);
    expect(
      container.read(authProvider).convexAuthStatus,
      ConvexAuthStatus.ready,
    );
  });

  test('stale startup setup does not mark user ready after sign-out', () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.autoAuthenticateOnSetAuth = false;
    convexApi.setAuthCompleter = Completer<AuthProviderAuthHandle>();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    expect(convexApi.setAuthCalls, 1);
    expect(convexApi.clearAuthCalls, 0);

    await container.read(authProvider.notifier).signOut();
    expect(container.read(authProvider).convexAuthStatus, ConvexAuthStatus.signedOut);
    expect(convexApi.clearAuthCalls, 1);

    convexApi.setAuthCompleter!.complete(FakeAuthHandle());
    await pumpMicrotasks();
    convexApi.emitAuthState(true);
    await pumpMicrotasks();

    expect(convexApi.mutationCalls, 0);
    final state = container.read(authProvider);
    expect(state.isAuthenticated, isFalse);
    expect(state.isConvexUserReady, isFalse);
    expect(state.convexAuthStatus, ConvexAuthStatus.signedOut);
  });

  test('null session clears Convex auth cleanly', () async {
    supabaseApi.currentSession = null;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final initialState = container.read(authProvider);
    expect(initialState.convexAuthStatus, ConvexAuthStatus.signedOut);

    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(convexApi.clearAuthCalls, 1);
    expect(state.isAuthenticated, isFalse);
    expect(state.convexAuthStatus, ConvexAuthStatus.signedOut);
  });

  test('real unauthenticated error still creates auth incident', () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.mutationError = Exception('{"code":"UNAUTHENTICATED"}');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(state.convexAuthStatus, ConvexAuthStatus.incident);
    expect(state.activeAuthIncidentId, isNotNull);
    expect(
      state.errorMessage,
      'Cloud authentication expired. Retry Convex auth or sign out.',
    );
  });

  test('auth readiness timeout surfaces as setup incident, not unauthenticated',
      () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.autoAuthenticateOnSetAuth = false;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(state.convexAuthStatus, ConvexAuthStatus.incident);
    expect(state.activeAuthIncidentId, isNull);
    expect(
      state.errorMessage,
      contains('Convex auth did not become ready within'),
    );
    expect(convexApi.mutationCalls, 0);
  });

  test(
      'non-auth setup error does not incorrectly become unauthenticated incident',
      () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.mutationError = StateError('boom');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(state.convexAuthStatus, ConvexAuthStatus.incident);
    expect(state.activeAuthIncidentId, isNull);
    expect(state.errorMessage, contains('Failed to configure Convex auth'));
  });

  test(
      'reconnect throwing still surfaces setup incident if readiness never arrives',
      () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.autoAuthenticateOnSetAuth = false;
    convexApi.reconnectError = StateError('reconnect failed');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(convexApi.reconnectCalls, 1);
    expect(state.convexAuthStatus, ConvexAuthStatus.incident);
    expect(state.activeAuthIncidentId, isNull);
    expect(
      state.errorMessage,
      contains('Convex auth did not become ready within'),
    );
    expect(state.errorMessage, contains('reconnectResult: unknown'));
  });
}

Future<void> pumpMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Session fakeSession() {
  final session = Session(
    accessToken: 'test-token',
    refreshToken: 'refresh-token',
    tokenType: 'bearer',
    user: const User(
      id: 'user-1',
      appMetadata: <String, dynamic>{},
      userMetadata: <String, dynamic>{'full_name': 'Test User'},
      aud: 'authenticated',
      email: 'test@example.com',
      createdAt: '2026-03-23T00:00:00.000Z',
    ),
  );
  session.expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch ~/
      1000;
  return session;
}

class FakeAuthHandle implements AuthProviderAuthHandle {
  bool isDisposed = false;

  @override
  void dispose() {
    isDisposed = true;
  }
}

class FakeConvexApi implements AuthProviderConvexApi {
  FakeConvexApi() : _authStateController = StreamController<bool>.broadcast();

  final StreamController<bool> _authStateController;
  int clearAuthCalls = 0;
  int reconnectCalls = 0;
  int setAuthCalls = 0;
  int mutationCalls = 0;
  String? lastMutationName;
  bool autoAuthenticateOnSetAuth = true;
  bool _isAuthenticated = false;
  Object? mutationError;
  Object? reconnectError;
  bool reconnectResult = true;
  Completer<AuthProviderAuthHandle>? setAuthCompleter;

  @override
  Stream<bool> get authState => _authStateController.stream;

  @override
  bool get isAuthenticated => _isAuthenticated;

  @override
  String? get currentConnectionStateLabel => 'connected';

  @override
  Future<void> clearAuth() async {
    clearAuthCalls += 1;
    _isAuthenticated = false;
    _authStateController.add(false);
  }

  @override
  Future<bool> reconnect() async {
    reconnectCalls += 1;
    if (reconnectError case final Object error?) {
      throw error;
    }
    return reconnectResult;
  }

  @override
  Future<String> mutation({
    required String name,
    required Map<String, dynamic> args,
  }) async {
    mutationCalls += 1;
    lastMutationName = name;
    if (mutationError case final Object error?) {
      throw error;
    }
    return '{}';
  }

  @override
  Future<AuthProviderAuthHandle> setAuthWithRefresh({
    required Future<String?> Function() fetchToken,
    void Function(bool isAuthenticated)? onAuthChange,
  }) async {
    setAuthCalls += 1;
    final completer = setAuthCompleter;
    if (completer != null) {
      return completer.future;
    }
    if (autoAuthenticateOnSetAuth) {
      emitAuthState(true);
      onAuthChange?.call(true);
    }
    return FakeAuthHandle();
  }

  void emitAuthState(bool isAuthenticated) {
    _isAuthenticated = isAuthenticated;
    _authStateController.add(isAuthenticated);
  }
}

class FakeSupabaseApi implements AuthProviderSupabaseApi {
  @override
  Session? currentSession;
  bool emitInitialSessionOnListen = false;
  bool emitSignedInEventOnPasswordSignIn = false;
  Session? sessionFromUrlSession;
  int getSessionFromUrlCalls = 0;
  final List<MultiStreamController<AuthState>> _controllers =
      <MultiStreamController<AuthState>>[];

  @override
  Stream<AuthState> get onAuthStateChange => Stream<AuthState>.multi(
        (controller) {
          _controllers.add(controller);
          if (emitInitialSessionOnListen) {
            controller.add(
              AuthState(AuthChangeEvent.initialSession, currentSession),
            );
          }
          controller.onCancel = () {
            _controllers.remove(controller);
          };
        },
        isBroadcast: true,
      );

  @override
  Future<void> getSessionFromUrl(Uri uri) async {
    getSessionFromUrlCalls += 1;
    if (sessionFromUrlSession case final Session session?) {
      currentSession = session;
      for (final controller in _controllers) {
        controller.add(AuthState(AuthChangeEvent.signedIn, currentSession));
      }
    }
  }

  @override
  Future<AuthResponse> refreshSession() async {
    return AuthResponse(session: currentSession);
  }

  @override
  Future<bool> signInWithOAuth(
    OAuthProvider provider, {
    required String redirectTo,
    required LaunchMode authScreenLaunchMode,
    required String scopes,
  }) async {
    return true;
  }

  @override
  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) async {
    if (emitSignedInEventOnPasswordSignIn) {
      for (final controller in _controllers) {
        controller.add(AuthState(AuthChangeEvent.signedIn, currentSession));
      }
    }
    return AuthResponse(session: currentSession);
  }

  @override
  Future<void> signOut() async {
    currentSession = null;
    for (final controller in _controllers) {
      controller.add(AuthState(AuthChangeEvent.signedOut, currentSession));
    }
  }

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) async {
    return AuthResponse(session: currentSession);
  }

  Future<void> dispose() async {}
}
