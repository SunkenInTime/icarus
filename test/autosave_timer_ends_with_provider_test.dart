import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

void main() {
  test('an autosave still waiting when its provider is disposed never runs',
      () {
    fakeAsync((async) {
      final container = ProviderContainer();
      container.read(strategyProvider.notifier).setFromState(
            const StrategyState(
              strategyId: 'strategy',
              strategyName: 'Strategy',
              source: StrategySource.local,
              storageDirectory: null,
              isOpen: true,
            ),
          );
      container.read(strategyProvider.notifier).setUnsaved();
      expect(container.read(strategySaveStateProvider).isDirty, isTrue);
      expect(async.pendingTimers, isNotEmpty);

      container.dispose();
      async.elapse(Settings.autoSaveOffset * 2);

      expect(async.pendingTimers, isEmpty);
    });
  });
}
