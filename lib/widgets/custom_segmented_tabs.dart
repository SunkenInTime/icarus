import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';

enum SegmentedIndicatorBehavior {
  slidingPill,
  staticFill,
}

class SegmentedTabItem<T> {
  const SegmentedTabItem({required this.value, required this.child});

  final T value;
  final Widget child;
}

class CustomSegmentedTabs<T> extends StatefulWidget {
  const CustomSegmentedTabs({
    required this.items,
    required this.value,
    required this.onChanged,
    this.compactness = 0.35,
    this.segmentSpacing,
    this.segmentHorizontalPadding,
    this.segmentVerticalPadding,
    this.maxWidth,
    this.padding,
    this.animationDuration = const Duration(milliseconds: 240),
    this.animationCurve = Curves.easeInOutCubic,
    this.indicatorBehavior = SegmentedIndicatorBehavior.slidingPill,
    super.key,
  });

  final List<SegmentedTabItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;

  /// A density control in range [0, 1].
  ///
  /// - `0` = roomier tabs.
  /// - `1` = compact tabs with reduced spacing and padding.
  final double compactness;

  /// Spacing between each segment.
  ///
  /// If null, it is derived from `compactness`.
  final double? segmentSpacing;

  /// Horizontal padding inside each segment.
  ///
  /// If null, it is derived from `compactness`.
  final double? segmentHorizontalPadding;

  /// Vertical padding inside each segment.
  ///
  /// If null, it is derived from `compactness`.
  final double? segmentVerticalPadding;

  final double? maxWidth;
  final EdgeInsetsGeometry? padding;
  final Duration animationDuration;
  final Curve animationCurve;
  final SegmentedIndicatorBehavior indicatorBehavior;

  @override
  State<CustomSegmentedTabs<T>> createState() => _CustomSegmentedTabsState<T>();
}

class _CustomSegmentedTabsState<T> extends State<CustomSegmentedTabs<T>> {
  static const double _containerRadius = 6;
  static const double _segmentRadius = 5;

  final GlobalKey _stackKey = GlobalKey();
  late List<GlobalKey> _tabKeys;
  late List<double> _segmentLefts;
  late List<double> _segmentWidths;

  @override
  void initState() {
    super.initState();
    _initTabKeys();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureSegments());
  }

  @override
  void didUpdateWidget(covariant CustomSegmentedTabs<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      _initTabKeys();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureSegments());
  }

  void _initTabKeys() {
    _tabKeys =
        List<GlobalKey>.generate(widget.items.length, (_) => GlobalKey());
    _segmentLefts = List<double>.filled(widget.items.length, 0);
    _segmentWidths = List<double>.filled(widget.items.length, 0);
  }

  void _measureSegments() {
    if (!mounted || widget.items.isEmpty) {
      return;
    }

    final stackContext = _stackKey.currentContext;
    if (stackContext == null) {
      return;
    }

    final stackRenderObject = stackContext.findRenderObject();
    if (stackRenderObject is! RenderBox) {
      return;
    }

    bool changed = false;

    for (int i = 0; i < _tabKeys.length; i++) {
      final tabContext = _tabKeys[i].currentContext;
      if (tabContext == null) {
        continue;
      }

      final tabRenderObject = tabContext.findRenderObject();
      if (tabRenderObject is! RenderBox) {
        continue;
      }

      final left = tabRenderObject
          .localToGlobal(Offset.zero, ancestor: stackRenderObject)
          .dx;
      final width = tabRenderObject.size.width;

      if ((_segmentLefts[i] - left).abs() > 0.5 ||
          (_segmentWidths[i] - width).abs() > 0.5) {
        _segmentLefts[i] = left;
        _segmentWidths[i] = width;
        changed = true;
      }
    }

    if (changed) {
      setState(() {});
    }
  }

  int get _selectedIndex {
    final index = widget.items.indexWhere((item) => item.value == widget.value);
    return index == -1 ? 0 : index;
  }

  bool get _hasSelectedMeasurement {
    if (widget.items.isEmpty) {
      return false;
    }
    final index = _selectedIndex;
    return index >= 0 &&
        index < _segmentWidths.length &&
        _segmentWidths[index] > 0;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    final clampedCompactness = widget.compactness.clamp(0.0, 1.0);
    final horizontalInset = lerpDouble(5, 2, clampedCompactness)!;
    final verticalInset = lerpDouble(5, 2, clampedCompactness)!;
    final itemGap =
        widget.segmentSpacing ?? lerpDouble(4, 1.5, clampedCompactness)!;
    final itemHorizontalPadding = widget.segmentHorizontalPadding ??
        lerpDouble(10, 5, clampedCompactness)!;
    final itemVerticalPadding =
        widget.segmentVerticalPadding ?? lerpDouble(7, 4, clampedCompactness)!;

    final selectedIndex = _selectedIndex;

    Widget content = Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.secondary,
        borderRadius: BorderRadius.circular(_containerRadius),
        border: Border.all(
          color: Settings.tacticalVioletTheme.border,
          width: 1,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalInset,
          vertical: verticalInset,
        ),
        child: Stack(
          key: _stackKey,
          children: [
            if (widget.indicatorBehavior ==
                    SegmentedIndicatorBehavior.slidingPill &&
                _hasSelectedMeasurement)
              AnimatedPositioned(
                duration: widget.animationDuration,
                curve: widget.animationCurve,
                left: _segmentLefts[selectedIndex],
                top: 0,
                width: _segmentWidths[selectedIndex],
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Settings.tacticalVioletTheme.primary,
                    borderRadius: BorderRadius.circular(_segmentRadius),
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (int index = 0; index < widget.items.length; index++) ...[
                  _TabButton<T>(
                    key: _tabKeys[index],
                    isSelected: index == selectedIndex,
                    item: widget.items[index],
                    onTap: () => widget.onChanged(widget.items[index].value),
                    behavior: widget.indicatorBehavior,
                    animationDuration: widget.animationDuration,
                    animationCurve: widget.animationCurve,
                    horizontalPadding: itemHorizontalPadding,
                    verticalPadding: itemVerticalPadding,
                    borderRadius: _segmentRadius,
                  ),
                  if (index < widget.items.length - 1) SizedBox(width: itemGap),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    if (widget.maxWidth != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth!),
        child: content,
      );
    }

    return content;
  }
}

class _TabButton<T> extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.item,
    required this.isSelected,
    required this.onTap,
    required this.behavior,
    required this.animationDuration,
    required this.animationCurve,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.borderRadius,
  });

  final SegmentedTabItem<T> item;
  final bool isSelected;
  final VoidCallback onTap;
  final SegmentedIndicatorBehavior behavior;
  final Duration animationDuration;
  final Curve animationCurve;
  final double horizontalPadding;
  final double verticalPadding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final bool showStaticFill =
        behavior == SegmentedIndicatorBehavior.staticFill;

    final Color textColor = isSelected
        ? Settings.tacticalVioletTheme.primaryForeground
        : Settings.tacticalVioletTheme.mutedForeground;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(borderRadius),
        onTap: onTap,
        child: AnimatedContainer(
          duration: animationDuration,
          curve: animationCurve,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            color: showStaticFill && isSelected
                ? Settings.tacticalVioletTheme.primary
                : Colors.transparent,
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              color: textColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            child: item.child,
          ),
        ),
      ),
    );
  }
}
