import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';

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
    return AgentFilterState(
      currentFilter: FilterState.all,
      currentRole: AgentRole.duelist,
      agentList: _sortAgentsByName(AgentType.values),
    );
  }

  void updateFilterState(FilterState filterState) {
    switch (filterState) {
      case FilterState.all:
        state = state.copyWith(
          currentFilter: filterState,
          agentList: _sortAgentsByName(AgentType.values),
        );
      case FilterState.onMap:
        Set<AgentType> filteredList = {};

        for (PlacedAgent agent in ref.read(agentProvider)) {
          filteredList.add(agent.type);
        }

        state = state.copyWith(
          currentFilter: filterState,
          agentList: _sortAgentsByName(filteredList),
        );

      case FilterState.role:
        List<AgentType> filteredList = [];

        for (AgentType agentType in AgentType.values) {
          if (AgentData.agents[agentType]!.role == state.currentRole) {
            filteredList.add(agentType);
          }
        }

        state = state.copyWith(
          currentFilter: filterState,
          agentList: _sortAgentsByName(filteredList),
        );
    }
  }

  void updateRoleState(AgentRole currentRole) {
    List<AgentType> filteredList = [];

    for (AgentType agentType in AgentType.values) {
      if (AgentData.agents[agentType]!.role == currentRole) {
        filteredList.add(agentType);
      }
    }

    state = state.copyWith(
      currentRole: currentRole,
      agentList: _sortAgentsByName(filteredList),
    );
  }
}

class AgentFilterState {
  final FilterState currentFilter;
  final AgentRole currentRole;
  List<AgentType> agentList;
  AgentFilterState({
    required this.currentFilter,
    required this.currentRole,
    required this.agentList,
  });

  AgentFilterState copyWith({
    FilterState? currentFilter,
    AgentRole? currentRole,
    List<AgentType>? agentList,
  }) {
    return AgentFilterState(
      currentFilter: currentFilter ?? this.currentFilter,
      currentRole: currentRole ?? this.currentRole,
      agentList: agentList ?? this.agentList,
    );
  }
}
