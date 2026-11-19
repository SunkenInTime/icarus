import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/text_widget_height_provider.dart';
import 'package:icarus/widgets/canvas_draggable.dart';
import 'package:icarus/widgets/context_menu_region.dart';
import 'package:icarus/widgets/draggable_widgets/adjacent_page_copy_menu.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';
import 'package:icarus/widgets/draggable_widgets/canonical_positioned.dart';
import 'package:icarus/widgets/draggable_widgets/tag_color_menu.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_links.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_scale_controller.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

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
  static const _tagGreen = Color(0xFF22C55E);
  static const _tagBlue = Color(0xFF3B82F6);
  static const _tagAmber = Color(0xFFF59E0B);
  static const _tagRed = Color(0xFFEF4444);
  static const _tagPurple = Color(0xFFA855F7);
  final _boxKey = GlobalKey();
  double? localSize; // Make localScale nullable to check if it's initialized
  bool isPanning = false;
  bool isDragging = false;
  Offset? pinnedScreenPosition;

  /// How far a mid-resize side switch moved the box away from the held
  /// pointer, so the width keeps following the pointer's movement.
  double pointerShift = 0;
  @override
  void initState() {
    localSize ??= widget.size;
    super.initState();
  }

  /// A side switch mid-resize moves the pin to where the box now shows,
  /// so the position stored on release is read on the side it was pinned on.
  /// The box leaves the held pointer behind, so later drag updates measure
  /// from where the left edge was.
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
    final nextPinned = coordinateSystem.screenPositionForSide(
      attackScreenPosition: coordinateSystem.screenPositionFromSide(
        sideScreenPosition: pinned,
        reflectionOffset: boxSize,
        isAttack: oldWidget.isAttack,
      ),
      reflectionOffset: boxSize,
      isAttack: widget.isAttack,
    );
    pointerShift += nextPinned.dx - pinned.dx;
    pinnedScreenPosition = nextPinned;
  }

  /// Stores the new width at once, so a page save right after release keeps
  /// it, with the position that keeps the box's top-left where the resize
  /// pinned it. On defense the box hangs from its bottom-right corner, so
  /// that position moves with the size.
  ///
  /// The text's height, and so its defense position, follows from its width,
  /// and the last drag update may not be laid out yet. So the pin holds for
  /// one more frame, then the position is stored again if it moved, unless a
  /// page switch loaded another page's copy of the text, which keeps its id.
  Future<void> _finishResize() async {
    final resizedText = widget.placedText;
    final pinned = pinnedScreenPosition;
    if (pinned != null) _storeResize(resizedText, pinned);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final stillLoaded = ref
        .read(textProvider)
        .any((text) => identical(text, resizedText));
    if (pinned != null && stillLoaded) _storeResize(resizedText, pinned);
    setState(() {
      isPanning = false;
      isDragging = false;
      pinnedScreenPosition = null;
      pointerShift = 0;
    });
  }

  /// Writes [text]'s new width and the position that puts its top-left at
  /// [pinned] as laid out now, unless both are already stored.
  void _storeResize(PlacedText text, Offset pinned) {
    final renderBox = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final coordinateSystem = CoordinateSystem.instance;
    final position = coordinateSystem.screenToCoordinate(
      coordinateSystem.screenPositionFromSide(
        sideScreenPosition: pinned,
        reflectionOffset: renderBox.size.bottomRight(Offset.zero),
        isAttack: widget.isAttack,
      ),
    );
    if (text.size == localSize && text.position == position) return;
    ref
        .read(textProvider.notifier)
        .resize(text.id, size: localSize!, position: position);
    ref.read(strategyProvider.notifier).setUnsaved();
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
    final attackScreenPosition = coordinateSystem.coordinateToScreen(
      widget.placedText.position,
    );
    final drawnSize =
        ref.watch(
          textWidgetHeightProvider.select(
            (sizes) => sizes[widget.placedText.id],
          ),
        ) ??
        Offset.zero;
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
          final widthInContentSpace =
              widthInScreenPixels / scale + pointerShift;
          final widthInWorldSpace = coordinateSystem.screenWidthToWorld(
            widthInContentSpace,
          );

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
        child: CanvasDraggable<PlacedText>(
          dot:
              widget.placedText.position +
              coordinateSystem
                  .screenSizeToWorld(Size(drawnSize.dx, drawnSize.dy))
                  .center(Offset.zero),
          maxSimultaneousDrags: itemDragLimit(context),
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
          dragAnchorStrategy: ref
              .read(screenZoomProvider.notifier)
              .zoomDragAnchorStrategy,
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
          child: EditorItemOutline(
            child: ContextMenuRegion(
              items: [
                ..._buildLinkItems(draftText ?? widget.placedText.text),
                ..._buildTagColorItems(),
              ],
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
      ),
    );
  }

  /// Open, for each link in [text]: the way to a link for someone editing on
  /// a touch screen, and where the click that opens one is written down. One
  /// link reads "Open link"; several are told apart by their addresses.
  List<ShadContextMenuItem> _buildLinkItems(String text) {
    final muted = ShadTheme.of(context).colorScheme.mutedForeground;
    final links = textLinks(text).toList();
    return [
      for (final link in links)
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.externalLink, size: 16),
          trailing: Text(
            openLinkShortcut,
            style: TextStyle(color: muted, fontSize: 12),
          ),
          onPressed: () => openTextLink(link),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              links.length == 1
                  ? context.l10n.canvasItemOpenTheLink
                  : context.l10n.canvasItemOpenLink(_shortAddress(link)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
    ];
  }

  /// [link] without the parts every address has, so the part that tells
  /// links apart fits in a menu.
  static String _shortAddress(Uri link) {
    final address = link.toString().replaceFirst(RegExp(r'^https?://'), '');
    return address.startsWith('www.') ? address.substring(4) : address;
  }

  List<ShadContextMenuItem> _buildTagColorItems() {
    final l10n = context.l10n;
    return [
      buildTagColorMenuItem(
        context,
        current: widget.placedText.tagColorValue,
        choices: [
          (color: _tagGreen, label: l10n.shapeToolsColorGreen),
          (color: _tagBlue, label: l10n.shapeToolsColorBlue),
          (color: _tagAmber, label: l10n.canvasItemTagColorAmber),
          (color: _tagRed, label: l10n.shapeToolsColorRed),
          (color: _tagPurple, label: l10n.canvasItemTagColorPurple),
        ],
        onPicked: (colorValue) {
          ref
              .read(textProvider.notifier)
              .updateTagColor(widget.placedText.id, colorValue);
          ref.read(strategyProvider.notifier).setUnsaved();
        },
      ),
      ...buildCaptionMenuItems(context, ref, widget.placedText.id),
      ...buildAdjacentPageCopyMenuItems(ref, widget.placedText.id),
    ];
  }
}
