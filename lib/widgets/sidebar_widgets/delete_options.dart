import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DeleteOptions extends ConsumerWidget {
  const DeleteOptions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        const SizedBox(height: 10),
        SizedBox(
          height: 50,
          width: 300,
          child: ShadButton(
            onPressed: () {
              ConfirmAlertDialog.show(
                context: context,
                title: "Clear All Items",
                content:
                    "Are you sure you want to clear all items? This cannot be undone.",
                confirmText: "Clear All",
                cancelText: "Cancel",
                isDestructive: true,
              ).then((confirmed) {
                if (confirmed) {
                  ref.read(actionProvider.notifier).clearAllActions();
                }
              });
            },
            child: const Text("Clear all"),
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Theme(
            data: Theme.of(context).copyWith(
              iconButtonTheme: IconButtonThemeData(
                style: ButtonStyle(
                  backgroundColor:
                      WidgetStateProperty.all(Settings.highlightColor),
                  shape: WidgetStateProperty.all(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                  ),
                ),
              ),
            ),
            child: Row(
              spacing: 10,
              children: [
                Expanded(
                  child: IconButton(
                    tooltip: "Clear Agent",
                    onPressed: () {
                      ref
                          .read(actionProvider.notifier)
                          .clearAction(ActionGroup.agent);
                    },
                    icon: const Icon(Icons.person),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    tooltip: "Clear Ability",
                    onPressed: () {
                      ref
                          .read(actionProvider.notifier)
                          .clearAction(ActionGroup.ability);
                    },
                    icon: const Icon(Icons.bolt),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    tooltip: "Clear Drawing",
                    onPressed: () {
                      ref
                          .read(actionProvider.notifier)
                          .clearAction(ActionGroup.drawing);
                    },
                    icon: const Icon(Icons.draw),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    tooltip: "Clear Text",
                    onPressed: () {
                      ref
                          .read(actionProvider.notifier)
                          .clearAction(ActionGroup.text);
                    },
                    icon: const Icon(Icons.text_fields),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    tooltip: "Clear Image",
                    onPressed: () {
                      ref
                          .read(actionProvider.notifier)
                          .clearAction(ActionGroup.image);
                    },
                    icon: const Icon(Icons.image),
                  ),
                ),
              ],
            ),
          ),
        )
      ],
    );
  }
}
