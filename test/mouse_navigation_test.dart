import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('mouse back does not navigate under an open Shad popover',
      (tester) async {
    final popoverController = ShadPopoverController();
    final unrelatedFocusNode = FocusNode();
    addTearDown(popoverController.dispose);
    addTearDown(unrelatedFocusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: ShadApp(
          navigatorKey: appNavigatorKey,
          navigatorObservers: [mouseNavigationRouteObserver],
          builder: (_, child) => MouseNavigation(child: child!),
          home: const Scaffold(body: Text('library')),
        ),
      ),
    );

    appNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/auxiliary'),
        builder: (_) => Scaffold(
          body: Stack(
            children: [
              TextField(focusNode: unrelatedFocusNode),
              ShadPopover(
                controller: popoverController,
                popover: (_) => const Text('menu'),
                child: const SizedBox.expand(child: Text('auxiliary')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    popoverController.show();
    await tester.pumpAndSettle();
    expect(find.text('menu'), findsOneWidget);
    unrelatedFocusNode.requestFocus();
    await tester.pump();
    expect(unrelatedFocusNode.hasFocus, isTrue);

    await tester.sendEventToBinding(
      const PointerDownEvent(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
        position: Offset(400, 300),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('auxiliary'), findsOneWidget);
    expect(find.text('library'), findsNothing);
  });

  testWidgets('mouse back does not navigate under an open Shad context menu',
      (tester) async {
    final menuController = ShadContextMenuController();
    final unrelatedFocusNode = FocusNode();
    addTearDown(menuController.dispose);
    addTearDown(unrelatedFocusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: ShadApp(
          navigatorKey: appNavigatorKey,
          navigatorObservers: [mouseNavigationRouteObserver],
          builder: (_, child) => MouseNavigation(child: child!),
          home: const Scaffold(body: Text('library')),
        ),
      ),
    );

    appNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/auxiliary'),
        builder: (_) => Scaffold(
          body: Stack(
            children: [
              TextField(focusNode: unrelatedFocusNode),
              ShadContextMenu(
                controller: menuController,
                items: const [ShadContextMenuItem(child: Text('menu item'))],
                child: const SizedBox.expand(child: Text('auxiliary')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    menuController.show();
    await tester.pumpAndSettle();
    expect(find.text('menu item'), findsOneWidget);
    unrelatedFocusNode.requestFocus();
    await tester.pump();
    expect(unrelatedFocusNode.hasFocus, isTrue);

    await tester.sendEventToBinding(
      const PointerDownEvent(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
        position: Offset(400, 300),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('auxiliary'), findsOneWidget);
    expect(find.text('library'), findsNothing);
  });
}
