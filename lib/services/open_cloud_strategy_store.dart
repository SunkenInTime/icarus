import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/open_cloud_strategy_store_stub.dart'
    if (dart.library.js_interop) 'package:icarus/services/open_cloud_strategy_store_web.dart'
    as platform;
import 'package:icarus/strategy/strategy_page_models.dart';

/// The cloud strategy open in the editor, so a page reload can reopen it.
///
/// On web a reload restarts the app on the editor's route, which carries no
/// strategy; the web store keeps the id in the tab's sessionStorage. Native
/// builds never reload, so memory is enough there.
abstract interface class OpenCloudStrategyStore {
  String? read();
  void write(String strategyPublicId);
  void clear();
}

class MemoryOpenCloudStrategyStore implements OpenCloudStrategyStore {
  String? _strategyPublicId;

  @override
  String? read() => _strategyPublicId;

  @override
  void write(String strategyPublicId) => _strategyPublicId = strategyPublicId;

  @override
  void clear() => _strategyPublicId = null;
}

/// sessionStorage on web, memory on native.
OpenCloudStrategyStore createOpenCloudStrategyStore() =>
    platform.createOpenCloudStrategyStore();

final openCloudStrategyStoreProvider = Provider<OpenCloudStrategyStore>(
  (ref) => createOpenCloudStrategyStore(),
);

/// While watched (by the editor), keeps [openCloudStrategyStoreProvider]
/// naming the cloud strategy open in the editor. It follows
/// [strategyProvider] rather than the route, because the open strategy
/// changes in place (quick switcher, back/forward, a new strategy). When the
/// editor goes away the store is cleared.
final openCloudStrategyRecorderProvider = Provider.autoDispose<void>((ref) {
  final store = ref.watch(openCloudStrategyStoreProvider);
  ref.listen(
    strategyProvider.select(
      (strategy) => (id: strategy.strategyId, source: strategy.source),
    ),
    (_, open) {
      final id = open.id;
      if (open.source == StrategySource.cloud && id != null) {
        store.write(id);
      } else {
        store.clear();
      }
    },
    fireImmediately: true,
  );
  ref.onDispose(store.clear);
});
