import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A numeric text field that supports drag-to-adjust: drag left/right to
/// decrease/increase the value. Uses distance-adjusted sensitivity for smooth
/// control (short drags = fine, long drags = coarse).
///
/// The [leading] widget and text field sit inside a single container styled
/// like ShadInput (Shad secondary background, border, optional focus ring).
class _SuffixFormatter extends TextInputFormatter {
  _SuffixFormatter(this.suffix);

  final String suffix;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (!text.endsWith(suffix)) {
      final numberPart = text.trim();
      final newText = numberPart + suffix;
      final cursor = (newText.length - suffix.length).clamp(0, newText.length);
      return TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: cursor),
      );
    }
    final maxOffset = text.length - suffix.length;
    final base = newValue.selection.baseOffset.clamp(0, maxOffset);
    final extent = newValue.selection.extentOffset.clamp(0, maxOffset);
    return TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: base, extentOffset: extent),
    );
  }
}

class NumericDragInput extends StatefulWidget {
  const NumericDragInput({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = -999999,
    this.max = 999999,
    this.label = 'Value',
    this.leading,
    this.hintText = 'Enter a number',
    this.keyboardType = const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
    this.minHeight = 36,
    this.minWidth = 80,
    this.leadingPadding = const EdgeInsets.symmetric(horizontal: 8),
    this.fieldPadding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    this.trailingPadding = const EdgeInsets.only(left: 4, right: 6),
    this.suffix,
    this.labelTextStyle,
    this.valueTextStyle,
    this.hintTextStyle,
    this.suffixTextStyle,
    this.dragIconSize = 16,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final String label;

  /// Optional leading widget inside the container. If null, [label] is shown as text.
  final Widget? leading;
  final String hintText;
  final TextInputType keyboardType;
  final double minHeight;
  final double minWidth;
  final EdgeInsetsGeometry leadingPadding;
  final EdgeInsetsGeometry fieldPadding;
  final EdgeInsetsGeometry trailingPadding;

  /// Optional trailing unit/suffix shown as part of the field text (e.g. " m", " %").
  /// When set, the value is displayed as "18m" and parsing on commit strips the
  /// suffix so "42 m" and "50%" work.
  final String? suffix;
  final TextStyle? labelTextStyle;
  final TextStyle? valueTextStyle;
  final TextStyle? hintTextStyle;

  /// Unused when [suffix] is set (suffix is drawn with [valueTextStyle] in-field).
  final TextStyle? suffixTextStyle;
  final double dragIconSize;

  @override
  State<NumericDragInput> createState() => _NumericDragInputState();
}

class _NumericDragInputState extends State<NumericDragInput> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  bool _isDragging = false;
  double _dragStartValue = 0;
  double _dragDeltaX = 0;

  double get _min => widget.min;
  double get _max => widget.max;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focusNode = FocusNode();
    _controller.text = _valueToDisplay(widget.value);
    _focusNode.addListener(_onFocusChange);
    _controller.addListener(_onTextChange);
  }

