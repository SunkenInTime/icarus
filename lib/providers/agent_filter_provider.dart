import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/favorite_agents_provider.dart';

enum FilterState { all, onMap, role }

final agentFilterProvider =
    NotifierProvider<AgentFilterProvider, AgentFilterState>(
        AgentFilterProvider.new);

class AgentFilterProvider extends Notifier<AgentFilterState> {
  List<AgentType> _sortAgentsByName(Iterable<AgentType> agents) {
    final sortedAgents = agents.toList();
    sortedAgents.sort(
      (a, b) => AgentData.agents[a]!.name
          .toLowerCase()
          .compareTo(AgentData.agents[b]!.name.toLowerCase()),
    );
    return sortedAgents;
  }

  @override
  AgentFilterState build() {
    ref.listen<Set<AgentType>>(favoriteAgentsProvider, (_, __) {
      _refreshAgentList();
    });

    ref.listen<List<PlacedAgent>>(agentProvider, (_, __) {
      if (state.currentFilter == FilterState.onMap) {
        _refreshAgentList();
      }
    });

    return AgentFilterState(
      currentFilter: FilterState.all,
      currentRole: AgentRole.duelist,
      favoritesOnly: false,
      agentList: _sortAgentsByName(AgentType.values),
    );
  }

  void updateFilterState(FilterState filterState) {
    _refreshAgentList(currentFilter: filterState);
  }

  void updateRoleState(AgentRole currentRole) {
    _refreshAgentList(currentRole: currentRole);
  }

  void toggleFavoritesOnly() {
    _refreshAgentList(favoritesOnly: !state.favoritesOnly);
  }

  void _refreshAgentList({
    FilterState? currentFilter,
    AgentRole? currentRole,
    bool? favoritesOnly,
  }) {
    final resolvedFilter = currentFilter ?? state.currentFilter;
    final resolvedRole = currentRole ?? state.currentRole;
    final resolvedFavoritesOnly = favoritesOnly ?? state.favoritesOnly;
    final favoriteAgents = ref.read(favoriteAgentsProvider);

    final baseAgentList = _getBaseAgentList(
      filterState: resolvedFilter,
      role: resolvedRole,
    );

    final filteredList = resolvedFavoritesOnly
        ? baseAgentList.where(favoriteAgents.contains).toList(growable: false)
        : baseAgentList;

    state = state.copyWith(
      currentFilter: resolvedFilter,
      currentRole: resolvedRole,
      favoritesOnly: resolvedFavoritesOnly,
      agentList: filteredList,
    );
  }

  List<AgentType> _getBaseAgentList({
    required FilterState filterState,
    required AgentRole role,
  }) {
    switch (filterState) {
      case FilterState.all:
        return _sortAgentsByName(AgentType.values);
      case FilterState.onMap:
        final filteredList = <AgentType>{};
        for (final agent in ref.read(agentProvider)) {
          filteredList.add(agent.type);
        }
        return _sortAgentsByName(filteredList);
      case FilterState.role:
        final filteredList = <AgentType>[];
        for (final agentType in AgentType.values) {
          if (AgentData.agents[agentType]!.role == role) {
            filteredList.add(agentType);
          }
        }
        return _sortAgentsByName(filteredList);
    }
  }
}

class AgentFilterState {
  final FilterState currentFilter;
  final AgentRole currentRole;
  final bool favoritesOnly;
  List<AgentType> agentList;
  AgentFilterState({
    required this.currentFilter,
    required this.currentRole,
    required this.favoritesOnly,
    required this.agentList,
  });

  AgentFilterState copyWith({
    FilterState? currentFilter,
    AgentRole? currentRole,
    bool? favoritesOnly,
    List<AgentType>? agentList,
  }) {
    return AgentFilterState(
      currentFilter: currentFilter ?? this.currentFilter,
      currentRole: currentRole ?? this.currentRole,
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      agentList: agentList ?? this.agentList,
    );
  }
}

