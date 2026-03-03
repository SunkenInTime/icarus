import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/widgets/custom_segmented_tabs.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AgentFilter extends ConsumerWidget {
  const AgentFilter({super.key, this.compactness = 0.2});

  final double compactness;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CustomSegmentedTabs<FilterState>(
      compactness: compactness,
      value: ref.watch(agentFilterProvider).currentFilter,
      items: const [
        SegmentedTabItem<FilterState>(
          value: FilterState.all,
          child: Text("All"),
        ),
        SegmentedTabItem<FilterState>(
          value: FilterState.onMap,
          child: Text("On Map"),
        ),
        SegmentedTabItem<FilterState>(
          value: FilterState.role,
          child: Text("Role"),
        ),
      ],
      onChanged: (value) {
        ref.read(agentFilterProvider.notifier).updateFilterState(value);
      },
    );
  }
}
