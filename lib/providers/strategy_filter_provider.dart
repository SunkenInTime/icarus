import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/l10n/l10n.dart';
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
  static String sortByLabel(SortBy sortBy, AppLocalizations l10n) =>
      switch (sortBy) {
        SortBy.alphabetical => l10n.prefsMsgSortAlphabetical,
        SortBy.dateCreated => l10n.prefsMsgSortDateCreated,
        SortBy.dateUpdated => l10n.prefsMsgSortDateUpdated,
      };

  static String sortOrderLabel(SortOrder sortOrder, AppLocalizations l10n) =>
      switch (sortOrder) {
        SortOrder.ascending => l10n.prefsMsgSortAscending,
        SortOrder.descending => l10n.prefsMsgSortDescending,
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
    final label = sortByLabel(state.sortBy, ref.read(l10nProvider));

    switch (state.sortBy) {
      case SortBy.alphabetical:
        return (icon: LucideIcons.arrowDownAZ, label: label);
      case SortBy.dateCreated:
        return (icon: LucideIcons.calendarPlus, label: label);
      case SortBy.dateUpdated:
        return (icon: LucideIcons.history, label: label);
    }
  }
}
