import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CreateStrategyDialog extends ConsumerStatefulWidget {
  const CreateStrategyDialog({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _NameStrategyDialogState();
}

class _NameStrategyDialogState extends ConsumerState<CreateStrategyDialog> {
  final TextEditingController _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text("Create Strategy"),
      actions: [
        ShadButton(
          child: const Text("Create"),
          onPressed: () async {
            final strategyName = _textController.text;
            if (strategyName.isNotEmpty) {
              final strategyID = await ref
                  .read(strategyProvider.notifier)
                  .createNewStrategy(strategyName);
              if (!context.mounted) return;
              Navigator.of(context).pop(strategyID); // Close the dialog
            } else {
              // Optionally, show an error message if the name is empty
              Settings.showToast(
                message: "Strategy name cannot be empty.",
                backgroundColor: Settings.tacticalVioletTheme.destructive,
              );
            }
          },
        )
      ],
      child: SizedBox(
        width: 300,
        child: CustomTextField(
          // onEnterPressed: (intent) {},
          hintText: "Enter strategy name",
          controller: _textController,

          onSubmitted: (value) async {
            if (value.isNotEmpty) {
              final strategyID = await ref
                  .read(strategyProvider.notifier)
                  .createNewStrategy(value);
              if (!context.mounted) return;
              Navigator.of(context).pop(strategyID); // Close the dialog
            } else {
              // Optionally, show an error message if the name is empty
              Settings.showToast(
                message: "Strategy name cannot be empty.",
                backgroundColor: Settings.tacticalVioletTheme.destructive,
              );
            }
          },
        ),
      ),
    );
  }
}
// How to use it:
// showDialog(
//   context: context,
//   builder: (context) => const NameStrategyDialog(),
// );
