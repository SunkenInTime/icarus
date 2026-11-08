import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/caption_card.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';

class _TestStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: true,
        stratName: null,
        id: 'caption-writing-test',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

class _Preferences extends AppPreferencesNotifier {
  @override
  AppPreferences build() => AppPreferences(
        defaultThemeProfileIdForNewStrategies: 'theme',
        showCaptions: true,
      );
}

/// What the app's shortcuts would do with a key, counted.
class _Shortcut extends Intent {
  const _Shortcut(this.key);
  final String key;
}

class _Rig {
  _Rig(this.container, this.canvas);

  final ProviderContainer container;

  /// Where the keyboard is while the user works on the map.
  final FocusNode canvas;
  final fired = <String>[];

  OpenCaption? get card => container.read(captionCardProvider);
  String? get caption => placedItemById(container, 'agent')?.caption;

  void startWriting() => container
      .read(captionCardProvider.notifier)
      .startWriting('agent', currentCaptionPlace(container));

  /// Create caption, then long enough for the field's last grab at focus.
  Future<void> write(WidgetTester tester) async {
    startWriting();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<_Rig> _pump(
  WidgetTester tester, {
  String? caption,
  bool canEdit = true,
  bool appShortcuts = false,
}) async {
  final container = ProviderContainer(overrides: [
    strategyProvider.overrideWith(_TestStrategyProvider.new),
    appPreferencesProvider.overrideWith(_Preferences.new),
    if (!canEdit)
      currentStrategyCapabilitiesProvider.overrideWithValue(
        StrategyCapabilities.fromCloudRole('viewer'),
      ),
  ]);
  addTearDown(container.dispose);
  container.read(agentProvider.notifier).fromHive([
    PlacedAgent(id: 'agent', type: AgentType.jett, position: Offset.zero)
      ..caption = caption,
  ]);
  final controller = TransformationController();
  addTearDown(controller.dispose);
  final canvas = FocusNode(debugLabel: 'canvas');
  addTearDown(canvas.dispose);
  final rig = _Rig(container, canvas);

  Widget shortcuts(Widget child) => appShortcuts
      ? GlobalShortcuts(child: child)
      // Stands in for GlobalShortcuts: E deletes and X turns what's under
      // the pointer.
      : Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyE): _Shortcut('E'),
            SingleActivator(LogicalKeyboardKey.keyX): _Shortcut('X'),
          },
          child: Actions(
            actions: {
              _Shortcut: CallbackAction<_Shortcut>(
                onInvoke: (intent) => rig.fired.add(intent.key),
              ),
            },
            child: child,
          ),
        );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: shortcuts(
          Scaffold(
            body: CanvasItemRegistryScope(
              registry: container.read(canvasItemRegistryProvider),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Focus(
                      focusNode: canvas,
                      autofocus: true,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  const Positioned(
                    left: 300,
                    top: 400,
                    width: 40,
                    height: 40,
                    child: ItemOutlineScope(
                      id: 'agent',
                      kind: SelectableKind.agent,
                      child: EditorItemOutline(child: SizedBox.expand()),
                    ),
                  ),
                  Positioned.fill(
                    child: CaptionCardLayer(transformation: controller),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return rig;
}

Future<void> _ctrlEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

EditableText _field(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText));

void main() {
  testWidgets(
      'Create caption opens the card with the cursor in it, even when the '
      'closing menu hands the keyboard back to the canvas', (tester) async {
    final rig = await _pump(tester);
    rig.startWriting();
    await tester.pump();
    // The menu closes a frame later and puts the keyboard back on the canvas.
    rig.canvas.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Jett'), findsOneWidget);
    expect(_field(tester).focusNode.hasFocus, isTrue);
  });

  testWidgets("letters typed into a note don't fire the app's shortcuts",
      (tester) async {
    final rig = await _pump(tester);
    // On the map they do.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    expect(rig.fired, ['E']);
    rig.fired.clear();

    await rig.write(tester);

    for (final key in [
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.enter,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.pump();

    expect(rig.fired, isEmpty);
    // Tab didn't carry the keyboard out, and Enter didn't end the note.
    expect(_field(tester).focusNode.hasFocus, isTrue);
    expect(rig.card?.writing, isTrue);
  });

  testWidgets('Ctrl+Enter saves the note and closes the card', (tester) async {
    final rig = await _pump(tester);
    await rig.write(tester);

    await tester.enterText(
        find.byType(EditableText), '  Smoke B main\nthen go ');
    await _ctrlEnter(tester);

    expect(rig.caption, 'Smoke B main\nthen go');
    expect(rig.card, isNull);
  });

  testWidgets('a press off the card saves the note', (tester) async {
    final rig = await _pump(tester);
    await rig.write(tester);

    await tester.enterText(find.byType(EditableText), 'Lurk');
    await tester.tapAt(const Offset(700, 580));
    await tester.pump();

    expect(rig.caption, 'Lurk');
    expect(rig.card, isNull);
  });

  testWidgets('a press on the card keeps writing', (tester) async {
    final rig = await _pump(tester);
    await rig.write(tester);

    await tester.tap(find.text('Jett'));
    await tester.pump();

    expect(rig.card?.writing, isTrue);
    expect(_field(tester).focusNode.hasFocus, isTrue);
  });

  testWidgets('Escape drops what was typed', (tester) async {
    final rig = await _pump(tester, caption: 'Note');
    await rig.write(tester);

    await tester.enterText(find.byType(EditableText), 'Something else');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(rig.caption, 'Note');
    expect(rig.card, isNull);
  });

  testWidgets('clearing the text removes the caption', (tester) async {
    final rig = await _pump(tester, caption: 'Note');
    await rig.write(tester);
    expect(_field(tester).controller.text, 'Note');

    await tester.enterText(find.byType(EditableText), '   ');
    await _ctrlEnter(tester);

    expect(rig.caption, '');
  });

  testWidgets('a note being written stays open whatever the pointer does',
      (tester) async {
    final rig = await _pump(tester);
    await rig.write(tester);
    final card = rig.container.read(captionCardProvider.notifier);

    card.itemEntered('other', 'region');
    card.cardExited();
    card.closeNow();
    await tester.pump(const Duration(seconds: 1));

    expect(rig.card?.writing, isTrue);
  });

  testWidgets('an editor clicks into a card to write, at the spot clicked',
      (tester) async {
    final rig = await _pump(tester, caption: 'Smoke B main');
    rig.container.read(captionCardProvider.notifier).openNow('agent');
    await tester.pump();

    await tester.tapAt(
        tester.getTopLeft(find.text('Smoke B main')) + const Offset(2, 8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(rig.card?.writing, isTrue);
    expect(_field(tester).focusNode.hasFocus, isTrue);
    expect(_field(tester).controller.selection.baseOffset, 0);
  });

  testWidgets("a reader who can't edit clicks a card and nothing changes",
      (tester) async {
    final rig = await _pump(tester, caption: 'Smoke B main', canEdit: false);
    rig.container.read(captionCardProvider.notifier).openNow('agent');
    await tester.pump();

    await tester.tap(find.text('Smoke B main'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(rig.card?.writing, isFalse);
    expect(find.byType(EditableText), findsNothing);
  });

  testWidgets(
      "E deletes the item under the pointer, but not while a note is being "
      'written, even before the keyboard reaches the note', (tester) async {
    final rig = await _pump(tester, appShortcuts: true);
    void hoverAgent() =>
        rig.container.read(hoveredDeleteTargetProvider.notifier).state =
            HoveredDeleteTarget.agent(id: 'agent', ownerToken: 'test');

    rig.startWriting();
    await tester.pump();
    // The menu closing puts the keyboard back on the map.
    rig.canvas.requestFocus();
    await tester.pump();
    expect(rig.canvas.hasFocus, isTrue);
    hoverAgent();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump(const Duration(milliseconds: 300));
    expect(rig.caption, isNull);
    expect(placedItemById(rig.container, 'agent'), isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(rig.card, isNull);

    // Back on the map, E deletes it.
    rig.canvas.requestFocus();
    hoverAgent();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();
    expect(placedItemById(rig.container, 'agent'), isNull);
  });

  testWidgets(
      "Escape with the field's menu open closes the menu and keeps the note",
      (tester) async {
    final rig = await _pump(tester);
    await rig.write(tester);
    await tester.enterText(find.byType(EditableText), 'Keep this');
    final field = tester.state<EditableTextState>(find.byType(EditableText));
    field.showToolbar();
    await tester.pumpAndSettle();
    expect(field.selectionOverlay?.toolbarIsVisible, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(field.selectionOverlay?.toolbarIsVisible ?? false, isFalse);
    expect(rig.card?.writing, isTrue);
    expect(_field(tester).controller.text, 'Keep this');
  });

  testWidgets("a press on the field's menu is a press in the note",
      (tester) async {
    final rig = await _pump(tester);
    await rig.write(tester);
    await tester.enterText(find.byType(EditableText), 'Smoke');
    final field = tester.state<EditableTextState>(find.byType(EditableText));
    field.selectAll(SelectionChangedCause.toolbar);
    field.showToolbar();
    await tester.pumpAndSettle();

    final button = find.text('Cut');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(rig.card?.writing, isTrue);
    expect(_field(tester).controller.text, '');
  });
}
