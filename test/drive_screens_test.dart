import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/drive_screens.dart';

String? rowKind(Widget widget) => switch (widget.key) {
      ValueKey<String>(:final value) when value.startsWith('row ') => 'row',
      _ => null,
    };

Widget rows({required int count}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          height: 300,
          child: ListView(
            children: [
              for (var n = 0; n < count; n++)
                SizedBox(
                  key: ValueKey('row $n'),
                  height: 100,
                  child: Text('row $n'),
                ),
            ],
          ),
        ),
      ),
    );

void main() {
  testWidgets('only rows that show in the viewport are on screen',
      (tester) async {
    await tester.pumpWidget(rows(count: 40));
    expect(find.text('row 4', skipOffstage: false), findsOneWidget);
    expect(
      [for (final item in drawnOnScreen(rowKind)) item.drawn],
      ['"row 0"', '"row 1"', '"row 2"'],
    );
    await tester.drag(find.byType(ListView), const Offset(0, -150));
    await tester.pump();
    expect(
      [for (final item in drawnOnScreen(rowKind)) item.drawn],
      ['"row 1"', '"row 2"', '"row 3"', '"row 4"'],
    );
  });

  testWidgets('what a root draws leaves out the parts scrolled out of view',
      (tester) async {
    await tester.pumpWidget(
      KeyedSubtree(key: const ValueKey('row list'), child: rows(count: 40)),
    );
    expect(
      [for (final item in drawnOnScreen(rowKind)) item.drawn],
      ['"row 0" "row 1" "row 2"'],
    );
  });

  testWidgets(
      'rows under a page pushed over them are not on screen, rows under a dialog are',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: rows(count: 3)),
    );
    expect(drawnOnScreen(rowKind), hasLength(3));
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const Text('over'),
    );
    await tester.pumpAndSettle();
    expect(drawnOnScreen(rowKind), hasLength(3));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('editor')),
    );
    await tester.pumpAndSettle();
    expect(drawnOnScreen(rowKind), isEmpty);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(drawnOnScreen(rowKind), hasLength(3));
  });

  test('a listener added twice is heard until it is removed twice', () {
    final source = ValueNotifier(0);
    final counted = countedForDrive(source, 'twice');
    var heard = 0;
    void listener() => heard++;
    counted
      ..addListener(listener)
      ..addListener(listener);
    source.value = 1;
    expect(heard, 2);
    counted.removeListener(listener);
    source.value = 2;
    expect(heard, 3);
    counted.removeListener(listener);
    source.value = 3;
    expect(heard, 3);
  });
}
