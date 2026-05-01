import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _pagesBarCornerRadius = 12;
const double _pagesBarInnerButtonRadius = 6;

class PagesBar extends ConsumerStatefulWidget {
  const PagesBar({super.key});

  @override
  ConsumerState<PagesBar> createState() => _PagesBarState();
}

class _PagesBarState extends ConsumerState<PagesBar> {
  static const double _defaultExpandedHeight = 310;
  static const double _defaultWidth = 224;
  static const double _minWidth = 224;
  static const double _maxWidth = 420;
  static const double _widthResizeHandleWidth = 8;
  static final double _minExpandedHeight =
      _ExpandedPanel.minHeightForVisibleRows(
    2,
  );
  static const double _maxExpandedHeight = 520;

  bool _expanded = false;
  bool _isHeightResizing = false;
  bool _isWidthResizing = false;
  double? _liveExpandedHeight;
  double? _liveWidth;
  double? _persistedExpandedHeightCache;
  double? _persistedWidthCache;
  final GlobalKey _expandedPanelKey = GlobalKey();
  final GlobalKey _barKey = GlobalKey();

  StrategyData? _strategy(Box<StrategyData> box, String id) => box.get(id);

  double _clampExpandedHeight(double height) {
    return height.clamp(_minExpandedHeight, _maxExpandedHeight).toDouble();
  }

  double _clampWidth(double width) {
    return width.clamp(_minWidth, _maxWidth).toDouble();
  }

  double _effectiveExpandedHeight(double persistedHeight) {
    final baseHeight = _persistedExpandedHeightCache ?? persistedHeight;
    return _clampExpandedHeight(
      _isHeightResizing ? (_liveExpandedHeight ?? baseHeight) : baseHeight,
    );
  }

  double _effectiveWidth(double persistedWidth) {
    final baseWidth = _persistedWidthCache ?? persistedWidth;
    return _clampWidth(
        _isWidthResizing ? (_liveWidth ?? baseWidth) : baseWidth);
  }

  void _startHeightResize() {
    final context = _expandedPanelKey.currentContext;
    final renderBox = context?.findRenderObject() as RenderBox?;
    final renderedHeight = renderBox != null && renderBox.hasSize
        ? renderBox.size.height
        : (_persistedExpandedHeightCache ?? _defaultExpandedHeight);

    setState(() {
      _isHeightResizing = true;
      _liveExpandedHeight = _clampExpandedHeight(renderedHeight);
    });
  }

  void _updateHeightResize(Offset globalPosition) {
    final context = _expandedPanelKey.currentContext;
    if (context == null) return;

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;

    final localPosition = renderBox.globalToLocal(globalPosition);
    final nextHeight =
        _clampExpandedHeight(renderBox.size.height - localPosition.dy);
    final currentHeight = _liveExpandedHeight;
    if (currentHeight != null && (nextHeight - currentHeight).abs() < 0.5) {
      return;
    }

    setState(() {
      _liveExpandedHeight = nextHeight;
    });
  }

  Future<void> _endHeightResize() async {
    if (!_isHeightResizing) return;

    final height = _clampExpandedHeight(
      _liveExpandedHeight ??
          _persistedExpandedHeightCache ??
          _defaultExpandedHeight,
    );

    setState(() {
      _isHeightResizing = false;
      _liveExpandedHeight = null;
      _persistedExpandedHeightCache = height;
    });

    await ref
        .read(appPreferencesProvider.notifier)
        .setPagesBarExpandedHeight(height);

    if (!mounted) return;
    setState(() {
      _persistedExpandedHeightCache = null;
    });
  }

  void _startWidthResize() {
    final context = _barKey.currentContext;
    final renderBox = context?.findRenderObject() as RenderBox?;
    final renderedWidth = renderBox != null && renderBox.hasSize
        ? renderBox.size.width
        : (_persistedWidthCache ?? _defaultWidth);

    setState(() {
      _isWidthResizing = true;
      _liveWidth = _clampWidth(renderedWidth);
    });
  }

  void _updateWidthResize(Offset globalPosition) {
    final context = _barKey.currentContext;
    if (context == null) return;

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;

    final localPosition = renderBox.globalToLocal(globalPosition);
    final nextWidth = _clampWidth(localPosition.dx);
    final currentWidth = _liveWidth;
    if (currentWidth != null && (nextWidth - currentWidth).abs() < 0.5) {
      return;
    }

    setState(() {
      _liveWidth = nextWidth;
    });
  }

