import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CustomTextField extends ConsumerWidget {
  const CustomTextField({
    super.key,
    this.controller,
    this.hintText,
    this.textAlign,
    this.minLines,
    this.maxLines,
    this.onSubmitted,
    // required this.onEnterPressed,
  });
  final TextEditingController? controller;
  final String? hintText;
  final TextAlign? textAlign;
  final int? minLines;
  final int? maxLines;
  final Function(String)? onSubmitted;
  // final Function(EnterTextIntent intent) onEnterPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextEditingShortcutScope(
      child: ShadInput(
        controller: controller,
        textAlign: textAlign ?? TextAlign.start,
        minLines: minLines,
        maxLines: maxLines ?? 1,
        placeholder: hintText != null ? Text(hintText!) : null,
        onSubmitted: onSubmitted,
      ),
    );
  }
}
