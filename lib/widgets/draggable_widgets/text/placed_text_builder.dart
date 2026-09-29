import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/widgets/draggable_widgets/adjacent_page_copy_menu.dart';
import 'package:icarus/widgets/draggable_widgets/canonical_positioned.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_scale_controller.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class PlacedTextBuilder extends ConsumerStatefulWidget {
  const PlacedTextBuilder({
    super.key,
    required this.size,
    required this.placedText,
    required this.isAttack,
    required this.onDragEnd,
  });
  final double size;
  final PlacedText placedText;
  final bool isAttack;
  final Function(DraggableDetails details) onDragEnd;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _PlacedTextBuilderState();
}

class _PlacedTextBuilderState extends ConsumerState<PlacedTextBuilder> {
  static const double minSize = 60;
  static const List<Color> _tagPalette = [
    Color(0xFF22C55E),
    Color(0xFF3B82F6),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFFA855F7),
  ];
  final _boxKey = GlobalKey();
  double? localSize; // Make localScale nullable to check if it's initialized
  bool isPanning = false;
  bool isDragging = false;
  Offset? pinnedScreenPosition;
  @override
  void initState() {
    localSize ??= widget.size;
    super.initState();
  }

  /// A side switch mid-resize moves the pin to where the box now shows,
  /// so the position stored on release is read on the side it was pinned on.
  @override
  void didUpdateWidget(covariant PlacedTextBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pinned = pinnedScreenPosition;
    final renderBox = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (pinned == null ||
        renderBox == null ||
        oldWidget.isAttack == widget.isAttack) {
      return;
    }
    final coordinateSystem = CoordinateSystem.instance;
    final boxSize = renderBox.size.bottomRight(Offset.zero);
    pinnedScreenPosition = coordinateSystem.screenPositionForSide(
      attackScreenPosition: coordinateSystem.screenPositionFromSide(
        sideScreenPosition: pinned,
        reflectionOffset: boxSize,
        isAttack: oldWidget.isAttack,
      ),
      reflectionOffset: boxSize,
      isAttack: widget.isAttack,
    );
  }

  /// Stores the new width, and the position that keeps the box's top-left
  /// where the resize pinned it. On defense the box hangs from its
  /// bottom-right corner, so that position moves with the size.
  ///
  /// Waits for the frame that lays out the last drag update, because the
  /// text's height, and so its defense position, follows from its width.
  Future<void> _finishResize() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final pinned = pinnedScreenPosition;
    final renderBox = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (pinned != null && renderBox != null) {
      final coordinateSystem = CoordinateSystem.instance;
      final position = coordinateSystem.screenToCoordinate(
        coordinateSystem.screenPositionFromSide(
          sideScreenPosition: pinned,
          reflectionOffset: renderBox.size.bottomRight(Offset.zero),
          isAttack: widget.isAttack,
        ),
      );
      ref
          .read(textProvider.notifier)
          .resize(widget.placedText.id, size: localSize!, position: position);
      ref.read(strategyProvider.notifier).setUnsaved();
    }
    setState(() {
      isPanning = false;
      isDragging = false;
      pinnedScreenPosition = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final texts = ref.watch(textProvider);
    final index = PlacedWidget.getIndexByID(widget.placedText.id, texts);
    final draftText = ref.watch(
      textDraftProvider.select((drafts) => drafts[widget.placedText.id]),
    );
    if (localSize == null) {
      return const SizedBox.shrink();
    }

    if (index < 0) {
      return const SizedBox.shrink();
    }

    if (texts[index].size != localSize && !isPanning) {
      localSize = texts[index].size;
    }
    final coordinateSystem = CoordinateSystem.instance;
    final attackScreenPosition =
        coordinateSystem.coordinateToScreen(widget.placedText.position);
    return CanonicalPositionedBox(
      attackScreenPosition: attackScreenPosition,
      isAttack: widget.isAttack,
      pinnedScreenPosition: pinnedScreenPosition,
      child: TextScaleController(
        key: _boxKey,
        isDragging: isDragging,
        onPanUpdate: (details) {
          final renderBox =
              _boxKey.currentContext?.findRenderObject() as RenderBox?;
          if (renderBox == null) return;

          final leftEdgeGlobal = renderBox.localToGlobal(Offset.zero);
          final scale = ref.read(screenZoomProvider);
          final widthInScreenPixels =
              details.globalPosition.dx - leftEdgeGlobal.dx;
          final widthInContentSpace = widthInScreenPixels / scale;
          final widthInWorldSpace =
              coordinateSystem.screenWidthToWorld(widthInContentSpace);

          setState(() {
            isPanning = true;
            pinnedScreenPosition ??= coordinateSystem.screenPositionForSide(
              attackScreenPosition: attackScreenPosition,
              reflectionOffset: renderBox.size.bottomRight(Offset.zero),
              isAttack: widget.isAttack,
            );
            localSize = widthInWorldSpace.clamp(minSize, double.infinity);
          });
        },
        onPanEnd: (_) => _finishResize(),
        child: Draggable<PlacedText>(
          data: widget.placedText,
          feedback: Opacity(
            opacity: 0.8,
            child: ZoomTransform(
              child: TextWidget(
                id: widget.placedText.id,
                text: draftText ?? widget.placedText.text,
                size: localSize!,
                fontSize: widget.placedText.fontSize,
                tagColorValue: widget.placedText.tagColorValue,
                isFeedback: true,
              ),
            ),
          ),
          childWhenDragging: const SizedBox.shrink(),
          dragAnchorStrategy:
              ref.read(screenZoomProvider.notifier).zoomDragAnchorStrategy,
          onDragStarted: () {
            ref
                .read(textDraftProvider.notifier)
                .commitDraft(widget.placedText.id);
            setState(() {
              isDragging = true;
            });
          },
          onDragEnd: (details) {
            widget.onDragEnd(details);
            setState(() {
              isDragging = false;
            });
          },
          child: ShadContextMenuRegion(
            items: _buildTagColorItems(),
            child: MouseWatch(
              cursor: SystemMouseCursors.click,
              deleteTarget: HoveredDeleteTarget.text(
                id: widget.placedText.id,
                ownerToken: Object(),
              ),
              child: TextWidget(
                id: widget.placedText.id,
                text: widget.placedText.text,
                size: localSize!,
                fontSize: widget.placedText.fontSize,
                tagColorValue: widget.placedText.tagColorValue,
                isFeedback: false,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<ShadContextMenuItem> _buildTagColorItems() {
    return [
      ShadContextMenuItem(
        child: const Text('Reset tag to gray'),
        onPressed: () {
          ref
              .read(textProvider.notifier)
              .updateTagColor(widget.placedText.id, null);
          ref.read(strategyProvider.notifier).setUnsaved();
        },
      ),
      ..._tagPalette.map(
        (color) => ShadContextMenuItem(
          leading: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          child: Text(_labelForColor(color)),
          onPressed: () {
            ref
                .read(textProvider.notifier)
                .updateTagColor(widget.placedText.id, color.toARGB32());
            ref.read(strategyProvider.notifier).setUnsaved();
          },
        ),
      ),
      ...buildAdjacentPageCopyMenuItems(ref, widget.placedText.id),
    ];
  }

  String _labelForColor(Color color) {
    if (color.toARGB32() == const Color(0xFF22C55E).toARGB32()) {
      return 'Green tag';
    }
    if (color.toARGB32() == const Color(0xFF3B82F6).toARGB32()) {
      return 'Blue tag';
    }
    if (color.toARGB32() == const Color(0xFFF59E0B).toARGB32()) {
      return 'Amber tag';
    }
    if (color.toARGB32() == const Color(0xFFEF4444).toARGB32()) {
      return 'Red tag';
    }
    return 'Purple tag';
  }
}