  Future<void> _endWidthResize() async {
    if (!_isWidthResizing) return;

    final width =
        _clampWidth(_liveWidth ?? _persistedWidthCache ?? _defaultWidth);

    setState(() {
      _isWidthResizing = false;
      _liveWidth = null;
      _persistedWidthCache = width;
    });

    await ref.read(appPreferencesProvider.notifier).setPagesBarWidth(width);

    if (!mounted) return;
    setState(() {
      _persistedWidthCache = null;
    });
  }

  Future<void> _collapsePanel() async {
    if (_isHeightResizing) {
      await _endHeightResize();
    }
    if (_isWidthResizing) {
      await _endWidthResize();
    }
    if (!mounted) return;
    setState(() => _expanded = false);
  }

  Future<void> _addPage() async {
    await ref.read(strategyProvider.notifier).addPage();
  }

  Future<void> _selectPage(String id) async {
    if (id == ref.read(strategyProvider.notifier).activePageID) return;
    await ref.read(strategyProvider.notifier).setActivePageAnimated(id);
  }

  Future<void> _renamePage(StrategyData strat, StrategyPage page) async {
    final controller = TextEditingController(text: page.name);
    final newName = await showShadDialog<String>(
      context: context,
      builder: (ctx) => ShadDialog(
        title: const Text("Rename page"),
        description: const Text("Enter a new name for the page:"),
        actions: [
          ShadButton.secondary(
            onPressed: () => Navigator.of(ctx).pop(),
            backgroundColor: Settings.tacticalVioletTheme.border,
            child: const Text("Cancel"),
          ),
          ShadButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            leading: const Icon(Icons.text_fields),
            child: const Text("Rename"),
          ),
        ],
        child: CustomTextField(
          // autofocus: true,
          controller: controller,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
      ),
    );
    if (newName == null || newName.isEmpty || newName == page.name) return;

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final updatedPages = [
      for (final p in strat.pages)
        if (p.id == page.id) p.copyWith(name: newName) else p,
    ];
    final updated =
        strat.copyWith(pages: updatedPages, lastEdited: DateTime.now());
    await box.put(updated.id, updated);
    controller.dispose();
  }

  Future<void> _deletePage(StrategyData strat, StrategyPage page) async {
    if (strat.pages.length == 1) return; // cannot delete last

    final confirm = await ConfirmAlertDialog.show(
      context: context,
      title: "Delete '${page.name}'?",
      content:
          "Are you sure you want to delete this page? This action cannot be undone.",
      confirmText: "Delete",
      cancelText: "Cancel",
      isDestructive: true,
    );

    if (confirm != true) return;

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final remaining = [...strat.pages]..removeWhere((p) => p.id == page.id);
    // Reindex sortIndex to keep dense ordering
    final reindexed = [
      for (var i = 0; i < remaining.length; i++)
        remaining[i].copyWith(sortIndex: i),
    ];
    final activeId = ref.read(strategyProvider.notifier).activePageID;
    final newActive = (activeId == page.id) ? reindexed.first.id : activeId;

    final updated = strat.copyWith(
      pages: reindexed,
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
    if (newActive != activeId) {
      if (newActive != null)
        await ref
            .read(strategyProvider.notifier)
            .setActivePageAnimated(newActive);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strategyId = ref.watch(strategyProvider).id;
    final activePageIdFromState =
        ref.watch(strategyProvider.select((state) => state.activePageId));
    final persistedExpandedHeight = ref.watch(
      appPreferencesProvider.select((prefs) => prefs.pagesBarExpandedHeight),
    );
    final persistedWidth = ref.watch(
      appPreferencesProvider.select((prefs) => prefs.pagesBarWidth),
    );
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    return ValueListenableBuilder(
      valueListenable: box.listenable(keys: [strategyId]),
      builder: (context, Box<StrategyData> b, _) {
        final strat = _strategy(b, strategyId);
        if (strat == null) return const SizedBox();

        final pages = [...strat.pages]
          ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
        final activePageId =
            activePageIdFromState ?? (pages.isNotEmpty ? pages.first.id : null);
        final activeName = pages
            .firstWhere(
              (p) => p.id == activePageId,
              orElse: () => pages.first,
            )
            .name;

        final width = _effectiveWidth(persistedWidth);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              key: _barKey,
              decoration: BoxDecoration(
                color: Settings.tacticalVioletTheme.card,
                borderRadius: BorderRadius.circular(_pagesBarCornerRadius),
                border: Border.all(
                  color: Settings.tacticalVioletTheme.border,
                  width: 2,
                ),
              ),
              width: width,
              padding: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.only(right: _widthResizeHandleWidth),
                child: _expanded
                    ? _ExpandedPanel(
                        pages: pages,
                        activePageId: activePageId,
                        height:
                            _effectiveExpandedHeight(persistedExpandedHeight),
                        panelKey: _expandedPanelKey,
                        onSelect: _selectPage,
                        onRename: (p) => _renamePage(strat, p),
                        onDelete: (p) => _deletePage(strat, p),
                        onAdd: _addPage,
                        onCollapse: _collapsePanel,
                        onResizeStart: _startHeightResize,
                        onResizeUpdate: _updateHeightResize,
                        onResizeEnd: _endHeightResize,
                        isResizeActive: _isHeightResizing,
                      )
                    : _CollapsedPill(
                        activeName: activeName,
                        onAdd: _addPage,
                        onToggle: () => setState(() => _expanded = true),
                      ),
              ),
            ),
            Positioned(
              top: 0,
              right: 2,
              bottom: 0,
              child: _ResizeHandle(
                width: _widthResizeHandleWidth,
                axis: Axis.horizontal,
                onResizeStart: _startWidthResize,
                onResizeUpdate: _updateWidthResize,
                onResizeEnd: _endWidthResize,
                isActive: _isWidthResizing,
              ),
            ),
          ],
        );
      },
    );
  }
}

