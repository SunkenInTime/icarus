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

  test('only ContextMenuRegion builds a shadcn region', () {
    final builders = <String>[
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            file.readAsStringSync().contains('ShadContextMenuRegion('))
          file.path.replaceAll(r'\', '/'),
    ];

    expect(builders, ['lib/widgets/context_menu_region.dart']);
  });
}
