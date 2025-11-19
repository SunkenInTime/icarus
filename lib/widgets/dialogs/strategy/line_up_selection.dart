import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:flutter/material.dart';

class LineupSelectionPage extends StatelessWidget {
  final AgentData? selectedAgent;
  final AbilityInfo? selectedAbility;
  final ValueChanged<AgentData> onAgentSelected;
  final ValueChanged<AbilityInfo> onAbilitySelected;

  const LineupSelectionPage({
    super.key,
    required this.selectedAgent,
    required this.selectedAbility,
    required this.onAgentSelected,
    required this.onAbilitySelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Agent Selector
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Settings.abilityBGColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Settings.highlightColor),
            ),
            padding: const EdgeInsets.all(8),
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: AgentData.agents.length,
              itemBuilder: (context, index) {
                final agent = AgentData.agents.values.elementAt(index);
                final isSelected = selectedAgent?.type == agent.type;
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => onAgentSelected(agent),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      decoration: BoxDecoration(
                        border: isSelected
                            ? Border.all(
                                color: Colors.deepPurpleAccent, width: 2)
                            : Border.all(color: Colors.transparent, width: 2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.asset(agent.iconPath, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Ability Selector
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 80,
          decoration: BoxDecoration(
            color: Settings.abilityBGColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Settings.highlightColor),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: selectedAgent == null
              ? const Center(
                  child: Text(
                    "Select an Agent",
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: selectedAgent!.abilities.map((ability) {
                    final isSelected = selectedAbility?.index == ability.index;
                    return MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => onAbilitySelected(ability),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.deepPurpleAccent.withOpacity(0.2)
                                : Colors.transparent,
                            border: Border.all(
                              color: isSelected
                                  ? Colors.deepPurpleAccent
                                  : Colors.transparent,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: Image.asset(ability.iconPath),
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }
}
