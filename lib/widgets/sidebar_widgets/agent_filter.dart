import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AgentFilter extends ConsumerWidget {
  AgentFilter({super.key});

  final List<AgentRole> agentRoles = [
    AgentRole.duelist,
    AgentRole.controller,
    AgentRole.initiator,
    AgentRole.sentinel,
  ];
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadTabs<FilterState>(
      tabBarConstraints: const BoxConstraints(maxWidth: 240),
      value: ref.watch(agentFilterProvider).currentFilter,
      // padding: EdgeInsets.zero,
      tabs: const [
        ShadTab<FilterState>(
          value: FilterState.all,
          child: Text("All"),
        ),
        ShadTab<FilterState>(
          value: FilterState.onMap,
          // label: Text("On Map"),
          child: Text("On Map"),
        ),
        ShadTab<FilterState>(
          value: FilterState.role,
          // label: Text("Role"),
          child: Text("Role"),
        ),
      ],
      onChanged: (value) {
        ref.read(agentFilterProvider.notifier).updateFilterState(value);
      },
      //   selectedValue: ref.watch(agentFilterProvider).currentFilter,
      //   onValueChanged: (value) {
      //     ref.read(agentFilterProvider.notifier).updateFilterState(value);
      //   },
      //  child:
    );
  }
}

class FilterText extends ConsumerWidget {
  final String text;
  final FilterState filterState;

  const FilterText({
    super.key,
    required this.text,
    required this.filterState,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSelected =
        ref.watch(agentFilterProvider).currentFilter == filterState;

    return Text(
      text,
      style: TextStyle(
        color: isSelected ? Colors.white : const Color(0xFF9E9E9E),
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
