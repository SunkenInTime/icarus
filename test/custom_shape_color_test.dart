import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return StrategyState(
      isSaved: true,
      stratName: null,
      id: 'shape-color-test',
      storageDirectory: null,
      activePageId: null,
    );
  }

  @override
  void setUnsaved() {
    state = state.copyWith(isSaved: false);
  }
}

void main() {
  test('custom shape color changes support undo, redo, and snapshots', () {
    final container = ProviderContainer(
      overrides: [
        strategyProvider.overrideWith(_NoopStrategyProvider.new),
      ],
    );
    addTearDown(container.dispose);
    final utility = PlacedUtility(
      type: UtilityType.customCircle,
      position: const Offset(100, 120),
      id: 'circle',
      customDiameter: 12,
      customColorValue: 0xff8b5cf6,
      customOpacityPercent: 40,
    );
    container.read(utilityProvider.notifier).fromHive([utility]);

    container.read(utilityProvider.notifier).updateCustomShapeColor(
          id: utility.id,
          colorValue: 0xffff0000,
        );

    expect(
      container.read(utilityProvider).single.customColorValue,
      0xffff0000,
    );
    expect(container.read(actionProvider), hasLength(1));
    expect(container.read(strategyProvider).isSaved, isFalse);

    final snapshot = container.read(utilityProvider.notifier).takeSnapshot();
    container.read(utilityProvider.notifier).restoreSnapshot(snapshot);

    container.read(actionProvider.notifier).undoAction();
    expect(
      container.read(utilityProvider).single.customColorValue,
      0xff8b5cf6,
    );

    container.read(actionProvider.notifier).redoAction();
    expect(
      container.read(utilityProvider).single.customColorValue,
      0xffff0000,
    );

    container.read(utilityProvider.notifier).updateCustomShapeColor(
          id: utility.id,
          colorValue: 0xffff0000,
        );
    expect(container.read(actionProvider), hasLength(1));
  });
}
