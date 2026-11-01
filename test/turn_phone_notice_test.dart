import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/turn_phone_notice.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _EditorKeyIntent extends Intent {
  const _EditorKeyIntent();
}

void main() {
  // The app's shortcuts sit above every screen, as GlobalShortcuts does.
  Future<(List<String>, List<String>)> pumpNotice(WidgetTester tester) async {
    final editorKeys = <String>[];
    final left = <String>[];
    await tester.pumpWidget(
      ShadApp(
        builder: (context, child) => Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyE): _EditorKeyIntent(),
            SingleActivator(LogicalKeyboardKey.delete): _EditorKeyIntent(),
            SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                _EditorKeyIntent(),
          },
          child: Actions(
            actions: {
              _EditorKeyIntent: CallbackAction<_EditorKeyIntent>(
                onInvoke: (_) {
                  editorKeys.add('reached the editor');
                  return null;
                },
              ),
            },
            child: child!,
          ),
        ),
        home: Scaffold(
          body: TurnPhoneNotice(onLeave: () => left.add('left')),
        ),
      ),
    );
    await tester.pump();
    return (editorKeys, left);
  }

  testWidgets('keys never reach the editor it covers', (tester) async {
    final (editorKeys, _) = await pumpNotice(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(editorKeys, isEmpty);
  });

  testWidgets('a keyboard can still reach the way out', (tester) async {
    final (_, left) = await pumpNotice(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(left, ['left']);
  });
}
