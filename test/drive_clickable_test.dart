import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/clickable.dart';

const _name = 'Strategy B';

bool _isName(Widget widget) => widget is Text && widget.data == _name;

class _Library extends StatelessWidget {
  const _Library();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(padding: EdgeInsets.all(200), child: Text(_name)),
        ),
      );
}

class _Editor extends StatelessWidget {
  const _Editor({required this.switcherShowsName});

  final bool switcherShowsName;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('switcher-barrier'),
                behavior: HitTestBehavior.opaque,
                onTap: () {},
              ),
            ),
            if (switcherShowsName)
              const Positioned(left: 600, top: 40, child: Text(_name)),
          ],
        ),
      );
}

Future<void> _editorOverLibrary(
  WidgetTester tester, {
  required bool switcherShowsName,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester
      .pumpWidget(MaterialApp(navigatorKey: navigator, home: const _Library()));
  navigator.currentState!.push(MaterialPageRoute<void>(
    maintainState: true,
    builder: (_) => _Editor(switcherShowsName: switcherShowsName),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'the first match in the tree is the tile on the library under the '
      'editor; the one a click reaches is the switcher item', (tester) async {
    await _editorOverLibrary(tester, switcherShowsName: true);

    final matches = screenMatches(_isName);
    expect(matches, hasLength(2));
    expect(clickReaches(matches.first.box, matches.first.at), isFalse,
        reason: 'the old helper tapped this one');

    final notes = <String>[];
    final picked = clickableCenterOf(_isName, what: 'tapText', note: notes.add);

    expect(picked, matches.last.at);
    expect(picked, tester.getCenter(find.text(_name).last));
    expect(notes.single, contains('covered by'));
  });

  testWidgets(
      'with the name only on the library under the editor, the step fails '
      'and says what covers it', (tester) async {
    await _editorOverLibrary(tester, switcherShowsName: false);

    expect(screenMatches(_isName), hasLength(1));
    expect(
      () => clickableCenterOf(_isName, what: 'tapText "$_name"'),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        allOf(
          contains('tapText "$_name": found 1, all covered by'),
          contains("switcher-barrier"),
        ),
      )),
    );
  });

  testWidgets(
      'text inside a control that ignores pointers is tapped, since the click '
      'lands on the control around it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: GestureDetector(
            key: const ValueKey('delete-item'),
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: const Opacity(
              opacity: 0.5,
              child: IgnorePointer(
                child: Padding(padding: EdgeInsets.all(8), child: Text(_name)),
              ),
            ),
          ),
        ),
      ),
    ));

    expect(
      clickableCenterOf(_isName, what: 'tapText "$_name"'),
      tester.getCenter(find.text(_name)),
    );
  });

  testWidgets('a match below the bottom of the window fails as off screen',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Transform.translate(
          offset: const Offset(0, 2000),
          child: const Text(_name),
        ),
      ),
    ));

    expect(
      () => clickableCenterOf(_isName, what: 'tapText "$_name"'),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        startsWith('tapText "$_name": found 1, all off screen, at'),
      )),
    );
  });

  testWidgets('asking past the last match says how many there are',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _Library()));

    expect(
      () => clickableCenterOf(_isName, what: 'tapText "$_name"', nth: 1),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        'tapText "$_name": found 1',
      )),
    );
  });

  testWidgets('a menu drawn in an overlay with no route of its own counts',
      (tester) async {
    final menu = OverlayPortalController()..show();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OverlayPortal(
          controller: menu,
          overlayChildBuilder: (_) => const Positioned(
            left: 300,
            top: 300,
            child: Text(_name),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    ));

    expect(
      clickableCenterOf(_isName, what: 'tapText'),
      tester.getCenter(find.text(_name)),
    );
  });
}
