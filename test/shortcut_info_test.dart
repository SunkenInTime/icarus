import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/shortcut_info.dart';

void main() {
  test('primary modifier displays as the active platform modifier', () {
    const binding = IcarusKeyBinding(
      trigger: LogicalKeyboardKey.keyS,
      primary: true,
    );

    expect(binding.displayLabel(platform: TargetPlatform.windows), 'Ctrl S');
    expect(binding.displayLabel(platform: TargetPlatform.macOS), 'Cmd S');
  });

  test('duplicate lookup compares logical primary bindings', () {
    final duplicate = ShortcutInfo.findDuplicateBinding(
      editingShortcutId: IcarusShortcutAction.draw.name,
      binding: const IcarusKeyBinding(trigger: LogicalKeyboardKey.keyD),
      customBindings: const {},
    );

    expect(duplicate?.action, IcarusShortcutAction.forwardPage);
  });

  test('duplicate lookup rejects reserved undo and redo bindings', () {
    final undoDuplicate = ShortcutInfo.findDuplicateBinding(
      editingShortcutId: IcarusShortcutAction.draw.name,
      binding: const IcarusKeyBinding(
        trigger: LogicalKeyboardKey.keyZ,
        primary: true,
      ),
      customBindings: const {},
    );
    final redoDuplicate = ShortcutInfo.findDuplicateBinding(
      editingShortcutId: IcarusShortcutAction.draw.name,
      binding: const IcarusKeyBinding(
        trigger: LogicalKeyboardKey.keyZ,
        primary: true,
        shift: true,
      ),
      customBindings: const {},
    );

    expect(undoDuplicate?.title, 'Undo');
    expect(redoDuplicate?.title, 'Redo');
  });

  test('effective bindings ignore custom bindings reserved for undo and redo',
      () {
    const reservedUndoBinding = IcarusKeyBinding(
      trigger: LogicalKeyboardKey.keyZ,
      primary: true,
    );
    final binding = ShortcutInfo.effectiveBindingFor(
      IcarusShortcutAction.draw.name,
      {
        IcarusShortcutAction.draw.name: reservedUndoBinding.serialize(),
      },
    );

    expect(binding, const IcarusKeyBinding(trigger: LogicalKeyboardKey.keyQ));
  });

  test('search matches both action title and key chord', () {
    const bindings = <String, String>{};
    final saveDefinition =
        ShortcutInfo.definitionsById[IcarusShortcutAction.saveStrategy.name]!;

    expect(
      ShortcutInfo.matchesSearch(
        saveDefinition,
        'save',
        bindings,
        platform: TargetPlatform.windows,
      ),
      isTrue,
    );
    expect(
      ShortcutInfo.matchesSearch(
        saveDefinition,
        'ctrl s',
        bindings,
        platform: TargetPlatform.windows,
      ),
      isTrue,
    );
  });

  test('text editing overrides follow custom shortcut bindings', () {
    const customDrawBinding = IcarusKeyBinding(
      trigger: LogicalKeyboardKey.keyP,
    );
    final shortcuts = ShortcutInfo.textEditingOverridesFor({
      IcarusShortcutAction.draw.name: customDrawBinding.serialize(),
    });

    expect(
      shortcuts[
          customDrawBinding.toActivator(platform: TargetPlatform.windows)],
      isA<DoNothingAndStopPropagationIntent>(),
    );
    expect(
      shortcuts[const IcarusKeyBinding(
        trigger: LogicalKeyboardKey.keyQ,
      ).toActivator(platform: TargetPlatform.windows)],
      isNull,
    );
  });
}
