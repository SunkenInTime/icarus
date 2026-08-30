import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/strategy_provider.dart';

class _ControlledSaveStrategyProvider extends StrategyProvider {
  final firstSaveStarted = Completer<void>();
  final releaseFirstSave = Completer<void>();
  int saveCalls = 0;

  @override
  StrategyState build() => StrategyState(
        isSaved: false,
        stratName: 'Strategy',
        id: 'strategy-id',
        storageDirectory: null,
        activePageId: 'page-id',
      );

  @override
  Future<void> saveToHive(String id) async {
    saveCalls++;
    if (saveCalls == 1) {
      firstSaveStarted.complete();
      await releaseFirstSave.future;
    }
  }
}

void main() {
  test('overlapping forceSaveNow waits for a follow-up save', () async {
    final notifier = _ControlledSaveStrategyProvider();
    final container = ProviderContainer(
      overrides: [strategyProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    final mountedNotifier = container.read(strategyProvider.notifier);

    final firstSave = mountedNotifier.forceSaveNow('strategy-id');
    await notifier.firstSaveStarted.future;

    var overlappingSaveCompleted = false;
    final overlappingSave =
        mountedNotifier.forceSaveNow('strategy-id').whenComplete(
              () => overlappingSaveCompleted = true,
            );
    await Future<void>.delayed(Duration.zero);

    expect(notifier.saveCalls, 1);
    expect(overlappingSaveCompleted, isFalse);

    notifier.releaseFirstSave.complete();
    await Future.wait([firstSave, overlappingSave]);

    expect(notifier.saveCalls, 2);
    expect(overlappingSaveCompleted, isTrue);
  });
}
