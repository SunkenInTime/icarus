import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/shortcut_info.dart';
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Shortcuts(
      shortcuts: ShortcutInfo.textEditingOverrides,
      child: ShadInput(
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
