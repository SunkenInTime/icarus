import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';

void main() {
  late String clipboardText;

  setUp(() {
    clipboardText = '';
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          return <String, dynamic>{'text': clipboardText};
        case 'Clipboard.setData':
          final arguments = call.arguments as Map<dynamic, dynamic>;
          clipboardText = arguments['text'] as String? ?? '';
        case 'Clipboard.hasStrings':
          return <String, bool>{'value': clipboardText.isNotEmpty};
      }
      return null;
    });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('renders without an opened app preferences Hive box',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TextEditingShortcutScope(
              child: TextField(),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl+V pastes text instead of invoking the app shortcut',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var pasteImageInvocations = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.keyV, control: true):
                  PasteImageIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                PasteImageIntent: CallbackAction<PasteImageIntent>(
                  onInvoke: (_) {
                    pasteImageInvocations++;
                    return null;
                  },
                ),
              },
              child: Scaffold(
                body: TextEditingShortcutScope(
                  child: TextField(controller: controller),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    clipboardText = 'https://youtu.be/example';

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(controller.text, 'https://youtu.be/example');
    expect(pasteImageInvocations, 0);
  });

  testWidgets('Ctrl+Z uses the text field undo history', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TextEditingShortcutScope(
              child: TextField(controller: controller, autofocus: true),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField), 'draft text');
    await tester.pump(const Duration(milliseconds: 500));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(controller.text, isEmpty);
  });

  testWidgets('field-specific shortcuts take priority over text defaults',
      (tester) async {
    var submitInvocations = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TextEditingShortcutScope(
              extraShortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.enter): EnterTextIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  EnterTextIntent: CallbackAction<EnterTextIntent>(
                    onInvoke: (_) {
                      submitInvocations++;
                      return null;
                    },
                  ),
                },
                child: const TextField(autofocus: true),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(submitInvocations, 1);
  });
}