  @override
  void didUpdateWidget(NumericDragInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_isDragging) {
      _controller.text = _valueToDisplay(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChange);
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onTextChange() => setState(() {});

  void _onFocusChange() {
    if (!_focusNode.hasFocus) {
      _commitText();
    }
    setState(() {});
  }

  static String _formatValue(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _valueToDisplay(double v) =>
      _formatValue(v) + (widget.suffix?.trim() ?? '');

  double _clampValue(double value) => value.clamp(_min, _max);

  static double _distanceAdjustedDelta(double distance) {
    if (distance <= 40) return distance * 0.05;
    if (distance <= 160) return 2 + ((distance - 40) * 0.20);
    return 26 + ((distance - 160) * 0.50);
  }

  static EdgeInsets _resolveInsets(
    BuildContext context,
    EdgeInsetsGeometry insets,
  ) {
    return insets.resolve(Directionality.of(context));
  }

  void _setValue(double nextValue, {required bool commitToText}) {
    final clamped = _clampValue(nextValue);
    widget.onChanged(clamped);
    if (commitToText) {
      _controller.text = _valueToDisplay(clamped);
    }
  }

  void _handlePanStart(DragStartDetails details) {
    setState(() {
      _isDragging = true;
      _dragStartValue = widget.value;
      _dragDeltaX = 0;
    });
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    _dragDeltaX += details.delta.dx;
    final adjusted =
        _distanceAdjustedDelta(_dragDeltaX.abs()) * _dragDeltaX.sign;
    _setValue(_dragStartValue + adjusted, commitToText: true);
  }

  void _handlePanEnd(DragEndDetails details) {
    setState(() {
      _isDragging = false;
      _controller.text = _valueToDisplay(widget.value);
    });
  }

  String _stripSuffix(String text) {
    var t = text.trim();
    final s = widget.suffix?.trim();
    if (s == null || s.isEmpty) return t;
    if (t.endsWith(s)) {
      return t.substring(0, t.length - s.length).trim();
    }
    if (t.endsWith(' $s')) {
      return t.substring(0, t.length - s.length - 1).trim();
    }
    return t;
  }

  void _commitText() {
    final raw = _controller.text;
    final text = _stripSuffix(raw);
    final parsed = double.tryParse(text);
    if (parsed == null) {
      _controller.text = _valueToDisplay(widget.value);
      return;
    }
    _setValue(parsed, commitToText: true);
  }

  @override
  Widget build(BuildContext context) {
    final shadTheme = ShadTheme.of(context);
    final colorScheme = shadTheme.colorScheme;
    final isFocused = _focusNode.hasFocus;
    final labelStyle =
        (widget.labelTextStyle ?? shadTheme.textTheme.lead).copyWith(
      color: _isDragging ? colorScheme.primary : colorScheme.mutedForeground,
    );
    final valueStyle = (widget.valueTextStyle ?? shadTheme.textTheme.lead)
        .copyWith(color: colorScheme.foreground);
    final hintStyle = (widget.hintTextStyle ?? shadTheme.textTheme.lead)
        .copyWith(color: colorScheme.mutedForeground);

    return LayoutBuilder(
      builder: (context, constraints) {
        final leadingPadding = _resolveInsets(context, widget.leadingPadding);
        final trailingPadding = _resolveInsets(context, widget.trailingPadding);
        final suffix = widget.suffix?.trim();
        final textField = TextField(
          controller: _controller,
          focusNode: _focusNode,
          keyboardType: widget.keyboardType,
          onSubmitted: (_) => _commitText(),
          maxLines: 1,
          style: valueStyle,
          inputFormatters: suffix != null && suffix.isNotEmpty
              ? [_SuffixFormatter(suffix)]
              : null,
          decoration: InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            hoverColor: Colors.transparent,
            filled: true,
            fillColor: Colors.transparent,
            hintText: widget.hintText,
            hintStyle: hintStyle,
            isCollapsed: true,
            contentPadding: EdgeInsets.zero,
          ),
        );

        return Container(
          constraints: BoxConstraints(
            minHeight: widget.minHeight,
            minWidth: widget.minWidth,
          ),
          decoration: BoxDecoration(
            color: colorScheme.secondary,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isFocused ? colorScheme.ring : colorScheme.border,
              width: 2,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: GestureDetector(
                  onPanStart: _handlePanStart,
                  onPanUpdate: _handlePanUpdate,
                  onPanEnd: _handlePanEnd,
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: Padding(
                      padding: leadingPadding,
                      child: widget.leading ??
                          Text(widget.label, style: labelStyle),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: textField,
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: GestureDetector(
                  onPanStart: _handlePanStart,
                  onPanUpdate: _handlePanUpdate,
                  onPanEnd: _handlePanEnd,
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: Padding(
                      padding: trailingPadding,
                      child: Icon(
                        Icons.drag_indicator,
                        size: widget.dragIconSize,
                        color: _isDragging
                            ? colorScheme.primary
                            : colorScheme.mutedForeground,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
