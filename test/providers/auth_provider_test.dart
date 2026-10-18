import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/guarded_sign_out.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    appProviderContainer = ProviderContainer();
  });

  tearDownAll(() {
    appProviderContainer.dispose();
  });

  late FakeSupabaseApi supabaseApi;
  late FakeConvexApi convexApi;

  setUp(() {
    supabaseApi = FakeSupabaseApi();
    convexApi = FakeConvexApi();
    appProviderContainer.read(inAppDebugProvider.notifier).clearLogs();
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

  test(
      'a restored session gets one Convex setup, not one from build and '
      'another from initialSession', () async {
    // A page refresh on web: Supabase restores the session before the
    // provider builds, then replays it to the new listener as initialSession,
    // and the Convex socket takes a while to confirm the token.
    supabaseApi.currentSession = fakeSession();
    supabaseApi.emitInitialSessionOnListen = true;
    convexApi.autoAuthenticateOnSetAuth = false;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();
    convexApi.emitAuthState(true);
    await pumpMicrotasks();
    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(state.convexAuthStatus, ConvexAuthStatus.ready);
    expect(state.isConvexUserReady, isTrue);
    expect(convexApi.setAuthCalls, 1);
    expect(convexApi.mutationCalls, 1);
    expect(convexApi.handles.single.isDisposed, isFalse);
  });

  test('initialSession with a different session than build still sets up',
      () async {
    supabaseApi.currentSession = fakeSession();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();
    expect(convexApi.setAuthCalls, 1);

    // Supabase refreshed the restored session before replaying it.
    final refreshed = fakeSession(accessToken: 'refreshed-token');
    supabaseApi.currentSession = refreshed;
    supabaseApi.emit(AuthChangeEvent.initialSession, refreshed);
    await pumpMicrotasks();
    await pumpMicrotasks();

    expect(convexApi.setAuthCalls, 2);
    expect(
      container.read(authProvider).convexAuthStatus,
      ConvexAuthStatus.ready,
    );
  });

  test('a Convex setup failure is reported, redacted, to the console',
      () async {
    final printed = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };
    AppErrorReporter.echoToConsole = true;
    addTearDown(() {
      debugPrint = originalDebugPrint;
      AppErrorReporter.echoToConsole = false;
    });
    supabaseApi.currentSession = fakeSession();
    convexApi.mutationError = StateError('boom access_token=secret-value');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    expect(
      container.read(authProvider).convexAuthStatus,
      ConvexAuthStatus.incident,
    );
    final entry = appProviderContainer
        .read(inAppDebugProvider)
        .singleWhere((entry) => entry.source == 'auth');
    expect(entry.message, 'Convex auth setup failed [build]');
    expect(entry.errorText, 'Bad state: boom access_token=<redacted>');
    expect(printed, [
      '[auth] warning: Convex auth setup failed [build]: '
          'Bad state: boom access_token=<redacted>',
    ]);
    final everything = [
      entry.message,
      entry.errorText,
      entry.stackTrace,
      ...printed,
    ].join('\n');
    expect(everything, isNot(contains('secret-value')));
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
              Uri.parse('icarus://auth/callback?code=test-code'),
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

  test('a link carrying session tokens is rejected without a sign-in',
      () async {
    // Anyone can craft this link. GoTrue would import the tokens and sign
    // the user into the attacker's account, so it must never reach it.
    final injected = Uri.parse(
      'icarus://auth/callback#access_token=attacker-access'
      '&refresh_token=attacker-refresh&expires_in=3600&token_type=bearer',
    );
    supabaseApi.sessionFromUrlSession = fakeSession();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();
    final before = container.read(authProvider);

    final handled = await container
        .read(authProvider.notifier)
        .handleAuthCallbackUri(injected, source: 'test');
    await pumpMicrotasks();

    expect(handled, isTrue, reason: 'handled, so the caller scrubs the URL');
    expect(supabaseApi.getSessionFromUrlCalls, 0);
    expect(supabaseApi.currentSession, isNull);
    final after = container.read(authProvider);
    expect(after.isAuthenticated, before.isAuthenticated);
    expect(after.convexAuthStatus, before.convexAuthStatus);
    expect(after.isLoading, isFalse);
    expect(convexApi.setAuthCalls, 0);

    final report = AppErrorReporter.buildClipboardReport(
      appProviderContainer.read(inAppDebugProvider),
    );
    expect(report, contains('Rejected auth callback carrying session tokens'));
    expect(report, isNot(contains('attacker-access')));
    expect(report, isNot(contains('attacker-refresh')));
  });

  group('redactDeepLinkUri', () {
    const code = 'ICR-2345-6789-ABCD-EFGH';

    test('hides share codes in every link form', () {
      for (final link in [
        'https://beta.icarusstrats.com/share/$code',
        'https://icarusstrats.com/share/$code?utm=x',
        'https://icarusstrats.com/share?code=$code',
        'https://icarusstrats.com/share?token=0ee927ca-babc-4350',
        'icarus://share?code=$code',
        'icarus://share/$code',
      ]) {
        final redacted = redactDeepLinkUri(Uri.parse(link));
        expect(redacted, contains('redacted'), reason: link);
        expect(redacted, isNot(contains(code)), reason: link);
        expect(redacted, isNot(contains('0ee927ca')), reason: link);
      }
      expect(
        redactDeepLinkUri(
          Uri.parse('https://icarusstrats.com/share/$code?utm=x'),
        ),
        'https://icarusstrats.com/share/%3Credacted%3E?utm=x',
      );
    });

    test('hides sign-in secrets in the query and fragment', () {
      final redacted = redactDeepLinkUri(
        Uri.parse(
          'https://beta.icarusstrats.com/?code=pkce-secret'
          '#access_token=access-secret&refresh_token=refresh-secret',
        ),
      );
      for (final secret in ['pkce-secret', 'access-secret', 'refresh-secret']) {
        expect(redacted, isNot(contains(secret)));
      }
    });

    test('leaves ordinary links readable and never throws', () {
      expect(
        redactDeepLinkUri(Uri.parse('https://beta.icarusstrats.com/#/')),
        'https://beta.icarusstrats.com/#/',
      );
      expect(
        redactDeepLinkUri(
          Uri.parse('https://beta.icarusstrats.com/?x=%E0%A4%A#a=%E0%A4%A'),
        ),
        isNot(contains('%E0%A4')),
      );
    });

    test('a path that does not decode is fully redacted, not thrown', () {
      const input = 'icarus://share/%FF?token=secret';
      expect(
        () => redactDeepLinkUri(Uri.parse(input)),
        returnsNormally,
      );
      expect(
        redactDeepLinkUri(Uri.parse(input)),
        unparseableLinkPlaceholder,
      );
      expect(redactLaunchArgument(input), unparseableLinkPlaceholder);
      expect(
        redactDeepLinkUri(Uri.parse('https://beta.icarusstrats.com/share/%FF')),
        unparseableLinkPlaceholder,
      );
    });

    test('an unparseable link-shaped argument is not logged raw', () {
      for (final argument in [
        'https://[beta.icarusstrats.com/share/$code',
        'icarus://[share?code=$code',
      ]) {
        expect(Uri.tryParse(argument), isNull, reason: argument);
        expect(
          redactLaunchArgument(argument),
          unparseableLinkPlaceholder,
          reason: argument,
        );
      }
      expect(
        redactLaunchArgument('icarus:share?code=$code'),
        isNot(contains(code)),
        reason: 'a parseable icarus: link without // is still redacted',
      );
    });

    test('launch arguments: links are redacted, file paths are not', () {
      expect(
        redactLaunchArgument('icarus://share?code=$code'),
        isNot(contains(code)),
      );
      expect(
        redactLaunchArgument(r'C:\Users\me\plans\retake.ica'),
        r'C:\Users\me\plans\retake.ica',
      );
    });
  });

  test('callback failure removes credentials from UI and diagnostics',
      () async {
    final callback = Uri.parse(
      'icarus://auth/callback?code=callback-code-secret',
    );
    supabaseApi.sessionFromUrlError = Exception(
      'Provider rejected $callback '
      'access_token=access-secret&refresh_token=refresh-secret '
      '{"code_verifier":"verifier-secret"} '
      'access_token%3Dencoded-secret%26token_type%3Dbearer',
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    final handled =
        await container.read(authProvider.notifier).handleAuthCallbackUri(
              callback,
              source: 'test',
            );

    expect(handled, isTrue);
    expect(
      container.read(authProvider).errorMessage,
      'Failed to complete login. Please try again.',
    );

    final report = AppErrorReporter.buildClipboardReport(
      appProviderContainer.read(inAppDebugProvider),
    );
    expect(report, contains('Failed auth callback [test]'));
    expect(report, contains('redacted'));
    for (final credential in [
      'callback-code-secret',
      'access-secret',
      'refresh-secret',
      'verifier-secret',
      'encoded-secret',
    ]) {
      expect(report, isNot(contains(credential)));
    }
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

    final error =
        await container.read(authProvider.notifier).signInWithEmailPassword(
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
    expect(container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.signedOut);
    expect(convexApi.clearAuthCalls, 1);

    convexApi.setAuthCompleter!.complete(FakeAuthHandle());
    await pumpMicrotasks();
    convexApi.emitAuthState(true);
    await pumpMicrotasks();

    expect(convexApi.mutationCalls, 0);
    final state = container.read(authProvider);
    expect(state.isAuthenticated, isFalse);
    expect(state.isConvexUserReady, isFalse);
    expect(state.errorMessage, isNull);
    expect(state.convexAuthStatus, ConvexAuthStatus.signedOut);
  });

  test('a signed-out startup leaves Convex alone', () async {
    // Clearing auth that was never set would open the Convex socket for a
    // user who never asked for the cloud.
    supabaseApi.currentSession = null;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final initialState = container.read(authProvider);
    expect(initialState.convexAuthStatus, ConvexAuthStatus.signedOut);

    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(convexApi.clearAuthCalls, 0);
    expect(convexApi.setAuthCalls, 0);
    expect(state.isAuthenticated, isFalse);
    expect(state.convexAuthStatus, ConvexAuthStatus.signedOut);
  });

  test('a session that ends clears the Convex auth it set', () async {
    supabaseApi.currentSession = fakeSession();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();
    expect(convexApi.setAuthCalls, 1);
    expect(convexApi.clearAuthCalls, 0);

    // The session expires or is revoked: Supabase reports it gone without
    // a sign-out through the app.
    supabaseApi.currentSession = null;
    supabaseApi.emit(AuthChangeEvent.signedOut, null);
    await pumpMicrotasks();

    expect(convexApi.clearAuthCalls, 1);
    expect(
      container.read(authProvider).convexAuthStatus,
      ConvexAuthStatus.signedOut,
    );
  });

  test('real unauthenticated error still creates auth incident', () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.mutationError = const ConvexClientFunctionError(
      rawCode: 'UNAUTHENTICATED',
      message: 'Authentication required',
      data: null,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(state.convexAuthStatus, ConvexAuthStatus.incident);
    expect(state.activeAuthIncidentId, isNotNull);
    expect(
      state.errorMessage,
      'Your cloud session expired. Reconnect to resume syncing, or sign out.',
    );
  });

  testWidgets('auth incident Sign Out uses the guarded flow', (tester) async {
    supabaseApi.currentSession = fakeSession();
    var guardedRequests = 0;
    final container = ProviderContainer(overrides: [
      guardedSignOutRequestProvider.overrideWithValue((context) async {
        guardedRequests += 1;
        return false;
      }),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          navigatorKey: appNavigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    final notifier = container.read(authProvider.notifier);
    await tester.pump();
    await tester.pump();

    await notifier.reportConvexUnauthenticated(
      source: 'test:incident-route',
      error: const ConvexClientFunctionError(
        rawCode: 'UNAUTHENTICATED',
        message: 'Authentication required',
        data: null,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Cloud connection lost'), findsOneWidget);

    await tester.tap(find.text('Sign Out'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(guardedRequests, 1);
    expect(supabaseApi.currentSession, isNotNull);
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
      "Couldn't connect to cloud sync. Please retry.",
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
    expect(state.errorMessage, "Couldn't connect to cloud sync. Please retry.");
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
      "Couldn't connect to cloud sync. Please retry.",
    );
  });

  test('a setup that ends after its provider is gone touches nothing',
      () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.setAuthCompleter = Completer<AuthProviderAuthHandle>();
    final container = ProviderContainer();
    container.read(authProvider);
    await pumpMicrotasks();
    expect(convexApi.setAuthCalls, 1);

    // The provider goes while setup waits on Convex, which then refuses it.
    container.dispose();
    convexApi.mutationError = _upgradeRequired;
    convexApi.emitAuthState(true);
    convexApi.setAuthCompleter!.complete(FakeAuthHandle());
    // Readiness times out after 50 ms; the setup fails after that. Any read
    // of a provider from the disposed container fails this test.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await pumpMicrotasks();
  });

  test('a setup queued behind one running when the provider goes never runs',
      () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.setAuthCompleter = Completer<AuthProviderAuthHandle>();
    final container = ProviderContainer();
    final notifier = container.read(authProvider.notifier);
    await pumpMicrotasks();
    expect(convexApi.setAuthCalls, 1);

    // A second setup queues behind the first, then the provider goes.
    unawaited(notifier.reinitializeConvexAuth(source: 'test'));
    await pumpMicrotasks();
    container.dispose();
    convexApi.emitAuthState(true);
    convexApi.setAuthCompleter!.complete(FakeAuthHandle());
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await pumpMicrotasks();

    expect(convexApi.setAuthCalls, 1);
  });

  test('a sign-up whose confirmation email cannot be sent says so', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final auth = container.read(authProvider.notifier);

    // What Supabase answered on the live beta once its email limit was spent.
    supabaseApi.signUpError = const AuthApiException(
      'email rate limit exceeded',
      statusCode: '429',
      code: 'over_email_send_rate_limit',
    );
    const unsent = "We couldn't send your confirmation email right now. Try "
        'again later, or continue with Discord.';
    expect(
      await auth.signUpWithEmailPassword(email: 'a@b.co', password: 'secret'),
      unsent,
    );

    // The mail server failing comes back as a 500 carrying the body.
    supabaseApi.signUpError = AuthRetryableFetchException(
      message: '{"code":"unexpected_failure",'
          '"message":"Error sending confirmation email"}',
      statusCode: '500',
    );
    expect(
      await auth.signUpWithEmailPassword(email: 'a@b.co', password: 'secret'),
      unsent,
    );

    // Throttled requests are still "too many attempts".
    supabaseApi.signUpError = const AuthApiException(
      'Request rate limit reached',
      statusCode: '429',
      code: 'over_request_rate_limit',
    );
    expect(
      await auth.signUpWithEmailPassword(email: 'a@b.co', password: 'secret'),
      'Too many attempts. Wait a moment and try again.',
    );
  });

  test('a setup the server refuses says Icarus was updated', () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.mutationError = _upgradeRequired;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(authProvider);
    await pumpMicrotasks();

    final state = container.read(authProvider);
    expect(state.convexAuthStatus, ConvexAuthStatus.incident);
    expect(state.errorMessage, clientUpgradeRequiredMessage());
    expect(container.read(clientUpgradeRequiredProvider), isTrue);
  });

  test('a refused setup runs again once the server accepts this build',
      () async {
    supabaseApi.currentSession = fakeSession();
    convexApi.mutationError = _upgradeRequired;
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider
          .overrideWithValue(_AcceptingRepository()),
    ]);
    addTearDown(container.dispose);
    container.read(authProvider);
    await pumpMicrotasks();
    expect(container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.incident);

    // A rolled-back deploy accepts this protocol again.
    convexApi.mutationError = null;
    await container.read(clientUpgradeRequiredProvider.notifier).recheck();
    await pumpMicrotasks();
    await pumpMicrotasks();

    expect(container.read(clientUpgradeRequiredProvider), isFalse);
    expect(
      container.read(authProvider).convexAuthStatus,
      ConvexAuthStatus.ready,
    );
  });

  group('offline', () {
    setUp(() {
      supabaseApi.currentSession = fakeSession();
      // Out of reach: the socket never connects.
      convexApi.connected = false;
      convexApi.reconnectResult = false;
      convexApi.autoAuthenticateOnSetAuth = false;
      AuthProvider.debugOfflineRetryDelay = (_) => const Duration(hours: 1);
    });

    test(
        'a setup that cannot reach the cloud is offline, not an incident, '
        'and says so through cloudOfflineProvider', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();

      final state = container.read(authProvider);
      expect(state.convexAuthStatus, ConvexAuthStatus.offline);
      expect(state.isAuthenticated, isTrue);
      expect(state.isConvexUserReady, isFalse);
      expect(state.activeAuthIncidentId, isNull);
      expect(state.errorMessage, isNull);
      expect(container.read(cloudOfflineProvider), isTrue);
      expect(convexApi.mutationCalls, 0);
    });

    test('it sets up again by itself the moment the socket connects', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();
      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.offline,
      );

      convexApi.reconnectSocket();
      await pumpMicrotasks();
      await pumpMicrotasks();

      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.ready,
      );
      expect(container.read(cloudOfflineProvider), isFalse);
      expect(convexApi.setAuthCalls, 2);
    });

    test('it sets up again on a timer when no connect event comes', () async {
      AuthProvider.debugOfflineRetryDelay =
          (_) => const Duration(milliseconds: 20);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();
      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.offline,
      );
      final attemptsWhileOffline = convexApi.setAuthCalls;

      await waitUntil(() => convexApi.setAuthCalls > attemptsWhileOffline);
      await pumpMicrotasks();
      // Still out of reach: each timed try ends offline again.
      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.offline,
      );

      convexApi
        ..connected = true
        ..reconnectResult = true
        ..autoAuthenticateOnSetAuth = true;
      await waitUntil(
        () =>
            container.read(authProvider).convexAuthStatus ==
            ConvexAuthStatus.ready,
      );
    });

    test(
        'a server that just came back and is slow to confirm the session '
        'keeps the session offline, and it gets through on a later try',
        () async {
      AuthProvider.debugOfflineRetryDelay =
          (_) => const Duration(milliseconds: 20);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();

      // Back, but the server doesn't confirm the session within the wait.
      convexApi
        ..connected = true
        ..reconnectResult = true;
      convexApi.connectedController.add(true);
      // The first try reached the server and ran out of time; the next one
      // has started.
      await waitUntil(() => convexApi.setAuthCalls >= 3);
      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.offline,
      );
      expect(container.read(authProvider).activeAuthIncidentId, isNull);

      convexApi.autoAuthenticateOnSetAuth = true;
      await waitUntil(
        () =>
            container.read(authProvider).convexAuthStatus ==
            ConvexAuthStatus.ready,
      );
    });

    test(
        'a connected server that never confirms the session is an incident '
        'after a few tries', () async {
      AuthProvider.debugOfflineRetryDelay =
          (_) => const Duration(milliseconds: 20);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();

      convexApi
        ..connected = true
        ..reconnectResult = true;
      convexApi.connectedController.add(true);

      await waitUntil(
        () =>
            container.read(authProvider).convexAuthStatus ==
            ConvexAuthStatus.incident,
      );
      // Three slow tries, then the fourth gave up.
      expect(convexApi.setAuthCalls, 5);
    });

    test('a retry stays offline on screen until it succeeds', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();

      final setAuth = Completer<AuthProviderAuthHandle>();
      convexApi.setAuthCompleter = setAuth;
      convexApi.connectedController.add(true);
      await pumpMicrotasks();

      expect(convexApi.setAuthCalls, 2);
      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.offline,
      );
      setAuth.complete(FakeAuthHandle());
      await pumpMicrotasks();
    });

    test('backs off from 5 seconds to a minute', () {
      AuthProvider.debugOfflineRetryDelay = null;
      expect(
        [for (var i = 0; i < 7; i++) AuthProvider.offlineRetryDelay(i)],
        const [
          Duration(seconds: 5),
          Duration(seconds: 10),
          Duration(seconds: 20),
          Duration(seconds: 40),
          Duration(seconds: 60),
          Duration(seconds: 60),
          Duration(seconds: 60),
        ],
      );
    });

    test('a server that refuses this build is still an incident', () async {
      convexApi
        ..reconnectResult = true
        ..autoAuthenticateOnSetAuth = true
        ..mutationError = _upgradeRequired;
      final container = ProviderContainer(overrides: [
        convexStrategyRepositoryProvider
            .overrideWithValue(_AcceptingRepository()),
      ]);
      addTearDown(container.dispose);

      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();

      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.incident,
      );
      expect(container.read(clientUpgradeRequiredProvider), isTrue);
      expect(container.read(cloudOfflineProvider), isFalse);
    });

    test('a session the server rejects is still an incident', () async {
      convexApi
        ..reconnectResult = true
        ..autoAuthenticateOnSetAuth = true
        ..mutationError = const ConvexFunctionException(
          code: ConvexErrorCode.unauthenticated,
          rawCode: 'UNAUTHENTICATED',
          message: 'Unauthenticated',
        );
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();

      final state = container.read(authProvider);
      expect(state.convexAuthStatus, ConvexAuthStatus.incident);
      expect(state.activeAuthIncidentId, isNotNull);
      expect(container.read(cloudOfflineProvider), isFalse);
    });

    test('a connected socket that never authenticates is still an incident',
        () async {
      convexApi
        ..connected = true
        ..reconnectResult = true;
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(authProvider);

      await waitUntil(
        () =>
            container.read(authProvider).convexAuthStatus ==
            ConvexAuthStatus.incident,
      );
      // At once, with no offline retries in between.
      expect(convexApi.setAuthCalls, 1);
    });
  });

  test(
      "signing out deletes that account's copies for this deployment, and "
      'nothing else', () async {
    supabaseApi.currentSession = fakeSession();
    final copy = _RecordingAccountCopy();
    final container = ProviderContainer(overrides: [
      cloudAccountCopiesProvider.overrideWithValue([copy]),
      cloudCopyDeploymentUrlProvider
          .overrideWithValue('https://example-1.convex.cloud'),
    ]);
    addTearDown(container.dispose);
    container.read(authProvider);
    await pumpMicrotasks();

    await container.read(authProvider.notifier).signOut();
    await pumpMicrotasks();

    expect(copy.deleted.toSet(), {
      const CloudCopyScope(
        deploymentUrl: 'https://example-1.convex.cloud',
        accountId: 'user-1',
      ),
    });
  });

  group('a refresh that cannot reach Supabase', () {
    setUp(() {
      supabaseApi.currentSession = fakeSession();
      convexApi.connected = false;
      convexApi.reconnectResult = false;
      convexApi.autoAuthenticateOnSetAuth = false;
      AuthProvider.debugOfflineRetryDelay = (_) => const Duration(hours: 1);
    });

    test('keeps an offline session offline, retrying', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();
      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.offline,
      );

      supabaseApi.emitError(AuthRetryableFetchException(message: 'offline'));
      await pumpMicrotasks();

      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.offline,
      );
      expect(container.read(authProvider).errorMessage, isNull);
      // Still retrying: the socket coming back sets up again.
      convexApi.reconnectSocket();
      await pumpMicrotasks();
      await pumpMicrotasks();
      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.ready,
      );
    });

    test('takes a session still setting up offline', () async {
      convexApi.setAuthCompleter = Completer<AuthProviderAuthHandle>();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider);
      await pumpMicrotasks();
      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.configuring,
      );

      supabaseApi.emitError(AuthRetryableFetchException(message: 'offline'));
      await pumpMicrotasks();

      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.offline,
      );
      convexApi.setAuthCompleter!.complete(FakeAuthHandle());
      await pumpMicrotasks();
    });

    test('leaves a ready session ready', () async {
      convexApi
        ..connected = true
        ..reconnectResult = true
        ..autoAuthenticateOnSetAuth = true;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();

      supabaseApi.emitError(AuthRetryableFetchException(message: 'offline'));
      await pumpMicrotasks();

      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.ready,
      );
    });

    test('a refresh Supabase refuses is still an incident', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();

      supabaseApi.emitError(
        const AuthApiException('Invalid Refresh Token', statusCode: '400'),
      );
      await pumpMicrotasks();

      expect(
        container.read(authProvider).convexAuthStatus,
        ConvexAuthStatus.incident,
      );
    });
  });

  group("the account's copies are deleted", () {
    late _RecordingAccountCopy copy;
    late ProviderContainer container;

    setUp(() async {
      supabaseApi.currentSession = fakeSession();
      copy = _RecordingAccountCopy();
      container = ProviderContainer(overrides: [
        cloudAccountCopiesProvider.overrideWithValue([copy]),
        cloudCopyDeploymentUrlProvider
            .overrideWithValue('https://example-1.convex.cloud'),
      ]);
      container.read(authProvider);
      await pumpMicrotasks();
    });

    tearDown(() => container.dispose());

    const user1 = CloudCopyScope(
      deploymentUrl: 'https://example-1.convex.cloud',
      accountId: 'user-1',
    );

    test('when Supabase ends the session itself', () async {
      supabaseApi.currentSession = null;
      supabaseApi.emit(AuthChangeEvent.signedOut, null);
      await pumpMicrotasks();

      expect(copy.deleted, contains(user1));
    });

    test('when another account signs in', () async {
      final other = fakeSession(userId: 'user-2', accessToken: 'other');
      supabaseApi.currentSession = other;
      supabaseApi.emit(AuthChangeEvent.signedIn, other);
      await pumpMicrotasks();

      expect(copy.deleted, contains(user1));
      expect(copy.deleted.map((scope) => scope.accountId), isNot('user-2'));
    });

    test('when signing out fails after Supabase signed out', () async {
      // Only this sign-out's own steps: the signedOut event is not here yet.
      supabaseApi.emitSignedOutOnSignOut = false;
      convexApi.clearAuthError = StateError('socket closed');

      await container.read(authProvider.notifier).signOut();

      expect(convexApi.clearAuthCalls, greaterThan(0));
      expect(copy.deleted, contains(user1));
    });

    test('not when the session is merely refreshed', () async {
      final refreshed = fakeSession(accessToken: 'refreshed');
      supabaseApi.currentSession = refreshed;
      supabaseApi.emit(AuthChangeEvent.tokenRefreshed, refreshed);
      await pumpMicrotasks();

      expect(copy.deleted, isEmpty);
    });
  });

  test(
      'a setup already waiting when Supabase turns out unreachable keeps '
      'retrying offline instead of ending in an incident', () async {
    // Convex is reachable but can't confirm the session: Supabase can't
    // refresh its token.
    supabaseApi.currentSession = fakeSession();
    convexApi
      ..connected = true
      ..reconnectResult = true
      ..autoAuthenticateOnSetAuth = false;
    AuthProvider.debugOfflineRetryDelay =
        (_) => const Duration(milliseconds: 20);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authProvider);
    await pumpMicrotasks();
    expect(
      container.read(authProvider).convexAuthStatus,
      ConvexAuthStatus.configuring,
    );

    supabaseApi.emitError(AuthRetryableFetchException(message: 'offline'));
    await pumpMicrotasks();
    expect(
      container.read(authProvider).convexAuthStatus,
      ConvexAuthStatus.offline,
    );

    // The first setup's wait runs out, then more than the slow-server
    // allowance of tries: still offline, never an incident.
    await waitUntil(() => convexApi.setAuthCalls >= 7);
    expect(
      container.read(authProvider).convexAuthStatus,
      ConvexAuthStatus.offline,
    );
    expect(container.read(authProvider).activeAuthIncidentId, isNull);

    // Supabase answers again and Convex confirms: ready.
    final refreshed = fakeSession(accessToken: 'refreshed');
    supabaseApi.currentSession = refreshed;
    convexApi.autoAuthenticateOnSetAuth = true;
    supabaseApi.emit(AuthChangeEvent.tokenRefreshed, refreshed);
    await waitUntil(
      () =>
          container.read(authProvider).convexAuthStatus ==
          ConvexAuthStatus.ready,
    );
  });

  group('a library list still open when the account ends', () {
    late MemoryCloudLibraryCopyStore store;
    late _LibraryRepository repository;
    late ProviderContainer container;

    setUp(() async {
      supabaseApi.currentSession = fakeSession();
      store = MemoryCloudLibraryCopyStore();
      repository = _LibraryRepository();
      container = ProviderContainer(overrides: [
        cloudLibraryCopyStoreProvider.overrideWithValue(store),
        cloudAccountCopiesProvider.overrideWith((ref) => [store]),
        cloudCopyDeploymentUrlProvider
            .overrideWithValue('https://example-1.convex.cloud'),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
      ]);
      container.read(authProvider);
      await pumpMicrotasks();
      await pumpMicrotasks();
      await container.read(convexConnectionProvider.future);
      container.listen(cloudStrategiesProvider, (_, __) {});
      await pumpMicrotasks();
      repository.strategies.add([_cloudEntry('s1')]);
      await pumpMicrotasks();
      expect(_accountKeys(store, 'user-1'), isNotEmpty);
    });

    tearDown(() => container.dispose());

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await pumpMicrotasks();
      }
    }

    test('does not write it back after Supabase signs it out', () async {
      supabaseApi.currentSession = null;
      supabaseApi.emit(AuthChangeEvent.signedOut, null);
      await settle();

      expect(_accountKeys(store, 'user-1'), isEmpty);
    });

    test('does not write it back after another account signs in', () async {
      final other = fakeSession(userId: 'user-2', accessToken: 'other');
      supabaseApi.currentSession = other;
      supabaseApi.emit(AuthChangeEvent.signedIn, other);
      await settle();

      expect(_accountKeys(store, 'user-1'), isEmpty);
    });

    test('does not write it back after signing out here', () async {
      await container.read(authProvider.notifier).signOut();
      await settle();

      expect(_accountKeys(store, 'user-1'), isEmpty);
    });

    test('keeps the account once it signs back in', () async {
      await container.read(authProvider.notifier).signOut();
      await settle();
      supabaseApi.currentSession = fakeSession(accessToken: 'again');
      supabaseApi.emit(AuthChangeEvent.signedIn, supabaseApi.currentSession);
      await settle();
      repository.strategies.add([_cloudEntry('s2')]);
      await settle();

      expect(_accountKeys(store, 'user-1'), isNotEmpty);
    });
  });
}

