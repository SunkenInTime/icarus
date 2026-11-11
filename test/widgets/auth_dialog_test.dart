import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/services/auth_callback_uri.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  setUp(() {
    _FakeAuthProvider.resetRequests = 0;
    _FakeAuthProvider.signInCompletion = null;
  });

  testWidgets('signing in after asking for a reset link closes only the dialog',
      (tester) async {
    await _openDialogOverPage(tester);

    await tester.tap(find.byKey(const ValueKey('auth-forgot-password')));
    await tester.pumpAndSettle();
    await tester.enterText(_field('auth-email-field'), 'a@b.co');
    await tester.tap(find.byKey(const ValueKey('auth-submit-button')));
    await tester.pumpAndSettle();
    expect(_FakeAuthProvider.resetRequests, 1);
    expect(find.text('Link sent.'), findsOneWidget);

    // They remember the password after all.
    await tester.tap(find.byKey(const ValueKey('auth-mode-switch')));
    await tester.pumpAndSettle();
    await tester.enterText(_field('auth-password-field'), 'secret');
    await tester.tap(find.byKey(const ValueKey('auth-submit-button')));
    await tester.pumpAndSettle();

    expect(find.byType(AuthDialog), findsNothing);
    expect(find.text('Settings page'), findsOneWidget);
  });

  testWidgets('a notice shows as good news or as a warning, then clears',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final (notice, icon) in [
      (AuthLinkNotice.emailConfirmed, LucideIcons.mailCheck),
      (AuthLinkNotice.linkExpired, LucideIcons.circleAlert),
    ]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authProvider.overrideWith(_FakeAuthProvider.new)],
          child: ShadApp(
            home: Scaffold(
              body: AuthDialog(key: ValueKey(notice), notice: notice),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(notice.message(_english)), findsOneWidget);
      expect(find.byIcon(icon), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('auth-mode-switch')));
    await tester.pumpAndSettle();
    expect(
        find.text(AuthLinkNotice.linkExpired.message(_english)), findsNothing);
  });

  testWidgets('a link landing while the dialog is open speaks through it',
      (tester) async {
    await _openDialogOverPage(tester);
    expect(AuthDialog.isOpen, isTrue);

    _container(tester)
        .read(authLinkNoticeProvider.notifier)
        .show(AuthLinkNotice.linkExpired);
    await tester.pumpAndSettle();

    expect(find.text(AuthLinkNotice.linkExpired.message(_english)),
        findsOneWidget);
    expect(find.byType(AuthDialog), findsOneWidget);
  });

  testWidgets('a link confirming the email moves the create form to sign-in',
      (tester) async {
    await _openDialogOverPage(tester);
    await tester.tap(find.byKey(const ValueKey('auth-mode-switch')));
    await tester.pumpAndSettle();
    await tester.enterText(_field('auth-email-field'), 'a@b.co');

    _container(tester)
        .read(authLinkNoticeProvider.notifier)
        .show(AuthLinkNotice.emailConfirmed);
    await tester.pumpAndSettle();

    expect(find.text(AuthLinkNotice.emailConfirmed.message(_english)),
        findsOneWidget);
    expect(find.text('Create account'), findsNothing);
    expect(find.text('a@b.co'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('auth-confirm-password-field')),
      findsNothing,
    );
  });

  testWidgets('a failed return while waiting for Discord is that sign-in failed',
      (tester) async {
    await _openDialogOverPage(tester);

    await tester.tap(find.byKey(const ValueKey('auth-discord-button')));
    await tester.pump(const Duration(milliseconds: 300));
    _container(tester)
        .read(authLinkNoticeProvider.notifier)
        .show(AuthLinkNotice.emailConfirmed);
    await tester.pumpAndSettle();

    expect(
      find.text('Failed to complete login. Please try again.'),
      findsOneWidget,
    );
    expect(find.text(AuthLinkNotice.emailConfirmed.message(_english)),
        findsNothing);
  });

  testWidgets('a reset link that timed out opens on asking for a new one',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authProvider.overrideWith(_FakeAuthProvider.new)],
        child: const ShadApp(
          home: Scaffold(
            body: AuthDialog(notice: AuthLinkNotice.resetLinkTimedOut),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(AuthLinkNotice.resetLinkTimedOut.message(_english)),
        findsOneWidget);
    expect(find.text('Send reset link'), findsOneWidget);
  });

  testWidgets('a sign-in landing after the dialog was dismissed keeps the page',
      (tester) async {
    _FakeAuthProvider.signInCompletion = Completer<void>();
    await _openDialogOverPage(tester);

    await tester.enterText(_field('auth-email-field'), 'a@b.co');
    await tester.enterText(_field('auth-password-field'), 'secret');
    await tester.tap(find.byKey(const ValueKey('auth-submit-button')));
    await tester.pump();

    // Dismissed while the sign-in is out; it lands mid close animation.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 30));
    _FakeAuthProvider.signInCompletion!.complete();
    await tester.pumpAndSettle();

    expect(find.byType(AuthDialog), findsNothing);
    expect(find.text('Settings page'), findsOneWidget);
  });

  testWidgets('an address with no domain ending is caught before Supabase',
      (tester) async {
    await _openDialogOverPage(tester);

    await tester.enterText(_field('auth-email-field'), 'foo@bar');
    await tester.enterText(_field('auth-password-field'), 'secret');
    await tester.tap(find.byKey(const ValueKey('auth-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Settings page'), findsOneWidget);
  });

  testWidgets('a plain password sign-in closes the dialog', (tester) async {
    await _openDialogOverPage(tester);

    await tester.enterText(_field('auth-email-field'), 'a@b.co');
    await tester.enterText(_field('auth-password-field'), 'secret');
    await tester.tap(find.byKey(const ValueKey('auth-submit-button')));
    await tester.pumpAndSettle();

    expect(find.byType(AuthDialog), findsNothing);
    expect(find.text('Settings page'), findsOneWidget);
  });
}

Finder _field(String key) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(EditableText),
    );

/// Home, then a page the dialog opens over, then the dialog.
ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(AuthDialog)));

Future<void> _openDialogOverPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authProvider.overrideWith(_FakeAuthProvider.new)],
      child: ShadApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Home page')),
      ),
    ),
  );
  navigatorKey.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Settings page')),
    ),
  );
  await tester.pumpAndSettle();
  showShadDialog<bool>(
    context: navigatorKey.currentContext!,
    builder: (_) => const AuthDialog(),
  );
  await tester.pumpAndSettle();
  expect(find.byType(AuthDialog), findsOneWidget);
}

/// Signs in the way Supabase does: the session lands in the auth state as
/// the request returns.
class _FakeAuthProvider extends AuthProvider {
  static int resetRequests = 0;
  static Completer<void>? signInCompletion;

  @override
  Future<void> signInWithDiscord() async {}

  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );

  @override
  Future<String?> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    await signInCompletion?.future;
    state = state.copyWith(
      isAuthenticated: true,
      convexAuthStatus: ConvexAuthStatus.configuring,
    );
    return null;
  }

  @override
  Future<({String message, bool sent})> sendPasswordReset(String email) async {
    resetRequests++;
    return (message: 'Link sent.', sent: true);
  }
}

final _english = lookupAppLocalizations(const Locale('en'));
