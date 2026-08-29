import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ConfirmAlertDialog extends ConsumerWidget {
  const ConfirmAlertDialog({
    super.key,
    required this.title,
    required this.content,
    this.confirmText = "Confirm",
    this.cancelText = "Cancel",
    this.isDestructive = false,
  });

  final String title;
  final String content;
  final String confirmText;
  final String cancelText;
  final bool isDestructive; // For dangerous actions like delete

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void cancel() => Navigator.of(context).pop(false);
    void confirm() => Navigator.of(context).pop(true);

    return ShadDialog.alert(
      title: Text(title),
      description: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Text(content),
      ),
      actions: [
        Semantics(
          key: const ValueKey('confirm-alert-cancel'),
          label: cancelText,
          button: true,
          onTap: cancel,
          excludeSemantics: true,
          child: ShadButton.secondary(
            onPressed: cancel,
            child: Text(cancelText),
          ),
        ),
        if (isDestructive)
          Semantics(
            key: const ValueKey('confirm-alert-confirm'),
            label: confirmText,
            button: true,
            onTap: confirm,
            excludeSemantics: true,
            child: ShadButton.destructive(
              onPressed: confirm,
              child: Text(confirmText),
            ),
          )
        else
          Semantics(
            key: const ValueKey('confirm-alert-confirm'),
            label: confirmText,
            button: true,
            onTap: confirm,
            excludeSemantics: true,
            child: ShadButton(
              onPressed: confirm,
              child: Text(confirmText),
            ),
          ),
      ],
    );
  }

  // Static helper method for easy usage
  static Future<bool> show({
    required BuildContext context,
    required String title,
    required String content,
    String confirmText = "Confirm",
    String cancelText = "Cancel",
    bool isDestructive = false,
  }) async {
    final result = await showShadDialog<bool>(
      context: context,
      builder: (context) => ConfirmAlertDialog(
        title: title,
        content: content,
        confirmText: confirmText,
        cancelText: cancelText,
        isDestructive: isDestructive,
      ),
    );

    return result ?? false; // Return false if dialog was dismissed
  }
}