class _RecordingAccountCopy implements CloudAccountCopy {
  final deleted = <CloudCopyScope>[];

  @override
  Future<void> deleteAccount(CloudCopyScope scope) async {
    deleted.add(scope);
  }
}

const _upgradeRequired = ConvexFunctionException(
  code: ConvexErrorCode.clientUpgradeRequired,
  rawCode: 'CLIENT_UPGRADE_REQUIRED',
  message: 'Client upgrade required',
);

class _AcceptingRepository extends Fake implements ConvexStrategyRepository {
  @override
  Future<bool> serverAcceptsCloudProtocol() async => true;
}

/// Waits for [condition] on real time, failing after [timeout]: timer-driven
/// retries take as long as they take on a loaded machine.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> pumpMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Session fakeSession({
  String accessToken = 'test-token',
  String userId = 'user-1',
}) {
  final session = Session(
    accessToken: accessToken,
    refreshToken: 'refresh-token',
    tokenType: 'bearer',
    user: User(
      id: userId,
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
  Object? clearAuthError;
  bool reconnectResult = true;
  Completer<AuthProviderAuthHandle>? setAuthCompleter;
  final List<FakeAuthHandle> handles = <FakeAuthHandle>[];

  @override
  Stream<bool> get authState => _authStateController.stream;

  @override
  bool get isAuthenticated => _isAuthenticated;

  @override
  String? get currentConnectionStateLabel =>
      connected ? 'connected' : 'connecting';

  bool connected = true;
  final StreamController<bool> connectedController =
      StreamController<bool>.broadcast();

  @override
  bool get isConnected => connected;

  @override
  Stream<bool> get connectedChanges => connectedController.stream;

  /// The socket comes back, and the next setup goes through.
  void reconnectSocket() {
    connected = true;
    reconnectResult = true;
    autoAuthenticateOnSetAuth = true;
    connectedController.add(true);
  }

  @override
  Future<void> clearAuth() async {
    clearAuthCalls += 1;
    if (clearAuthError case final Object error?) {
      clearAuthError = null;
      throw error;
    }
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
  Future<void> ensureCurrentUser() async {
    mutationCalls += 1;
    lastMutationName = 'users:ensureCurrentUser';
    if (mutationError case final Object error?) {
      throw error;
    }
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
    final handle = FakeAuthHandle();
    handles.add(handle);
    return handle;
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
  bool emitSignedOutOnSignOut = true;
  bool emitSignedInEventOnPasswordSignIn = false;
  Session? sessionFromUrlSession;
  Object? sessionFromUrlError;
  Object? signUpError;
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
    if (sessionFromUrlError case final Object error?) {
      throw error;
    }
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
    if (!emitSignedOutOnSignOut) return;
    for (final controller in _controllers) {
      controller.add(AuthState(AuthChangeEvent.signedOut, currentSession));
    }
  }

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) async {
    if (signUpError case final Object error?) {
      throw error;
    }
    return AuthResponse(session: currentSession);
  }

  void emit(AuthChangeEvent event, Session? session) {
    for (final controller in _controllers) {
      controller.add(AuthState(event, session));
    }
  }

  void emitError(Object error) {
    for (final controller in _controllers) {
      controller.addError(error);
    }
  }

  Future<void> dispose() async {}
}

Iterable<String> _accountKeys(MemoryCloudLibraryCopyStore store, String id) =>
    store.values.keys.where((key) => key.contains('|$id|'));

CloudStrategyEntry _cloudEntry(String id) => (
      strategy: StrategyData(
        id: id,
        name: 'Strategy $id',
        mapData: MapValue.ascent,
        versionNumber: 1,
        lastEdited: DateTime(2026, 10, 1),
        folderID: null,
      ),
      revision: 1,
      role: 'owner',
      attackLabel: 'Attack',
    );

class _LibraryRepository extends Fake implements ConvexStrategyRepository {
  final strategies = StreamController<List<CloudStrategyEntry>>.broadcast();

  @override
  Stream<List<CloudFolderEntry>> watchAllFolders() => const Stream.empty();

  @override
  Stream<List<CloudStrategyEntry>> watchStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) =>
      strategies.stream;
}
