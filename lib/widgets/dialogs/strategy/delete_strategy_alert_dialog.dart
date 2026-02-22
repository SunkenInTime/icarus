import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DeleteStrategyAlertDialog extends ConsumerWidget {
  const DeleteStrategyAlertDialog({
    super.key,
    required this.strategyID,
    required this.name,
  });
  final String strategyID;
  final String name;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadDialog.alert(
      title: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: "Delete "),
            TextSpan(
              text: name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      description: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: "Are you sure you want to delete "),
            TextSpan(
              text: name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const TextSpan(text: "? This action cannot be undone."),
          ],
        ),
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text(
            "Cancel",
          ),
        ),
        ShadButton.destructive(
          // padding: WidgetStateProperty.all(
          //   const EdgeInsets.symmetric(horizontal: 16, vertical: 8),

          onPressed: () async {
            await ref
                .read(strategyProvider.notifier)
                .deleteStrategy(strategyID);

            if (!context.mounted) return;

            Navigator.of(context).pop();
          },
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.delete_forever, color: Colors.white),
              SizedBox(width: 5),
              Text(
                "Delete",
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