/* -------- Collapsed pill -------- */
class _CollapsedPill extends StatelessWidget {
  const _CollapsedPill({
    required this.activeName,
    required this.onAdd,
    required this.onToggle,
  });

  final String activeName;
  final VoidCallback onAdd;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 8),
          _SquareIconButton(
            icon: Icons.add,
            onTap: onAdd,
            tooltip: "Add page",
            color: Settings.tacticalVioletTheme.primary,
            shortcutLabel: 'C',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              activeName,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14),
            ),
          ),
          ShadIconButton.ghost(
            foregroundColor: Colors.white,
            onPressed: onToggle,
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/* -------- Expanded panel -------- */
class _ExpandedPanel extends ConsumerWidget {
  const _ExpandedPanel({
    required this.pages,
    required this.activePageId,
    required this.height,
    required this.panelKey,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.onAdd,
    required this.onCollapse,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    required this.isResizeActive,
  });

  final List<StrategyPage> pages;
  final String? activePageId;
  final double height;
  final GlobalKey panelKey;
  final ValueChanged<String> onSelect;
  final ValueChanged<StrategyPage> onRename;
  final ValueChanged<StrategyPage> onDelete;
  final VoidCallback onAdd;
  final VoidCallback onCollapse;
  final VoidCallback onResizeStart;
  final ValueChanged<Offset> onResizeUpdate;
  final Future<void> Function() onResizeEnd;
  final bool isResizeActive;

  static const double _rowHeight = 40; // each page tile height
  static const double _verticalSpacing = 10; // separator height
  static const double _resizeHandleHeight = 8;
  static const double _headerFooterHeight = 48 + 1; // bottom bar + divider
  static const double _topPadding = 0; // handle + gap should match side inset
  static const double _bottomPadding = 0; // list bottom padding inside Expanded

  static double minHeightForVisibleRows(int visibleRows) {
    final clampedRows = visibleRows < 1 ? 1 : visibleRows;
    final rowsHeight = clampedRows * _rowHeight;
    final spacersHeight = (clampedRows - 1) * 8.0;
    final listSection =
        _topPadding + rowsHeight + spacersHeight + _bottomPadding + 8;
    return _resizeHandleHeight + listSection + _headerFooterHeight;
  }

  Widget proxyDecorator(Widget child, int index, Animation<double> animation) {
    return child;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listViewportHeight =
        height - _resizeHandleHeight - _headerFooterHeight - _topPadding - 8;
    final availableListHeight = listViewportHeight > 0 ? listViewportHeight : 0;
    final contentListHeight = pages.isEmpty
        ? 56.0
        : (pages.length * _rowHeight) + ((pages.length - 1) * _verticalSpacing);
    final needsScroll = contentListHeight > availableListHeight + 0.5;
    final activeIndex = activePageId == null
        ? -1
        : pages.indexWhere((p) => p.id == activePageId);
    final transitionState = ref.watch(transitionProvider);

    int? backwardIndex;
    int? forwardIndex;
    if (activeIndex >= 0 && pages.isNotEmpty) {
      backwardIndex = activeIndex - 1;
      if (backwardIndex < 0) backwardIndex = pages.length - 1;

      forwardIndex = activeIndex + 1;
      if (forwardIndex >= pages.length) forwardIndex = 0;
    }

    return SizedBox(
      key: panelKey,
      height: height,
      child: Column(
        children: [
          _ResizeHandle(
            height: _resizeHandleHeight,
            axis: Axis.vertical,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
            isActive: isResizeActive,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: _topPadding),
              child: ScrollConfiguration(
                behavior:
                    ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: ReorderableListView.builder(
                  onReorder: (oldIndex, newIndex) {
                    ref
                        .read(strategyProvider.notifier)
                        .reorderPage(oldIndex, newIndex);
                  },
                  padding: const EdgeInsets.fromLTRB(8, 0, 0, 8),
                  shrinkWrap: false,
                  physics:
                      needsScroll ? null : const NeverScrollableScrollPhysics(),
                  itemCount: pages.length,
                  buildDefaultDragHandles: false,
                  proxyDecorator: proxyDecorator,
                  itemBuilder: (ctx, i) {
                    bool showForwardIndicator = false;
                    bool showBackwardIndicator = false;
                    final p = pages[i];

                    if (pages.length != 1) {
                      if (pages.length == 2) {
                        if (activeIndex == 0 && activeIndex != i) {
                          showForwardIndicator = true;
                        } else if (activeIndex == 1 && activeIndex != i) {
                          showBackwardIndicator = true;
                        }
                      } else {
                        if (forwardIndex != null && i == forwardIndex) {
                          showForwardIndicator = true;
                        }
                        if (backwardIndex != null &&
                            i == backwardIndex &&
                            forwardIndex != backwardIndex) {
                          showBackwardIndicator = true;
                        }
                      }
                    }

                    return ReorderableDragStartListener(
                      key: ValueKey(p.id),
                      index: i,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _PageRow(
                          page: p,
                          active: p.id == activePageId,
                          showBackwardIndicator: showBackwardIndicator,
                          showForwardIndicator: showForwardIndicator,
                          transitionProgress:
                              _rowTransitionProgress(transitionState, p.id),
                          onSelect: onSelect,
                          onRename: onRename,
                          onDelete: onDelete,
                          disableDelete: pages.length == 1,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          Divider(height: 1, color: Settings.tacticalVioletTheme.border),
          SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 8),
                _SquareIconButton(
                  icon: Icons.add,
                  onTap: onAdd,
                  tooltip: "Add page",
                  color: Settings.tacticalVioletTheme.primary,
                  shortcutLabel: 'C',
                ),
                const Spacer(),
                ShadIconButton.ghost(
                  foregroundColor: Colors.white,
                  onPressed: onCollapse,
                  icon:
                      const Icon(Icons.keyboard_arrow_up, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  double? _rowTransitionProgress(PageTransitionState state, String pageId) {
    if (state.phase != PageTransitionPhase.preparing &&
        state.phase != PageTransitionPhase.animating) {
      return null;
    }
    if (state.sourcePageId == pageId) return 1 - state.progress;
    if (state.targetPageId == pageId) return state.progress;
    return null;
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    this.height,
    this.width,
    required this.axis,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    required this.isActive,
  });

  final double? height;
  final double? width;
  final Axis axis;
  final VoidCallback onResizeStart;
  final ValueChanged<Offset> onResizeUpdate;
  final Future<void> Function() onResizeEnd;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return _ResizeHandleStateful(
      height: height,
      width: width,
      axis: axis,
      onResizeStart: onResizeStart,
      onResizeUpdate: onResizeUpdate,
      onResizeEnd: onResizeEnd,
      isActive: isActive,
    );
  }
}

class _ResizeHandleStateful extends StatefulWidget {
  const _ResizeHandleStateful({
    this.height,
    this.width,
    required this.axis,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    required this.isActive,
  });

  final double? height;
  final double? width;
  final Axis axis;
  final VoidCallback onResizeStart;
  final ValueChanged<Offset> onResizeUpdate;
  final Future<void> Function() onResizeEnd;
  final bool isActive;

  @override
  State<_ResizeHandleStateful> createState() => _ResizeHandleStatefulState();
}

class _ResizeHandleStatefulState extends State<_ResizeHandleStateful> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = widget.isActive || _isHovered;
    final handleColor = isHighlighted
        ? Settings.tacticalVioletTheme.primary
        : Colors.transparent;
    final isHorizontalResize = widget.axis == Axis.horizontal;

    return MouseRegion(
      cursor: isHorizontalResize
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => widget.onResizeStart(),
        onPanUpdate: (details) => widget.onResizeUpdate(details.globalPosition),
        onPanEnd: (_) {
          widget.onResizeEnd();
        },
        onPanCancel: () {
          widget.onResizeEnd();
        },
        child: SizedBox(
          height: widget.height ?? double.infinity,
          width: widget.width ?? double.infinity,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: isHorizontalResize ? 2 : 36,
              height: isHorizontalResize ? 36 : 2,
              decoration: BoxDecoration(
                color: handleColor,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageRow extends StatefulWidget {
  const _PageRow({
    required this.page,
    required this.active,
    required this.showBackwardIndicator,
    required this.showForwardIndicator,
    required this.transitionProgress,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.disableDelete,
  });

  final StrategyPage page;
  final bool active;
  final bool showBackwardIndicator;
  final bool showForwardIndicator;
  final double? transitionProgress;
  final ValueChanged<String> onSelect;
  final ValueChanged<StrategyPage> onRename;
  final ValueChanged<StrategyPage> onDelete;
  final bool disableDelete;

  static const double _rowHeight = 40;
  static const double _rowRadius = 6;

  @override
  State<_PageRow> createState() => _PageRowState();
}

class _PageRowState extends State<_PageRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fillProgress = widget.transitionProgress?.clamp(0.0, 1.0);
    final showActions =
        _hovered || widget.active || widget.transitionProgress != null;
    final bg = widget.active && fillProgress == null
        ? Settings.tacticalVioletTheme.primary
        : Settings.tacticalVioletTheme.card;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        // color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_PageRow._rowRadius),
        ),
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(_PageRow._rowRadius),
          onTap: () => widget.onSelect(widget.page.id),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_PageRow._rowRadius),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_PageRow._rowRadius),
                border: Border.all(
                  color: Settings.tacticalVioletTheme.border,
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                      color: Settings.tacticalVioletTheme.card
                          .withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 4))
                ],
                color: bg,
              ),
              height: _PageRow._rowHeight,
              child: Stack(
                children: [
                  if (fillProgress != null)
                    Positioned.fill(
                      child: FractionallySizedBox(
                        widthFactor: fillProgress,
                        alignment: Alignment.centerLeft,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Settings.tacticalVioletTheme.primary,
                          ),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.page.name,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: widget.active
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          if (widget.showBackwardIndicator ||
                              widget.showForwardIndicator) ...[
                            const SizedBox(width: 6),
                            if (widget.showBackwardIndicator)
                              const _KeybindBadge(label: "A"),
                            if (widget.showBackwardIndicator &&
                                widget.showForwardIndicator)
                              const SizedBox(width: 4),
                            if (widget.showForwardIndicator)
                              const _KeybindBadge(label: "D"),
                            const SizedBox(width: 2),
                          ],
                          if (showActions) ...[
                            ShadTooltip(
                              builder: (context) => const Text("Rename"),
                              child: ShadIconButton.ghost(
                                width: 24,
                                hoverBackgroundColor: Colors.transparent,
                                foregroundColor: Colors.white,
                                icon: const Icon(LucideIcons.pen,
                                    size: 18, color: Colors.white),
                                onPressed: () => widget.onRename(widget.page),
                              ),
                            ),
                            const SizedBox(width: 2),
                            ShadTooltip(
                              builder: (context) => const Text("Delete"),
                              child: ShadIconButton.ghost(
                                width: 24,
                                hoverForegroundColor:
                                    Settings.tacticalVioletTheme.destructive,
                                hoverBackgroundColor: Colors.transparent,
                                foregroundColor: widget.disableDelete
                                    ? Colors.white24
                                    : Colors.white,
                                icon: const Icon(
                                  LucideIcons.trash,
                                  size: 18,
                                ),
                                onPressed: widget.disableDelete
                                    ? null
                                    : () => widget.onDelete(widget.page),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeybindBadge extends StatelessWidget {
  const _KeybindBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 20,
      width: 20,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Center(
        child: Text(
          textAlign: TextAlign.center,
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                height: 1.0,
              ),
        ),
      ),
    );
  }
}

/* -------- Square + button -------- */
class _SquareIconButton extends StatelessWidget {
  const _SquareIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    required this.color,
    this.shortcutLabel,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final Color color;
  final String? shortcutLabel;

  @override
  Widget build(BuildContext context) {
    final button = ShadTooltip(
      builder: (context) => Text(tooltip),
      child: ShadIconButton(
        backgroundColor: color,
        hoverBackgroundColor: color,
        foregroundColor: Colors.white,
        icon: Icon(icon),
        width: 36,
        height: 36,
        onPressed: onTap,
        decoration: ShadDecoration(
          border: ShadBorder(
            radius: BorderRadius.circular(_pagesBarInnerButtonRadius),
          ),
        ),
      ),
    );

    if (shortcutLabel == null || shortcutLabel!.isEmpty) {
      return button;
    }

    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: button),
          Positioned(
            right: 6,
            bottom: 5,
            child: Text(
              shortcutLabel!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 7,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.9),
                    height: 1.0,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
