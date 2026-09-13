import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
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
  bool _isSubmitting = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final strategyName = _textController.text.trim();
    if (strategyName.isEmpty) {
      Settings.showToast(
        message: 'Strategy name cannot be empty.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final strategyID = await ref
          .read(strategyProvider.notifier)
          .createNewStrategy(strategyName);
      if (!mounted) return;
      Navigator.of(context).pop(strategyID);
    } catch (_) {
      if (mounted) setState(() => _isSubmitting = false);
      Settings.showToast(
        message: "Couldn't create strategy right now.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('Create Strategy'),
      actions: [
        ShadButton(
          onPressed: _isSubmitting ? null : _submit,
          child: Text(_isSubmitting ? 'Creating…' : 'Create'),
        ),
      ],
      child: SizedBox(
        width: 300,
        child: CustomTextField(
          hintText: 'Enter strategy name',
          controller: _textController,
          autofocus: true,
          onSubmitted: (_) => _submit(),
        ),
      ),
    );
  }
}
