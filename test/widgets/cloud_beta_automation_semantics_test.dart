import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('auth dialog exposes stable fields and actions', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp(const AuthDialog()));

    expect(find.byKey(const ValueKey('auth-email-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-password-field')), findsOneWidget);
    expect(_semanticsLabel('Email'), findsOneWidget);
    expect(_semanticsLabel('Password'), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-mode-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-discord-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-submit-button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auth-mode-switch')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('auth-confirm-password-field')),
      findsOneWidget,
    );
    expect(_semanticsLabel('Confirm password'), findsOneWidget);
    expect(find.text('Create account'), findsAtLeastNWidgets(1));
  });

  testWidgets('library rail exposes stable destinations while signed out',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        const SizedBox(
          width: 220,
          height: 800,
          child: LibraryNavigationRail(),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('library-local')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-cloud')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-shared')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-community')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-account-action')),
      findsOneWidget,
    );
    expect(_semanticsLabel('This Computer library'), findsOneWidget);
    expect(_semanticsLabel('Cloud library'), findsOneWidget);
    expect(_semanticsLabel('Shared library'), findsOneWidget);
    expect(_semanticsLabel('Community library'), findsOneWidget);
    expect(_semanticsLabel('Log in to Icarus'), findsOneWidget);
  });
}

Finder _semanticsLabel(String label) {
  return find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  );
}

Widget _testApp(Widget child) {
  return ProviderScope(
    overrides: [
      authProvider.overrideWith(_SignedOutAuthProvider.new),
    ],
    child: ShadApp(
      home: Scaffold(body: child),
    ),
  );
}

class _SignedOutAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );
}
