import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

enum SortBy {
  alphabetical,
  dateCreated,
  dateUpdated,
}

enum SortOrder {
  ascending,
  descending,
}

class StrategyFilterState {
  final SortBy sortBy;
  final SortOrder sortOrder;

  StrategyFilterState({
    required this.sortBy,
    required this.sortOrder,
  });

  StrategyFilterState copyWith({
    SortBy? sortBy,
    SortOrder? sortOrder,
  }) {
    return StrategyFilterState(
      sortBy: sortBy ?? this.sortBy,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

final strategyFilterProvider =
    NotifierProvider<StrategyFilterProvider, StrategyFilterState>(
        StrategyFilterProvider.new);

class StrategyFilterProvider extends Notifier<StrategyFilterState> {
  static Map<SortBy, String> sortByLabels = {
    SortBy.alphabetical: 'Alphabetical',
    SortBy.dateCreated: 'Date Created',
    SortBy.dateUpdated: 'Date Updated',
  };

  static Map<SortOrder, String> sortOrderLabels = {
    SortOrder.ascending: 'Ascending',
    SortOrder.descending: 'Descending',
  };

  @override
  StrategyFilterState build() {
    final preferences = ref.read(appPreferencesProvider);
    return StrategyFilterState(
      sortBy: SortBy.values.firstWhere(
        (value) => value.name == preferences.librarySortByName,
        orElse: () => SortBy.dateCreated,
      ),
      sortOrder: SortOrder.values.firstWhere(
        (value) => value.name == preferences.librarySortOrderName,
        orElse: () => SortOrder.ascending,
      ),
    );
  }

  void setSortBy(SortBy sortBy) {
    state = state.copyWith(sortBy: sortBy);
    unawaited(
      ref
          .read(appPreferencesProvider.notifier)
          .setLibrarySort(sortByName: sortBy.name),
    );
  }

  void setSortOrder(SortOrder sortOrder) {
    state = state.copyWith(sortOrder: sortOrder);
    unawaited(
      ref
          .read(appPreferencesProvider.notifier)
          .setLibrarySort(sortOrderName: sortOrder.name),
    );
  }

  ({IconData icon, String label}) getCurrentSortBy() {
    final label = sortByLabels[state.sortBy]!;

    switch (state.sortBy) {
      case SortBy.alphabetical:
        return (icon: Icons.sort_by_alpha, label: label);
      case SortBy.dateCreated:
        return (icon: Icons.calendar_today, label: label);
      case SortBy.dateUpdated:
        return (icon: Icons.update, label: label);
    }
  }
}
