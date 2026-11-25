import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/clickable.dart';

const _name = 'Strategy B';

bool _isText(Widget widget, String text) =>
    widget is Text && widget.data == text;

final _taps = <String, int>{};

VoidCallback _counts(String who) => () => _taps[who] = (_taps[who] ?? 0) + 1;

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

Future<void> _tapThroughDriver(WidgetTester tester, String text,
    {int nth = 0}) async {
  await tester.tapAt(clickableCenterOf(
    (widget) => _isText(widget, text),
    what: 'tapText "$text"',
    nth: nth,
  ));
  await tester.pumpAndSettle();
}

Matcher _refused(String start) => throwsA(isA<StateError>()
    .having((error) => error.message, 'message', startsWith(start)));

void main() {
  setUp(_taps.clear);

  Future<void> editorOverLibrary(
    WidgetTester tester, {
    required bool switcherShowsName,
  }) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(200),
            child: InkWell(
                onTap: _counts('library tile'), child: const Text(_name)),
          ),
        ),
      ),
    ));
    navigator.currentState!.push(MaterialPageRoute<void>(
      maintainState: true,
      builder: (_) => Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('switcher-barrier'),
                behavior: HitTestBehavior.opaque,
                onTap: _counts('barrier'),
              ),
            ),
            if (switcherShowsName)
              Positioned(
                left: 600,
                top: 40,
                child: GestureDetector(
                  onTap: _counts('switcher item'),
                  child: const Text(_name),
                ),
              ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'with the name on the library under the editor and in the switcher, '
      'the tap goes to the switcher item', (tester) async {
    await editorOverLibrary(tester, switcherShowsName: true);
    final notes = <String>[];

    final at = clickableCenterOf((w) => _isText(w, _name),
        what: 'tapText', note: notes.add);
    await tester.tapAt(at);
    await tester.pumpAndSettle();

    expect(_taps, {'switcher item': 1});
    expect(
      notes.single,
      allOf(
        contains('the 1st match that can be tapped is the 2nd of 2'),
        contains("the tap goes to GestureDetector [<'switcher-barrier'>]"),
      ),
    );
  });

  testWidgets(
      'with the name only on the library under the editor, the step is '
      'refused and names the barrier that would take the tap', (tester) async {
    await editorOverLibrary(tester, switcherShowsName: false);

    await expectLater(
      () => _tapThroughDriver(tester, _name),
      _refused('tapText "$_name": found 1, none can be tapped; the first '
          "that cannot: the tap goes to GestureDetector [<'switcher-barrier'>]"),
    );
    expect(_taps, isEmpty);
  });

  testWidgets(
      'a page label under the open switcher is refused: the switcher\'s '
      'translucent dismissal takes the tap', (tester) async {
    await tester.pumpWidget(_app(Stack(
      children: [
        Positioned(
          left: 100,
          top: 100,
          child: GestureDetector(
            onTap: _counts('page 2'),
            child: const Text('Page 2'),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('switcher-dismissal'),
            behavior: HitTestBehavior.translucent,
            onTap: _counts('dismissal'),
          ),
        ),
      ],
    )));

    await expectLater(
      () => _tapThroughDriver(tester, 'Page 2'),
      _refused('tapText "Page 2": found 1, none can be tapped; the first '
          "that cannot: the tap goes to GestureDetector "
          "[<'switcher-dismissal'>]"),
    );
    expect(_taps, isEmpty);
  });

  testWidgets(
      'a translucent listener over the page that only follows the pointer, as '
      'the presence cursor reporter does, takes no tap and does not hide the '
      'button under it', (tester) async {
    await tester.pumpWidget(_app(Stack(
      children: [
        Positioned(
          left: 100,
          top: 100,
          child: GestureDetector(
            onTap: _counts('next'),
            child: const Text('Next'),
          ),
        ),
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerHover: (_) {},
            onPointerMove: (_) {},
          ),
        ),
      ],
    )));

    await _tapThroughDriver(tester, 'Next');

    expect(_taps, {'next': 1});
  });

  testWidgets(
      'text in a disabled item that ignores pointers is tapped, and the '
      'item takes the tap', (tester) async {
    await tester.pumpWidget(_app(Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _counts('disabled item'),
        child: const Opacity(
          opacity: 0.5,
          child: IgnorePointer(
            child: Padding(padding: EdgeInsets.all(8), child: Text('Delete')),
          ),
        ),
      ),
    )));

    await _tapThroughDriver(tester, 'Delete');

    expect(_taps, {'disabled item': 1});
  });

  for (final (label, hide) in [
    ('Offstage', (Widget child) => Offstage(child: child)),
    (
      'Visibility that keeps its state',
      (Widget child) =>
          Visibility(visible: false, maintainState: true, child: child),
    ),
    ('AbsorbPointer', (Widget child) => AbsorbPointer(child: child)),
    (
      'IgnorePointer two levels down',
      (Widget child) => Padding(
            padding: EdgeInsets.zero,
            child: IgnorePointer(child: SizedBox(child: child)),
          ),
    ),
  ]) {
    testWidgets(
        'a control inside $label within an outer detector is refused, and '
        'the outer detector is not tapped instead', (tester) async {
      await tester.pumpWidget(_app(GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _counts('outer'),
        child: Center(
          child: hide(GestureDetector(
            onTap: _counts('inner'),
            child: const Text('Inner'),
          )),
        ),
      )));

      await expectLater(
        () => _tapThroughDriver(tester, 'Inner'),
        _refused('tapText "Inner": found 1, none can be tapped; the first '
            'that cannot: the tap goes to GestureDetector'),
      );
      expect(_taps, isEmpty);
    });
  }

  testWidgets('a row whose middle the list clips away is refused',
      (tester) async {
    await tester.pumpWidget(_app(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: 100,
        width: 300,
        child: ListView(
          children: [
            for (final row in ['Row 1', 'Row 2'])
              SizedBox(
                height: 80,
                child: InkWell(onTap: _counts(row), child: Text(row)),
              ),
          ],
        ),
      ),
    )));

    await _tapThroughDriver(tester, 'Row 1');
    await expectLater(
      () => _tapThroughDriver(tester, 'Row 2'),
      _refused('tapText "Row 2": found 1, none can be tapped'),
    );
    expect(_taps, {'Row 1': 1});
  });

  testWidgets('a menu drawn in an overlay with no route of its own is tapped',
      (tester) async {
    final menu = OverlayPortalController()..show();
    await tester.pumpWidget(_app(OverlayPortal(
      controller: menu,
      overlayChildBuilder: (_) => Positioned(
        left: 300,
        top: 300,
        child: GestureDetector(
            onTap: _counts('menu item'), child: const Text('Rename')),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _counts('page'),
        child: const SizedBox.expand(),
      ),
    )));

    await _tapThroughDriver(tester, 'Rename');

    expect(_taps, {'menu item': 1});
  });

  testWidgets('a match moved below the bottom of the window is off screen',
      (tester) async {
    await tester.pumpWidget(_app(Transform.translate(
      offset: const Offset(0, 2000),
      child: GestureDetector(onTap: _counts('below'), child: const Text(_name)),
    )));

    await expectLater(
      () => _tapThroughDriver(tester, _name),
      _refused('tapText "$_name": found 1, none can be tapped; the first '
          'that cannot: off screen, at'),
    );
    expect(_taps, isEmpty);
  });

  testWidgets(
      'a control painted away from where it takes taps is refused, and what '
      'is under its painted middle is not tapped', (tester) async {
    await tester.pumpWidget(_app(GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _counts('outer'),
      child: Align(
        alignment: Alignment.topLeft,
        child: Transform.translate(
          offset: const Offset(300, 200),
          transformHitTests: false,
          child: GestureDetector(
              onTap: _counts('moved'), child: const Text('Moved')),
        ),
      ),
    )));

    await expectLater(
      () => _tapThroughDriver(tester, 'Moved'),
      _refused('tapText "Moved": found 1, none can be tapped'),
    );
    expect(_taps, isEmpty);
  });

  testWidgets(
      'nth counts the matches that can be tapped, and a refusal says how many '
      'were found, how many can be tapped and which was asked for',
      (tester) async {
    await tester.pumpWidget(_app(Stack(
      children: [
        for (final (index, left) in [100.0, 300.0, 500.0].indexed)
          Positioned(
            left: left,
            top: 100,
            child: GestureDetector(
              onTap: _counts('label ${index + 1}'),
              child: const Text('Label'),
            ),
          ),
        Positioned(
          left: 0,
          top: 0,
          width: 200,
          height: 300,
          child: GestureDetector(
            key: const ValueKey('cover'),
            behavior: HitTestBehavior.opaque,
            onTap: _counts('cover'),
          ),
        ),
      ],
    )));

    await _tapThroughDriver(tester, 'Label', nth: 1);
    expect(_taps, {'label 3': 1});
    await expectLater(
      () => _tapThroughDriver(tester, 'Label', nth: 2),
      _refused('tapText "Label": found 3, 2 can be tapped, asked for the 3rd; '
          "the first that cannot: the tap goes to GestureDetector [<'cover'>]"),
    );
  });

  testWidgets('asking past the last match says how many there are',
      (tester) async {
    await tester.pumpWidget(_app(const Center(child: Text(_name))));

    await expectLater(
      () => _tapThroughDriver(tester, _name, nth: 1),
      _refused(
          'tapText "$_name": found 1, all can be tapped, asked for the 2nd'),
    );
  });
}
