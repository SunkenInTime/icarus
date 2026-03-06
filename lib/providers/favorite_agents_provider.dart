import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';

final favoriteAgentsProvider =
    NotifierProvider<FavoriteAgentsProvider, Set<AgentType>>(
        FavoriteAgentsProvider.new);

class FavoriteAgentsProvider extends Notifier<Set<AgentType>> {
  static const bool _favoriteValue = true;

  Box<bool> get _box => Hive.box<bool>(HiveBoxNames.favoriteAgentsBox);

  @override
  Set<AgentType> build() {
    return _readFavoritesFromBox();
  }

  bool isFavorite(AgentType type) {
    return state.contains(type);
  }

  Future<void> toggleFavorite(AgentType type) async {
    if (isFavorite(type)) {
      await _box.delete(type.name);
      state = {...state}..remove(type);
      return;
    }

    await _box.put(type.name, _favoriteValue);
    state = {...state, type};
  }

  Set<AgentType> _readFavoritesFromBox() {
    final favorites = <AgentType>{};
    for (final key in _box.keys) {
      if (key is! String) {
        continue;
      }
      try {
        favorites.add(AgentType.values.byName(key));
      } catch (_) {
        // Keep local settings resilient to stale/invalid keys.
      }
    }
    return favorites;
  }
}

