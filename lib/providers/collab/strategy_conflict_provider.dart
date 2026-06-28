import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';

final strategyConflictProvider =
    NotifierProvider<StrategyConflictNotifier, List<ConflictResolution>>(
  StrategyConflictNotifier.new,
);

class StrategyConflictNotifier extends Notifier<List<ConflictResolution>> {
  @override
  List<ConflictResolution> build() {
    return const [];
  }

  void push(ConflictResolution resolution) {
    state = [...state, resolution];
  }

  void clear(String opId) {
    state = state.where((item) => item.opId != opId).toList(growable: false);
  }

  void clearAll() {
    state = const [];
  }
}
