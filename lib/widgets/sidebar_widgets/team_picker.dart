import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/team_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class TeamPicker extends ConsumerWidget {
  const TeamPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAlly = ref.watch(teamProvider);
    final notifier = ref.read(teamProvider.notifier);

    return SizedBox(
      width: 50,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _TeamTextButton(
            label: 'Ally',
            isSelected: isAlly,
            selectedColor: Settings.allyOutlineColor.withOpacity(1),
            onTap: () => notifier.isAlly(true),
          ),
          const SizedBox(height: 4),
          _TeamTextButton(
            label: 'Enemy',
            isSelected: !isAlly,
            selectedColor: Settings.enemyOutlineColor.withOpacity(1),
            onTap: () => notifier.isAlly(false),
          ),
        ],
      ),
    );
  }
}

class _TeamTextButton extends StatefulWidget {
  final String label;
  final bool isSelected;
  final Color selectedColor;
  final VoidCallback onTap;

  const _TeamTextButton({
    required this.label,
    required this.isSelected,
    required this.selectedColor,
    required this.onTap,
  });

  @override
  State<_TeamTextButton> createState() => _TeamTextButtonState();
}

class _TeamTextButtonState extends State<_TeamTextButton> {
  bool isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => isHovered = true),
      onExit: (_) => setState(() => isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 150),
          style: ShadTheme.of(context).textTheme.small.copyWith(
                color: widget.isSelected
                    ? widget.selectedColor
                    : (isHovered
                        ? widget.selectedColor.withOpacity(0.7)
                        : Settings.tacticalVioletTheme.mutedForeground),
                // fontSize: 14,
              ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: Text(widget.label),
          ),
        ),
      ),
    );
  }
}
