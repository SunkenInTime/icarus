import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/widgets/dialogs/custom_alert_dialog.dart';

class DeleteOptions extends ConsumerStatefulWidget {
  const DeleteOptions({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DeleteOptionsState();
}

class _DeleteOptionsState extends ConsumerState<DeleteOptions> {
  @override
  Widget build(BuildContext context) {
    final isExpanded =
        ref.watch(interactionStateProvider) == InteractionState.deleting;
    return AnimatedContainer(
      height: isExpanded ? 140 : 0,
      duration: const Duration(milliseconds: 200),
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 10),
            SizedBox(
              height: 50,
              width: 300,
              child: TextButton(
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.all(Colors.deepPurple),
                  shape: WidgetStateProperty.all(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                  ),
                ),
                onPressed: () {
                  ConfirmAlertDialog.show(
                    context: context,
                    title: "Clear All Items",
                    content:
                        "Are you sure you want to clear all items? This cannot be undone.",
                    confirmText: "Clear All",
                    cancelText: "Cancel",
                    confirmColor: Colors.redAccent,
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
            const SizedBox(
              height: 14,
            ),
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
                )),
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
        ),
      ),
    );
  }
}
