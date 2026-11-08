import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/context_menu_region.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _Menus extends StatelessWidget {
  const _Menus({this.controller});

  final ShadContextMenuController? controller;

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 40,
              top: 40,
              child: ContextMenuRegion(
                controller: controller,
                items: const [
                  ShadContextMenuItem(child: Text('First item')),
                  ShadContextMenuItem(
                    items: [ShadContextMenuItem(child: Text('Nested item'))],
                    child: Text('More'),
                  ),
                ],
                child: _target('first'),
              ),
            ),
            Positioned(
              left: 500,
              top: 400,
              child: ContextMenuRegion(
                items: const [ShadContextMenuItem(child: Text('Second item'))],
                child: _target('second'),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: ContextMenuRegion(
                items: const [ShadContextMenuItem(child: Text('Corner item'))],
                child: _target('corner'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _target(String key) => ColoredBox(
      key: ValueKey(key),
      color: Colors.white,
      child: const SizedBox.square(dimension: 40),
    );

Future<void> _rightClick(WidgetTester tester, String key) async {
  await tester.tap(
    find.byKey(ValueKey(key)),
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

/// The box of the menu holding [item], or of its submenu.
Rect _menuOf(WidgetTester tester, String item) => tester.getRect(
      find
          .ancestor(of: find.text(item), matching: find.byType(ShadDecorator))
          .last,
    );

void main() {
  // Windows opens the menu when the button comes up, not when it goes down.
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('a second right-click closes the first menu', (tester) async {
    await tester.pumpWidget(const _Menus());

    await _rightClick(tester, 'first');
    expect(find.text('First item'), findsOneWidget);

    await _rightClick(tester, 'second');
    expect(find.text('First item'), findsNothing);
    expect(find.text('Second item'), findsOneWidget);
  }, variant: windows);

  testWidgets('a left click on another region closes the open menu',
      (tester) async {
    await tester.pumpWidget(const _Menus());

    await _rightClick(tester, 'first');
    await tester.tap(find.byKey(const ValueKey('second')));
    await tester.pumpAndSettle();

    expect(find.text('First item'), findsNothing);
  }, variant: windows);

  testWidgets('a menu opened from code closes the open menu', (tester) async {
    final controller = ShadContextMenuController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_Menus(controller: controller));

    await _rightClick(tester, 'second');
    controller.show();
    await tester.pumpAndSettle();

    expect(find.text('Second item'), findsNothing);
    expect(find.text('First item'), findsOneWidget);
  }, variant: windows);

  testWidgets('a press inside a submenu keeps the menu open', (tester) async {
    await tester.pumpWidget(const _Menus());

    await _rightClick(tester, 'first');
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Nested item')),
    );
    await tester.pump();

    expect(find.text('First item'), findsOneWidget);
    expect(find.text('Nested item'), findsOneWidget);
    await gesture.up();
  }, variant: windows);

  testWidgets('a right-click opens the menu at its top-left corner',
      (tester) async {
    await tester.pumpWidget(const _Menus());

    await _rightClick(tester, 'first');

    final pointer = tester.getCenter(find.byKey(const ValueKey('first')));
    expect(_menuOf(tester, 'First item').topLeft, pointer);
  }, variant: windows);

  testWidgets('a right-click by the window corner keeps the menu on screen',
      (tester) async {
    await tester.pumpWidget(const _Menus());

    await _rightClick(tester, 'corner');

    final window = tester.view.physicalSize / tester.view.devicePixelRatio;
    final pointer = tester.getCenter(find.byKey(const ValueKey('corner')));
    final menu = _menuOf(tester, 'Corner item');
    // Opens upward from the pointer and moves left until it fits.
    expect(menu.bottom, pointer.dy);
    expect(menu.right, window.width);
  }, variant: windows);

  testWidgets('a submenu opens beside its row', (tester) async {
    await tester.pumpWidget(const _Menus());

    await _rightClick(tester, 'first');
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();

    final menu = _menuOf(tester, 'First item');
    final row = tester.getRect(find.text('More'));
    final nested = tester.getRect(find.text('Nested item'));
    expect(nested.left, greaterThan(menu.right));
    expect(nested.center.dy, closeTo(row.center.dy, 8));
  }, variant: windows);

  testWidgets('a menu opened from code opens below its region', (tester) async {
    final controller = ShadContextMenuController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_Menus(controller: controller));

    controller.show();
    await tester.pumpAndSettle();

    final region = tester.getRect(find.byKey(const ValueKey('first')));
    final menu = _menuOf(tester, 'First item');
    expect(menu.top, region.bottom + 4);
  }, variant: windows);

  testWidgets('a right-click after a menu opened from code moves it',
      (tester) async {
    final controller = ShadContextMenuController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_Menus(controller: controller));

    controller.show();
    await tester.pumpAndSettle();
    await _rightClick(tester, 'first');

    final pointer = tester.getCenter(find.byKey(const ValueKey('first')));
    expect(find.text('First item'), findsOneWidget);
    expect(_menuOf(tester, 'First item').topLeft, pointer);
    expect(controller.isOpen, isTrue);
  }, variant: windows);

  testWidgets('a right-click inside a nested navigator opens at the pointer',
      (tester) async {
    await tester.pumpWidget(
      ShadApp(
        home: Padding(
          padding: const EdgeInsets.only(left: 100, top: 50),
          child: Navigator(
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (_, __, ___) => Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: ContextMenuRegion(
                    items: const [
                      ShadContextMenuItem(child: Text('Inner item')),
                    ],
                    child: _target('inner'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await _rightClick(tester, 'inner');

    final pointer = tester.getCenter(find.byKey(const ValueKey('inner')));
    expect(_menuOf(tester, 'Inner item').topLeft, pointer);
  }, variant: windows);

  testWidgets('a menu opened from code after a right-click opens below',
      (tester) async {
    final controller = ShadContextMenuController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_Menus(controller: controller));

    await _rightClick(tester, 'first');
    await tester.tapAt(const Offset(700, 100));
    await tester.pumpAndSettle();
    expect(find.text('First item'), findsNothing);
    controller.show();
    await tester.pumpAndSettle();

    final region = tester.getRect(find.byKey(const ValueKey('first')));
    expect(_menuOf(tester, 'First item').top, region.bottom + 4);
  }, variant: windows);

  test('nothing builds a shadcn region, which centers its menu', () {
    final builders = <String>[
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            file.readAsStringSync().contains('ShadContextMenuRegion('))
          file.path.replaceAll(r'\', '/'),
    ];

    expect(builders, isEmpty);
  });
}
