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
    this.keyboardType,
    this.autofillHints,
    this.obscureText = false,
    this.textInputAction,
    this.hasError = false,
  });
  final TextEditingController? controller;
  final String? hintText;
  final TextAlign? textAlign;
  final int? minLines;
  final int? maxLines;
  final Function(String)? onSubmitted;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final bool obscureText;
  final TextInputAction? textInputAction;

  /// Draws a destructive border when true (e.g. failed validation).
  final bool hasError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextEditingShortcutScope(
      child: ShadInput(
        decoration: hasError
            ? ShadDecoration(
                border: ShadBorder.all(
                  color: ShadTheme.of(context).colorScheme.destructive,
                ),
              )
            : null,
        controller: controller,
        textAlign: textAlign ?? TextAlign.start,
        minLines: minLines,
        maxLines: maxLines ?? 1,
        keyboardType: keyboardType,
        autofillHints: autofillHints,
        obscureText: obscureText,
        textInputAction: textInputAction,
        placeholder: hintText != null ? Text(hintText!) : null,
        onSubmitted: onSubmitted,
      ),
    );
  }
}
