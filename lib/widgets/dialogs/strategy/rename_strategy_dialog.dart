import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class RenameStrategyDialog extends ConsumerStatefulWidget {
  final String strategyId;
  final String currentName;

  const RenameStrategyDialog({
    super.key,
    required this.strategyId,
    required this.currentName,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _RenameStrategyDialogState();
}

class _RenameStrategyDialogState extends ConsumerState<RenameStrategyDialog> {
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _textController.text = widget.currentName;
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text("Rename Strategy"),
      actions: [
        ShadButton.secondary(
          onPressed: () {
            Navigator.of(context).pop(); // Close the dialog
          },
          child: const Text("Cancel"),
        ),
        ShadButton(
          onPressed: () async {
            final strategyName = _textController.text;
            if (strategyName.isNotEmpty) {
              await ref
                  .read(strategyProvider.notifier)
                  .renameStrategy(widget.strategyId, strategyName);
              if (!context.mounted) return;
              Navigator.of(context).pop(true); // Close the dialog with success
            } else {
              // Optionally, show an error message if the name is empty
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Strategy name cannot be empty."),
                ),
              );
            }
          },
          height: 35,
          leading: const Icon(Icons.text_fields),
          child: const Text("Rename"),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: CustomTextField(
            // onEnterPressed: (intent) {},
            hintText: widget.currentName,
            controller: _textController,
            textAlign: TextAlign.start,
            onSubmitted: (value) async {
              if (value.isNotEmpty) {
                await ref
                    .read(strategyProvider.notifier)
                    .renameStrategy(widget.strategyId, value);
                if (!context.mounted) return;
                Navigator.of(context)
                    .pop(true); // Close the dialog with success
              } else {
                // Optionally, show an error message if the name is empty

                Settings.showToast(
                  message: "Strategy name cannot be empty.",
                  backgroundColor: Settings.tacticalVioletTheme.destructive,
                );
              }
            }),
      ),
    );
  }
}
// How to use it:
// showDialog(
//   context: context,
//   builder: (context) => RenameStrategyDialog(
//     strategyId: "your_strategy_id",
//     currentName: "Current Strategy Name",
//   ),
// );
