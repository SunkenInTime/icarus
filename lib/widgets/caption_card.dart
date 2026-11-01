import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/caption_links.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/caption_markers.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';
import 'package:url_launcher/url_launcher.dart';

/// The name a caption card shows for [item].
String captionItemName(PlacedWidget item) => switch (item) {
      PlacedAgentNode() => AgentData.agents[item.type]?.name ?? 'Agent',
      PlacedAbility() => item.data.name,
      PlacedText() => 'Text',
      PlacedImage() => 'Image',
      PlacedUtility() when item.type == UtilityType.spike => 'Spike',
      PlacedUtility() when UtilityData.isViewCone(item.type) => 'Vision cone',
      _ => 'Shape',
    };

/// The caption card of the item that's open, above that item, or below it
/// when above is covered. It sits outside the canvas, so presses and the wheel
/// stay on it, and it keeps its size at every zoom.
class CaptionCardLayer extends ConsumerStatefulWidget {
  const CaptionCardLayer({required this.transformation, super.key});

  /// The canvas's zoom and pan: moving it closes the card.
  final TransformationController transformation;

  @override
  ConsumerState<CaptionCardLayer> createState() => _CaptionCardLayerState();
}

class _CaptionCardLayerState extends ConsumerState<CaptionCardLayer>
    with WidgetsBindingObserver {
  final _card = GlobalKey();
  _Placement? _placement;

  CaptionCardNotifier get _notifier => ref.read(captionCardProvider.notifier);

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
    widget.transformation.addListener(_notifierClose);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    widget.transformation.removeListener(_notifierClose);
    super.dispose();
  }

  void _notifierClose() => _notifier.closeNow();

  bool _onCard(Offset position) {
    final box = _card.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return (Offset.zero & box.size).contains(box.globalToLocal(position));
  }

  void _onPointer(PointerEvent event) {
    if ((event is PointerDownEvent || event is PointerSignalEvent) &&
        !_onCard(event.position)) {
      _notifier.closeNow();
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        ref.read(captionCardProvider) != null) {
      _notifier.closeNow();
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _notifier.closeNow();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(captionCardProvider, (_, __) => _placement = null);
    ref.listen(interactionStateProvider, (_, __) => _notifier.closeNow());
    ref.listen(
      strategyPageSessionProvider.select((session) => session.activePageId),
      (_, __) => _notifier.closeNow(),
    );
    ref.listen(hoveredLineUpTargetProvider, (_, target) {
      if (target != null) _notifier.closeNow();
    });
    ref.listen(
      appPreferencesProvider.select((preferences) => preferences.showCaptions),
      (_, visible) {
        if (!visible) _notifier.closeNow();
      },
    );

    final id = ref.watch(captionCardProvider);
    // Keeps the card on its item, and its text current, when a teammate moves
    // or changes it.
    ref.watch(agentProvider);
    ref.watch(abilityProvider);
    ref.watch(textProvider);
    ref.watch(placedImageProvider);
    ref.watch(utilityProvider);
    if (id == null) return const SizedBox.shrink();

    final container = ProviderScope.containerOf(context, listen: false);
    final item = placedItemById(container, id);
    final caption = item?.caption;
    final registry = ref.read(canvasItemRegistryProvider);
    final stack = context.findAncestorRenderObjectOfType<RenderStack>();
    Rect? outline;
    final obstacles = <Rect>[];
    if (stack != null) {
      for (final (item: outlined, :corners) in registry.itemsIn(stack)) {
        if (outlined.id != id) continue;
        outline = _bounds(corners);
        break;
      }
      obstacles.addAll(registry.chromeIn(stack));
      if (registry.handleIn(stack, id) case final handle?) {
        obstacles.add(handle);
      }
    }
    if (item == null || caption == null || caption.isEmpty || outline == null) {
      // The item went while the card was open, a teammate cleared its note, or
      // the page moved on.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => mounted ? _notifier.closeNow() : null);
      return const SizedBox.shrink();
    }

    final placement = _placement ??= _Placement();
    return CustomSingleChildLayout(
      delegate: _CaptionCardLayout(
        item: outline,
        obstacles: obstacles,
        placement: placement,
      ),
      child: MouseRegion(
        key: _card,
        onEnter: (_) => _notifier.cardEntered(),
        onExit: (_) => _notifier.cardExited(),
        child: ListenableBuilder(
          listenable: placement,
          builder: (context, _) => Padding(
            // Part of the card, so there's no gap to cross on the way to it.
            padding: placement.above
                ? const EdgeInsets.only(bottom: _CaptionCardLayout.gap)
                : const EdgeInsets.only(top: _CaptionCardLayout.gap),
            child: _CaptionCard(
              name: captionItemName(item),
              caption: caption,
            ),
          ),
        ),
      ),
    );
  }

  static Rect _bounds(List<Offset> corners) {
    var bounds = Rect.fromPoints(corners.first, corners.first);
    for (final corner in corners) {
      bounds = bounds.expandToInclude(Rect.fromPoints(corner, corner));
    }
    return bounds;
  }
}

