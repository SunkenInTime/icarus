import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    return StrategyFilterState(
      sortBy: SortBy.dateCreated,
      sortOrder: SortOrder.ascending,
    );
  }

  void setSortBy(SortBy sortBy) {
    state = state.copyWith(sortBy: sortBy);
  }

  void setSortOrder(SortOrder sortOrder) {
    state = state.copyWith(sortOrder: sortOrder);
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
