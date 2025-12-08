import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/agent_filter_provider.dart';

class RolePicker extends ConsumerWidget {
  const RolePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isExpanded =
        ref.watch(agentFilterProvider).currentFilter == FilterState.role;

    return ClipRRect(
      child: AnimatedContainer(
        curve: Curves.easeIn,
        duration: const Duration(milliseconds: 100),
        height: isExpanded ? 38 : 0,
        child: AnimatedOpacity(
          opacity: isExpanded ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeIn,
          child: Padding(
            padding: const EdgeInsets.only(right: 8.0, top: 2),
            child: Row(
              spacing: 1,
              children: [
                for (final role in AgentRole.values)
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: IconButton(
                      style: IconButton.styleFrom(
                        backgroundColor: role ==
                                ref.watch(agentFilterProvider).currentRole
                            ? Settings.tacticalVioletTheme.primary.withAlpha(51)
                            : Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: Padding(
                        padding: const EdgeInsets.all(1),
                        child: Image.asset(
                          "assets/agents/${agentRoleNames[role]!}.webp",
                          fit: BoxFit.contain,
                        ),
                      ),
                      onPressed: () {
                        ref
                            .read(agentFilterProvider.notifier)
                            .updateRoleState(role);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
