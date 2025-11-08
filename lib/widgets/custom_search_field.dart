import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';

/// A themed search text field that smoothly expands (slides out) when:
/// - Hovered by the pointer
/// - Focused
/// - It contains any text
///
/// Otherwise, it collapses back to a compact width showing only the search icon.
///
/// Customization:
/// - [collapsedWidth]: width when idle
/// - [expandedWidth]: width when active (hover/focus/has text)
/// - [duration] / [curve]: animation timing
/// - [hintText]: hint displayed only while expanded and empty
/// - [onSubmitted]: callback for search action
class SearchTextField extends ConsumerStatefulWidget {
  const SearchTextField({
    super.key,
    this.controller,
    this.hintText = 'Search',
    this.onSubmitted,
    this.collapsedWidth = 44,
    this.expandedWidth = 260,
    this.duration = const Duration(milliseconds: 250),
    this.curve = Curves.easeOutCubic,
    this.compact = false,
  });

  final TextEditingController? controller;
  final String hintText;
  final ValueChanged<String>? onSubmitted;
  final double collapsedWidth;
  final double expandedWidth;
  final Duration duration;
  final Curve curve;
  final bool compact;

  @override
  ConsumerState<SearchTextField> createState() => _SearchTextFieldState();
}

class _SearchTextFieldState extends ConsumerState<SearchTextField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  late final FocusNode _focusNode = FocusNode();
  bool _hovering = false;

  bool get _hasText => _controller.text.isNotEmpty;
  bool get _expanded => _hovering || _focusNode.hasFocus || _hasText;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleTextChanged);
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleTextChanged() {
    // Expansion depends on whether text is empty; trigger rebuild.
    setState(() {});
  }

  void _handleFocusChange() {
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTextChanged);
    _focusNode.removeListener(_handleFocusChange);
    if (widget.controller == null) {
      _controller.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    // After clearing, collapse if not hovering (will rebuild).
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: compact ? 14 : 16,
      height: 1.2,
    );

    final contentPadding = compact
        ? const EdgeInsets.symmetric(vertical: 6, horizontal: 8)
        : const EdgeInsets.symmetric(vertical: 12, horizontal: 12);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        width: _expanded ? widget.expandedWidth : widget.collapsedWidth,
        duration: widget.duration,
        curve: widget.curve,
        // Let the height be intrinsic.
        alignment: Alignment.centerLeft,
        child: Shortcuts(
          shortcuts: ShortcutInfo.textEditingOverrides,
          child: _buildField(textStyle, contentPadding, compact),
        ),
      ),
    );
  }

  Widget _buildField(
      TextStyle textStyle, EdgeInsets contentPadding, bool compact) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      textInputAction: TextInputAction.search,
      onSubmitted: widget.onSubmitted,
      style: textStyle,
      cursorColor: Settings.highlightColor,
      decoration: InputDecoration(
        isDense: compact,
        contentPadding: contentPadding,
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
        hintText: _expanded ? widget.hintText : null,
        hintStyle: TextStyle(
          color: Colors.white54,
          fontSize: compact ? 14 : 16,
        ),
        prefixIcon: Padding(
          padding: compact
              ? const EdgeInsets.only(left: 8, right: 4)
              : const EdgeInsets.only(left: 12, right: 8),
          child: Icon(
            Icons.search,
            color: Colors.white54,
            size: compact ? 18 : 20,
          ),
        ),
        prefixIconConstraints: BoxConstraints(
          minWidth: compact ? 32 : 40,
          minHeight: compact ? 32 : 40,
        ),
        suffixIcon: _hasText
            ? IconButton(
                tooltip: 'Clear',
                icon: Icon(
                  Icons.close,
                  size: compact ? 18 : 20,
                  color: Colors.white70,
                ),
                onPressed: _clear,
              )
            : null,
      ),
      // When collapsed and user taps, force expansion by focusing.
      onTap: () {
        if (!_expanded) {
          _focusNode.requestFocus();
        }
      },
    );
  }
}