/// The side a card opened on, fixed until it closes: a rotate handle hides a
/// moment after the pointer leaves the item, and the card must not jump away
/// from the pointer on its way over.
class _Placement extends ChangeNotifier {
  bool above = true;
  bool chosen = false;

  void choose(bool value) {
    chosen = true;
    if (value == above) return;
    above = value;
    WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }
}

class _CaptionCardLayout extends SingleChildLayoutDelegate {
  _CaptionCardLayout({
    required this.item,
    required this.obstacles,
    required this.placement,
  });

  static const gap = 8.0;

  /// A card sits this far clear of the top of its item, past the marker.
  static const _markerClearance = 10.0;
  static const width = 280.0;
  static const _margin = 8.0;

  final Rect item;
  final List<Rect> obstacles;
  final _Placement placement;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: width,
        minWidth: width,
        maxHeight: constraints.maxHeight - 2 * _margin,
      );

  bool _clear(Rect card, Size size, List<Rect> around) =>
      card.top >= _margin &&
      card.bottom <= size.height - _margin &&
      !around.any(card.overlaps);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final around = obstacles;
    final left = (item.center.dx - childSize.width / 2).clamp(
      _margin,
      size.width - childSize.width - _margin,
    );
    final aboveTop = item.top - _markerClearance - childSize.height;
    final belowTop = item.bottom;
    Rect at(double top) => Offset(left, top) & childSize;
    if (!placement.chosen) {
      final above = _clear(at(aboveTop), size, around) ||
          !_clear(at(belowTop), size, around) &&
              item.top >= size.height - item.bottom;
      placement.choose(above);
    }
    final top = placement.above ? aboveTop : belowTop;
    return Offset(
      left,
      top.clamp(_margin, size.height - childSize.height - _margin),
    );
  }

  @override
  bool shouldRelayout(_CaptionCardLayout oldDelegate) =>
      item != oldDelegate.item || placement != oldDelegate.placement;
}

class _CaptionCard extends StatefulWidget {
  const _CaptionCard({required this.name, required this.caption});

  final String name;
  final String caption;

  @override
  State<_CaptionCard> createState() => _CaptionCardState();
}

class _CaptionCardState extends State<_CaptionCard> {
  final _links = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }

  void _disposeLinks() {
    for (final link in _links) {
      link.dispose();
    }
    _links.clear();
  }

  List<InlineSpan> _spans() {
    _disposeLinks();
    return [
      for (final run in captionRuns(widget.caption))
        if (run.uri case final uri?)
          TextSpan(
            text: run.text,
            style: const TextStyle(
              color: Settings.accentInk,
              decoration: TextDecoration.underline,
              decorationColor: Settings.accentInk,
            ),
            mouseCursor: SystemMouseCursors.click,
            recognizer: (TapGestureRecognizer()
                  ..onTap = () => launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      ))
                .also(_links.add),
          )
        else
          TextSpan(text: run.text),
    ];
  }

  @override
  Widget build(BuildContext context) {
    const border = BorderSide(color: _edge, width: 2);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Settings.abilityBGColor,
        border: Border.fromBorderSide(border),
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x8A000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: _edge)),
              ),
              child: Row(
                children: [
                  const CustomPaint(
                    size: Size(12, 11),
                    painter: _CaptionGlyphPainter(),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Settings.tacticalVioletTheme.mutedForeground,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 16 / 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Text.rich(
                  TextSpan(children: _spans()),
                  style: TextStyle(
                    color: Settings.tacticalVioletTheme.foreground,
                    fontSize: 14,
                    height: 20 / 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _edge = Color(0xFF27272A);
}

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 15);
    canvas.drawPath(
      captionMarkerPath,
      Paint()..color = Settings.tacticalVioletTheme.mutedForeground,
    );
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter oldDelegate) => false;
}

extension<T> on T {
  T also(void Function(T value) use) {
    use(this);
    return this;
  }
}
