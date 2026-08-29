import 'package:flutter/material.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CustomTextField extends StatefulWidget {
  const CustomTextField({
    super.key,
    this.controller,
    this.focusNode,
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
  final FocusNode? focusNode;
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
  State<CustomTextField> createState() => _CustomTextFieldState();
}

class _CustomTextFieldState extends State<CustomTextField> {
  late final TextEditingController _fallbackController;
  late final FocusNode _fallbackFocusNode;

  TextEditingController get _controller =>
      widget.controller ?? _fallbackController;
  FocusNode get _focusNode => widget.focusNode ?? _fallbackFocusNode;

  @override
  void initState() {
    super.initState();
    _fallbackController = TextEditingController();
    _fallbackFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _fallbackController.dispose();
    _fallbackFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _EditableTextFieldSemantics(
      label: widget.hintText,
      controller: _controller,
      focusNode: _focusNode,
      obscureText: widget.obscureText,
      child: TextEditingShortcutScope(
        child: ShadInput(
          decoration: widget.hasError
              ? ShadDecoration(
                  border: ShadBorder.all(
                    color: ShadTheme.of(context).colorScheme.destructive,
                  ),
                )
              : null,
          controller: _controller,
          focusNode: _focusNode,
          textAlign: widget.textAlign ?? TextAlign.start,
          minLines: widget.minLines,
          maxLines: widget.maxLines ?? 1,
          keyboardType: widget.keyboardType,
          autofillHints: widget.autofillHints,
          obscureText: widget.obscureText,
          textInputAction: widget.textInputAction,
          placeholder: widget.hintText != null ? Text(widget.hintText!) : null,
          onSubmitted: widget.onSubmitted,
        ),
      ),
    );
  }
}

class _EditableTextFieldSemantics extends StatefulWidget {
  const _EditableTextFieldSemantics({
    required this.label,
    required this.controller,
    required this.focusNode,
    required this.obscureText,
    required this.child,
  });

  final String? label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool obscureText;
  final Widget child;

  @override
  State<_EditableTextFieldSemantics> createState() =>
      _EditableTextFieldSemanticsState();
}

class _EditableTextFieldSemanticsState
    extends State<_EditableTextFieldSemantics> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    widget.focusNode.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant _EditableTextFieldSemantics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      oldWidget.focusNode.removeListener(_refresh);
      widget.focusNode.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    widget.focusNode.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _setText(String value) {
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    return Semantics(
      label: widget.label,
      value: widget.obscureText ? '•' * text.length : text,
      textField: true,
      enabled: true,
      obscured: widget.obscureText,
      focusable: true,
      focused: widget.focusNode.hasFocus,
      onTap: widget.focusNode.requestFocus,
      onSetText: _setText,
      onDidGainAccessibilityFocus: widget.focusNode.requestFocus,
      excludeSemantics: true,
      child: widget.child,
    );
  }
}
