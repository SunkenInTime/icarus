import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DeleteOptions extends ConsumerWidget {
  const DeleteOptions({
    super.key,
    this.animation,
    this.onMenuEntered,
    this.onMenuExited,
    this.onCloseRequested,
  });

  final Animation<double>? animation;
  final VoidCallback? onMenuEntered;
  final VoidCallback? onMenuExited;
  final VoidCallback? onCloseRequested;

  static const List<_DeleteOptionData> _options = [
    _DeleteOptionData(
      group: ActionGroup.agent,
      icon: Icons.person,
      label: 'Agents',
    ),
    _DeleteOptionData(
      group: ActionGroup.ability,
      icon: Icons.bolt,
      label: 'Abilities',
    ),
    _DeleteOptionData(
      group: ActionGroup.drawing,
      icon: Icons.draw,
      label: 'Drawings',
    ),
    _DeleteOptionData(
      group: ActionGroup.text,
      icon: Icons.text_fields,
      label: 'Text',
    ),
    _DeleteOptionData(
      group: ActionGroup.image,
      icon: Icons.image,
      label: 'Images',
    ),
    _DeleteOptionData(
      group: ActionGroup.utility,
      icon: Icons.crop_square,
      label: 'Utilities',
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = Container(
      width: 146,
      height: 94,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Settings.tacticalVioletTheme.border.withValues(alpha: 0.9),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(-4, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AnimatedDeleteMenuEntry(
            animation: animation,
            start: 0.0,
            end: 0.45,
            child: SizedBox(
              height: 24,
              child: ShadButton.destructive(
                onPressed: () async {
                  onCloseRequested?.call();
                  final confirmed = await ConfirmAlertDialog.show(
                    context: context,
                    title: "Clear All Items",
                    content:
                        "Are you sure you want to clear all items? You can undo this action.",
                    confirmText: "Clear All",
                    cancelText: "Cancel",
                    isDestructive: true,
                  );
                  if (confirmed) {
                    ref.read(actionProvider.notifier).clearAllAsAction();
                  }
                },
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(
                  "Delete all",
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          ...List.generate(2, (rowIndex) {
            final rowOptions = _options.skip(rowIndex * 3).take(3).toList();
            return Padding(
              padding: EdgeInsets.only(bottom: rowIndex == 0 ? 6 : 0),
              child: Row(
                children: [
                  for (int columnIndex = 0;
                      columnIndex < rowOptions.length;
                      columnIndex++) ...[
                    if (columnIndex > 0) const SizedBox(width: 6),
                    Expanded(
                      child: _AnimatedDeleteMenuEntry(
                        animation: animation,
                        start: (0.18 + (((rowIndex * 3) + columnIndex) * 0.08)),
                        end: (0.52 + (((rowIndex * 3) + columnIndex) * 0.06))
                            .clamp(0.0, 1.0),
                        child: ShadTooltip(
                          builder: (_) =>
                              Text("Clear ${rowOptions[columnIndex].label}"),
                          child: _DeleteOptionButton(
                            icon: rowOptions[columnIndex].icon,
                            onPressed: () {
                              onCloseRequested?.call();
                              ref
                                  .read(actionProvider.notifier)
                                  .clearGroupAsAction(
                                    rowOptions[columnIndex].group,
                                  );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
        ],
      ),
    );

    return MouseRegion(
      onEnter: (_) => onMenuEntered?.call(),
      onExit: (_) => onMenuExited?.call(),
      child: animation == null
          ? panel
          : AnimatedBuilder(
              animation: animation!,
              builder: (context, child) {
                final curved = CurvedAnimation(
                  parent: animation!,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                );
                return FadeTransition(
                  opacity: curved,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.035, 0),
                      end: Offset.zero,
                    ).animate(curved),
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.96,
                        end: 1.0,
                      ).animate(curved),
                      alignment: Alignment.centerRight,
                      child: child,
                    ),
                  ),
                );
              },
              child: panel,
            ),
    );
  }
}

class _DeleteOptionButton extends StatelessWidget {
  const _DeleteOptionButton({
    required this.icon,
    required this.onPressed,
  });

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.secondary.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Settings.tacticalVioletTheme.border.withValues(alpha: 0.75),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Center(
            child: Icon(icon, size: 14, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _AnimatedDeleteMenuEntry extends StatelessWidget {
  const _AnimatedDeleteMenuEntry({
    required this.child,
    required this.start,
    required this.end,
    this.animation,
  });

  final Widget child;
  final double start;
  final double end;
  final Animation<double>? animation;

  @override
  Widget build(BuildContext context) {
    if (animation == null) return child;

    final curved = CurvedAnimation(
      parent: animation!,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
      reverseCurve: Interval(start, end, curve: Curves.easeInCubic),
    );

    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        return Opacity(
          opacity: curved.value,
          child: Transform.translate(
            offset: Offset(0, (1 - curved.value) * 6),
            child: child,
          ),
        );
      },
    );
  }
}

class _DeleteOptionData {
  const _DeleteOptionData({
    required this.group,
    required this.icon,
    required this.label,
  });

  final ActionGroup group;
  final IconData icon;
  final String label;
}
