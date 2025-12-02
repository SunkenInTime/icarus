import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';

class CustomTextField extends ConsumerWidget {
  const CustomTextField({
    super.key,
    this.controller,
    this.hintText,
    this.textAlign,
    this.minLines,
    this.maxLines,
    // required this.onEnterPressed,
  });
  final TextEditingController? controller;
  final String? hintText;
  final TextAlign? textAlign;
  final int? minLines;
  final int? maxLines;
  // final Function(EnterTextIntent intent) onEnterPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Shortcuts(
      shortcuts: ShortcutInfo.textEditingOverrides,
      child: TextField(
        controller: controller,
        textAlign: textAlign ?? TextAlign.start,
        minLines: minLines,
        maxLines: maxLines ?? 1,
        decoration: InputDecoration(
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide:
                const BorderSide(color: Settings.highlightColor, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide: const BorderSide(color: Colors.deepPurple, width: 2),
          ),
          filled: true,
          fillColor: Settings.abilityBGColor,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide: BorderSide.none,
          ),
          hintText: hintText,
          hintStyle: const TextStyle(color: Colors.white54),
        ),
        style: const TextStyle(color: Colors.white),
      ),
    );
  }
}
