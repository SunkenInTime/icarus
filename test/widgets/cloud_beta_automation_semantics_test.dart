import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('auth dialog exposes stable fields and actions', (tester) async {
    final semanticsHandle = tester.ensureSemantics();
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
    expect(_textFieldNodes(tester), hasLength(2));
    expect(
      tester.getSemantics(find.byKey(const ValueKey('auth-email-field'))).label,
      'Email',
    );

    await tester.tap(find.byKey(const ValueKey('auth-mode-switch')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('auth-confirm-password-field')),
      findsOneWidget,
    );
    expect(_semanticsLabel('Confirm password'), findsOneWidget);
    expect(find.text('Create account'), findsAtLeastNWidgets(1));
    expect(_textFieldNodes(tester), hasLength(3));
    semanticsHandle.dispose();
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
    expect(_semantics('This Computer library').properties.onTap, isNotNull);
    expect(_semantics('Community library').properties.onTap, isNotNull);
    expect(_semantics('Log in to Icarus').properties.onTap, isNotNull);
  });

  testWidgets('signed-out cloud destinations open login', (tester) async {
    await tester.pumpWidget(
      _testApp(
        const SizedBox(
          width: 220,
          height: 800,
          child: LibraryNavigationRail(),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('library-cloud')));
    await tester.pumpAndSettle();

    expect(find.byType(AuthDialog), findsOneWidget);
    expect(find.text('Sign in'), findsAtLeastNWidgets(1));

    Navigator.of(tester.element(find.byType(AuthDialog))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('library-shared')));
    await tester.pumpAndSettle();

    expect(find.byType(AuthDialog), findsOneWidget);
  });
}

Semantics _semantics(String label) {
  return _semanticsLabel(label).evaluate().single.widget as Semantics;
}

List<SemanticsNode> _textFieldNodes(WidgetTester tester) {
  final nodes = <SemanticsNode>[];

  void visit(SemanticsNode node) {
    if (node.flagsCollection.isTextField) {
      nodes.add(node);
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  final root = tester
      .binding.renderViews.single.owner!.semanticsOwner!.rootSemanticsNode;
  if (root != null) {
    visit(root);
  }
  return nodes;
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
