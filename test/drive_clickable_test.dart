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
      _refused(
          'tapText "$_name": found 1, none can be tapped, asked for the 1st; the first '
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
      _refused(
          'tapText "Page 2": found 1, none can be tapped, asked for the 1st; the first '
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
        _refused(
            'tapText "Inner": found 1, none can be tapped, asked for the 1st; the first '
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

  testWidgets(
      'a match the hit test reaches but outside the window is refused as off '
      'screen', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(Stack(
      children: [
        Positioned(
          left: 1300,
          top: 300,
          child: GestureDetector(
            onTap: _counts('outside'),
            child: const Text(_name),
          ),
        ),
      ],
    )));
    tester.view.physicalSize = const Size(800, 600);

    expect(
      () => clickableCenterOf((w) => _isText(w, _name), what: 'tapText'),
      _refused('tapText: found 1, none can be tapped, asked for the 1st; the '
          'first that cannot: off screen, at'),
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

  testWidgets(
      'two matches that are one thing on screen count as two, as on main, and '
      'the second taps the same thing', (tester) async {
    await tester.pumpWidget(_app(Center(
      child: GestureDetector(
        onTap: _counts('page 1'),
        child:
            const KeyedSubtree(key: ValueKey('page-1'), child: Text('Page 1')),
      ),
    )));

    await tester.tapAt(clickableCenterOf(
      (widget) =>
          widget.key == const ValueKey('page-1') ||
          (widget is Text && widget.data == 'Page 1'),
      what: 'tapText "Page 1"',
      nth: 1,
      note: (line) => fail('no note expected: $line'),
    ));
    await tester.pumpAndSettle();

    expect(_taps, {'page 1': 1});
  });

  Widget disabledItem({required bool enabled}) => Listener(
        onPointerDown: (_) => _counts('press animation')(),
        child: MouseRegion(
          child: IgnorePointer(
            ignoring: !enabled,
            child: GestureDetector(
              onTap: _counts('delete'),
              child: const Text('Delete'),
            ),
          ),
        ),
      );

  testWidgets(
      'a disabled control is refused, and the refusal says how to mean it',
      (tester) async {
    await tester.pumpWidget(_app(Center(child: disabledItem(enabled: false))));

    await expectLater(
      () => _tapThroughDriver(tester, 'Delete'),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        endsWith('if the control is meant to be disabled, add "disabled": '
            'true'),
      )),
    );
    expect(_taps, isEmpty);
  });

  testWidgets(
      'with "disabled", a disabled control is pressed: only its wrapper hears '
      'the press, and nothing it holds runs', (tester) async {
    await tester.pumpWidget(_app(Center(child: disabledItem(enabled: false))));

    await tester.tapAt(clickableCenterOf(
      (widget) => _isText(widget, 'Delete'),
      what: 'tapText "Delete"',
      disabled: true,
    ));
    await tester.pumpAndSettle();

    expect(_taps, {'press animation': 1});
  });

  testWidgets('with "disabled", an enabled control fails as not disabled',
      (tester) async {
    await tester.pumpWidget(_app(Center(child: disabledItem(enabled: true))));

    expect(
      () => clickableCenterOf(
        (widget) => _isText(widget, 'Delete'),
        what: 'tapText "Delete"',
        disabled: true,
      ),
      _refused(
          'tapText "Delete": found 1, none disabled, asked for the 1st; the 1st is not '
          'disabled: its own handler takes the press'),
    );
  });

  testWidgets(
      'with "disabled", a disabled control under something else fails as '
      'covered', (tester) async {
    await tester.pumpWidget(_app(Stack(
      children: [
        Center(child: disabledItem(enabled: false)),
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('cover'),
            behavior: HitTestBehavior.opaque,
            onTap: _counts('cover'),
          ),
        ),
      ],
    )));

    expect(
      () => clickableCenterOf(
        (widget) => _isText(widget, 'Delete'),
        what: 'tapText "Delete"',
        disabled: true,
      ),
      _refused(
          'tapText "Delete": found 1, none disabled, asked for the 1st; the first that '
          "cannot be pressed: the tap goes to GestureDetector [<'cover'>]"),
    );
  });

  Widget underAnAppWideListener(Widget body) => Listener(
        onPointerDown: (_) => _counts('app-wide listener')(),
        child: _app(body),
      );

  testWidgets(
      'text with no handler of its own, under an app-wide listener, is refused '
      'where a slider covers it, and tapped where nothing does',
      (tester) async {
    await tester.pumpWidget(underAnAppWideListener(Stack(
      children: [
        const Positioned(left: 100, top: 100, child: Text('Covered')),
        const Positioned(left: 100, top: 300, child: Text('Uncovered')),
        Positioned(
          left: 50,
          top: 80,
          width: 300,
          height: 60,
          child: Slider(value: 0.5, onChanged: (_) => _counts('slider')()),
        ),
      ],
    )));

    expect(
      () => clickableCenterOf((w) => _isText(w, 'Covered'), what: 'tapText'),
      _refused('tapText: found 1, none can be tapped, asked for the 1st'),
    );
    await _tapThroughDriver(tester, 'Uncovered');
    expect(_taps, {'app-wide listener': 1});
  });

  testWidgets('with "disabled", an offstage control fails', (tester) async {
    await tester.pumpWidget(_app(Center(
      child: Listener(
        onPointerDown: (_) => _counts('press animation')(),
        child: MouseRegion(
          child: SizedBox(
            width: 200,
            height: 60,
            child: Offstage(child: disabledItem(enabled: false)),
          ),
        ),
      ),
    )));

    expect(
      () => clickableCenterOf((w) => _isText(w, 'Delete'),
          what: 'tapText "Delete"', disabled: true),
      _refused('tapText "Delete": found 1, none disabled'),
    );
  });

  testWidgets('with "disabled", a row its list clips away fails',
      (tester) async {
    await tester.pumpWidget(_app(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: 100,
        width: 300,
        child: ListView(
          children: [
            const SizedBox(height: 80),
            SizedBox(height: 80, child: disabledItem(enabled: false)),
          ],
        ),
      ),
    )));

    expect(
      () => clickableCenterOf((w) => _isText(w, 'Delete'),
          what: 'tapText "Delete"', disabled: true),
      _refused('tapText "Delete": found 1, none disabled'),
    );
    expect(_taps, isEmpty);
  });

  testWidgets('with "disabled", a control under another route fails',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: Scaffold(body: Center(child: disabledItem(enabled: false))),
    ));
    navigator.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: GestureDetector(
          key: const ValueKey('editor'),
          behavior: HitTestBehavior.opaque,
          onTap: _counts('editor'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(
      () => clickableCenterOf((w) => _isText(w, 'Delete'),
          what: 'tapText "Delete"', disabled: true),
      _refused('tapText "Delete": found 1, none disabled'),
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
