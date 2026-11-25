import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

typedef StrategyLook = ({String? name, MapValue? map, bool isAttack});

const StrategyLook unknownStrategyLook = (
  name: null,
  map: null,
  isAttack: true,
);

StrategyLook strategyLookFor(
  WidgetRef ref,
  String strategyId,
  StrategySource source,
) =>
    switch (source) {
      StrategySource.local => _localLook(ref, strategyId),
      StrategySource.cloud => _cloudLook(ref, strategyId),
    } ??
    unknownStrategyLook;

StrategyLook? _localLook(WidgetRef ref, String strategyId) {
  final library = ref.read(localLibraryViewProvider);
  if (!library.isOpen) return null;
  return switch (library.strategy(strategyId)) {
    final strategy? => (
        name: strategy.name,
        map: strategy.mapData,
        isAttack: strategy.opensOnAttack,
      ),
    null => null,
  };
}

StrategyLook? _cloudLook(WidgetRef ref, String strategyId) {
  if (ref.exists(cloudStrategiesProvider)) {
    final listed = (ref.read(cloudStrategiesProvider).valueOrNull ?? const [])
        .firstWhereOrNull((entry) => entry.strategy.id == strategyId);
    if (listed != null) {
      return (
        name: listed.strategy.name,
        map: listed.strategy.mapData,
        isAttack: listed.attackLabel != 'Defend',
      );
    }
  }
  final scope = ref.read(cloudCopyScopeProvider);
  if (scope == null) return null;
  final shell =
      ref.read(cloudStrategyCopyStoreProvider).readShell(scope, strategyId);
  if (shell == null) return null;
  final firstPage = shell.pages.sortedBy<num>((page) => page.sortIndex);
  return (
    name: shell.header.name,
    map: Maps.mapNames.entries
        .firstWhereOrNull((entry) => entry.value == shell.header.mapData)
        ?.key,
    isAttack: firstPage.firstOrNull?.isAttack ?? true,
  );
}
