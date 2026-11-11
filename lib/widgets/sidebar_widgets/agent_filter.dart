import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/widgets/custom_segmented_tabs.dart';

class AgentFilter extends ConsumerWidget {
  const AgentFilter({super.key, this.compactness = 0.2});

  final double compactness;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CustomSegmentedTabs<FilterState>(
      compactness: compactness,
      value: ref.watch(agentFilterProvider).currentFilter,
      items: [
        SegmentedTabItem<FilterState>(
          value: FilterState.all,
          child: Text(context.l10n.sidebarFilterAll),
        ),
        SegmentedTabItem<FilterState>(
          value: FilterState.onMap,
          child: Text(context.l10n.sidebarFilterOnMap),
        ),
        SegmentedTabItem<FilterState>(
          value: FilterState.role,
          child: Text(context.l10n.sidebarFilterRole),
        ),
      ],
      onChanged: (value) {
        ref.read(agentFilterProvider.notifier).updateFilterState(value);
      },
    );
  }
}
