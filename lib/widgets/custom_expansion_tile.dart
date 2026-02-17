import 'package:flutter/material.dart';

class CustomExpansionTile extends StatefulWidget {
  /// Creates a custom expansion tile that keeps a persistent row visible
  /// even when the tile is collapsed.
  const CustomExpansionTile({
    super.key,
    this.title,
    this.leading,
    this.persistentRow,
    this.children = const <Widget>[],
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.backgroundColor,
    this.collapsedBackgroundColor,
    this.textColor,
    this.collapsedTextColor,
    this.iconColor,
    this.collapsedIconColor,
    this.expandedAlignment,
    this.expandedCrossAxisAlignment,
    this.childrenPadding,
    this.tilePadding,
    this.trailing,
    this.maintainState = false,
  });

  /// The primary content of the tile's title.
  final Widget? title;

  /// A widget to display before the title.
  final Widget? leading;

  /// A widget that remains visible even when the expansion tile is collapsed.
  final List<Widget>? persistentRow;

  /// The widgets that are displayed when the tile expands.
  final List<Widget> children;

  /// Whether the tile is initially expanded.
  final bool initiallyExpanded;

  /// Called when the tile expands or collapses.
  final ValueChanged<bool>? onExpansionChanged;

  /// The background color of the expanded tile.
  final Color? backgroundColor;

  /// The background color of the collapsed tile.
  final Color? collapsedBackgroundColor;

  /// The color of the title text when expanded.
  final Color? textColor;

  /// The color of the title text when collapsed.
  final Color? collapsedTextColor;

  /// The color of the expansion icon when expanded.
  final Color? iconColor;

  /// The color of the expansion icon when collapsed.
  final Color? collapsedIconColor;

  /// The alignment of the children when expanded.
  final Alignment? expandedAlignment;

  /// The cross axis alignment of the children when expanded.
  final CrossAxisAlignment? expandedCrossAxisAlignment;

  /// Padding for the expanded children.
  final EdgeInsetsGeometry? childrenPadding;

  /// Padding for the title and persistent row.
  final EdgeInsetsGeometry? tilePadding;

  /// A widget to display at the end of the title row.
  final Widget? trailing;

  /// Whether to maintain the state of the children when collapsed.
  final bool maintainState;

  @override
  State<CustomExpansionTile> createState() => _CustomExpansionTileState();
}

class _CustomExpansionTileState extends State<CustomExpansionTile>
    with SingleTickerProviderStateMixin {
  static final Animatable<double> _easeInTween =
      CurveTween(curve: Curves.easeIn);
  static final Animatable<double> _halfTween =
      Tween<double>(begin: 0.0, end: 0.5);

  late AnimationController _controller;
  late Animation<double> _iconTurns;
  late Animation<double> _heightFactor;

  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _heightFactor = _controller.drive(_easeInTween);
    _iconTurns = _controller.drive(_halfTween.chain(_easeInTween));

    _isExpanded = widget.initiallyExpanded;
    if (_isExpanded) {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
      widget.onExpansionChanged?.call(_isExpanded);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final Color backgroundColor = _isExpanded
        ? widget.backgroundColor ?? Colors.transparent
        : widget.collapsedBackgroundColor ?? Colors.transparent;

    final Color? titleColor = _isExpanded
        ? widget.textColor ?? colorScheme.primary
        : widget.collapsedTextColor ?? theme.textTheme.titleMedium?.color;

    final Color iconColor = _isExpanded
        ? widget.iconColor ?? colorScheme.primary
        : widget.collapsedIconColor ?? theme.unselectedWidgetColor;

    return Material(
      color: backgroundColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Title row with expansion control
          InkWell(
            mouseCursor: SystemMouseCursors.click,
            onTap: _handleTap,
            child: Padding(
              padding: widget.tilePadding ??
                  const EdgeInsets.only(left: 16.0, right: 16, top: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  if (widget.leading != null) widget.leading!,
                  if (widget.title != null)
                    Expanded(
                      child: DefaultTextStyle(
                        style: theme.textTheme.titleMedium!
                            .copyWith(color: titleColor),
                        child: widget.title!,
                      ),
                    ),
                  widget.trailing ??
                      RotationTransition(
                        turns: _iconTurns,
                        child: Icon(
                          Icons.expand_more,
                          color: iconColor,
                        ),
                      ),
                ],
              ),
            ),
          ),

          // Persistent row that's always visible
          if (widget.persistentRow != null)
            Padding(
              padding: widget.tilePadding ??
                  const EdgeInsets.symmetric(vertical: 8.0),
              child: Column(
                children: widget.persistentRow!,
              ),
            ),

          // Expandable children
          ClipRect(
            child: AnimatedBuilder(
              animation: _controller.view,
              builder: (BuildContext context, Widget? child) {
                return Align(
                  alignment: widget.expandedAlignment ?? Alignment.center,
                  heightFactor: _heightFactor.value,
                  child: child,
                );
              },
              child: _isExpanded || widget.maintainState
                  ? Padding(
                      padding: widget.childrenPadding ?? EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: widget.expandedCrossAxisAlignment ??
                            CrossAxisAlignment.center,
                        children: widget.children,
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
