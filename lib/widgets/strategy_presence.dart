import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/strategy_presence_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/widgets/account_avatar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The same hue for a person on every screen. String.hashCode differs between
/// web and native, so hash by hand, keeping every step small enough to be
/// exact in JavaScript numbers.
Color presenceColorFor(String uid) {
  var hash = 0;
  for (final unit in uid.codeUnits) {
    hash = (hash * 31 + unit) % 1000003;
  }
  return Settings.presenceColors[hash % Settings.presenceColors.length];
}

/// Everyone else with this strategy open, as a row of avatars in the window
/// strip. Shows nothing when you are alone or the strategy is local.
class StrategyPresenceAvatars extends ConsumerWidget {
  const StrategyPresenceAvatars({super.key});

  static const int _maxShown = 4;
  static const double _size = 24;
  static const double _overlap = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Cursors move many times a second; only rebuild when the people change.
    ref.watch(strategyPresenceProvider.select(_peopleSignature));
    final people = ref.read(strategyPresenceProvider).people;
    if (people.isEmpty) return const SizedBox.shrink();

    final shown = people.take(_maxShown).toList();
    final hidden = people.skip(_maxShown).toList();
    final slots = shown.length + (hidden.isEmpty ? 0 : 1);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Center(
        child: SizedBox(
          key: const ValueKey('strategy-presence-avatars'),
          height: _size,
          width: _size + (slots - 1) * (_size - _overlap),
          child: Stack(
            children: [
              for (final (index, peer) in shown.indexed)
                Positioned(
                  left: index * (_size - _overlap),
                  child: _PresenceAvatar(peer: peer, size: _size),
                ),
              if (hidden.isNotEmpty)
                Positioned(
                  left: shown.length * (_size - _overlap),
                  child: _OverflowAvatar(people: hidden, size: _size),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _peopleSignature(PresenceRoomState state) => [
        for (final peer in state.people)
          '${peer.uid}\u0000${peer.name}\u0000${peer.avatarUrl}\u0000${peer.role}',
      ].join('\u0001');
}

const _belowStrip = ShadAnchor(
  offset: Offset(0, 6),
  childAlignment: Alignment.topCenter,
  overlayAlignment: Alignment.bottomCenter,
);

String _describe(PresencePeer peer) =>
    peer.role == 'viewer' ? '${peer.name} (viewing)' : peer.name;

class _PresenceAvatar extends StatelessWidget {
  const _PresenceAvatar({required this.peer, required this.size});

  final PresencePeer peer;
  final double size;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final initial = peer.name.isEmpty ? '?' : peer.name.characters.first;
    return ShadTooltip(
      builder: (context) => Text(_describe(peer)),
      // The strip is the top of the window; there is no room above it.
      anchor: _belowStrip,
      child: _Ring(
        color: presenceColorFor(peer.uid),
        size: size,
        child: AccountAvatar(
          radius: size / 2 - 3,
          backgroundColor: theme.secondary,
          avatarUrl: peer.avatarUrl,
          fallback: Text(
            initial.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: theme.foreground,
            ),
          ),
        ),
      ),
    );
  }
}

class _OverflowAvatar extends StatelessWidget {
  const _OverflowAvatar({required this.people, required this.size});

  final List<PresencePeer> people;
  final double size;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return ShadTooltip(
      builder: (context) => Text(people.map(_describe).join('\n')),
      anchor: _belowStrip,
      child: _Ring(
        color: theme.border,
        size: size,
        child: CircleAvatar(
          radius: size / 2 - 3,
          backgroundColor: theme.secondary,
          child: Text(
            '+${people.length}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: theme.foreground,
            ),
          ),
        ),
      ),
    );
  }
}

/// A person's color as a thin ring, with a gap in the strip's color so
/// overlapping avatars stay distinct.
class _Ring extends StatelessWidget {
  const _Ring({required this.color, required this.size, required this.child});

  final Color color;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Rings sit inside a ShadTooltip, which only opens for children that
    // report hover through the Shad theme; a plain Container doesn't.
    return ShadGestureDetector(
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        child: Container(
          padding: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Settings.tacticalVioletTheme.card,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Reports this user's pointer over the map to the presence room, in
/// attack-side world coordinates so it lands in the same spot for everyone.
///
/// Sits over the map viewport with no child and a translucent hit test, so it
/// sees every hover and drag while everything under it still gets them. The
/// map can also move under a still pointer (scroll zoom, a page or side
/// change, a resize), so it reports again from the last pointer position
/// whenever any of those change.
class PresenceCursorReporter extends ConsumerStatefulWidget {
  const PresenceCursorReporter({
    super.key,
    required this.transformationController,
    required this.coordinateSystem,
    required this.isAttack,
  });

  final TransformationController transformationController;
  final CoordinateSystem coordinateSystem;
  final bool isAttack;

  @override
  ConsumerState<PresenceCursorReporter> createState() =>
      _PresenceCursorReporterState();
}

class _PresenceCursorReporterState
    extends ConsumerState<PresenceCursorReporter> {
  /// Where the pointer is in the viewport, while it is over the map.
  Offset? _pointer;

  @override
  void initState() {
    super.initState();
    widget.transformationController.addListener(_reportAgain);
  }

  @override
  void didUpdateWidget(PresenceCursorReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transformationController != widget.transformationController) {
      oldWidget.transformationController.removeListener(_reportAgain);
      widget.transformationController.addListener(_reportAgain);
    }
    if (oldWidget.isAttack != widget.isAttack ||
        oldWidget.coordinateSystem.effectiveSize !=
            widget.coordinateSystem.effectiveSize) {
      _reportAgain();
    }
  }

  @override
  void dispose() {
    widget.transformationController.removeListener(_reportAgain);
    super.dispose();
  }

  bool _reportScheduled = false;

  /// Reports again once the frame settles. A wheel zoom sets the transform
  /// in steps (scale, then the pan that keeps the pointer's spot fixed), and
  /// reporting between them would fling the cursor across teammates' maps.
  void _reportAgain() {
    if (_pointer == null || _reportScheduled) return;
    _reportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportScheduled = false;
      final pointer = _pointer;
      if (mounted && pointer != null) _report(pointer);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _report(Offset viewportPosition) {
    _pointer = viewportPosition;
    final world = widget.transformationController.toScene(viewportPosition);
    final coordinateSystem = widget.coordinateSystem;
    final canonical = coordinateSystem.positionFromSide(
      sidePosition: coordinateSystem.screenToCoordinate(world),
      reflectionOffset: Offset.zero,
      isAttack: widget.isAttack,
    );
    ref
        .read(strategyPresenceProvider.notifier)
        .moveCursor(canonical.dx, canonical.dy);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      strategyPageSessionProvider.select((s) => s.activePageId),
      (_, __) => _reportAgain(),
    );
    return MouseRegion(
      opaque: false,
      hitTestBehavior: HitTestBehavior.translucent,
      onExit: (_) {
        _pointer = null;
        ref.read(strategyPresenceProvider.notifier).hideCursor();
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: (event) => _report(event.localPosition),
        onPointerMove: (event) => _report(event.localPosition),
      ),
    );
  }
}

/// Other people's cursors on the page being viewed. Lives inside the zoomed
/// world, so it pans with the map; each cursor counter-scales to stay the
/// same size on screen.
class RemoteCursorsLayer extends ConsumerWidget {
  const RemoteCursorsLayer({
    super.key,
    required this.coordinateSystem,
    required this.isAttack,
  });

  final CoordinateSystem coordinateSystem;
  final bool isAttack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pageId = ref.watch(
      strategyPageSessionProvider.select((s) => s.activePageId),
    );
    if (pageId == null) return const SizedBox.shrink();
    final peers = ref.watch(
      strategyPresenceProvider.select((s) => s.cursorsOn(pageId)),
    );
    if (peers.isEmpty) return const SizedBox.shrink();
    final zoom = ref.watch(screenZoomProvider);

    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final peer in peers) _positioned(peer, zoom),
        ],
      ),
    );
  }

  Widget _positioned(PresencePeer peer, double zoom) {
    final cursor = peer.cursor!;
    final screen = coordinateSystem.coordinateToScreen(
      coordinateSystem.positionForSide(
        canonicalPosition: Offset(cursor.x, cursor.y),
        reflectionOffset: Offset.zero,
        isAttack: isAttack,
      ),
    );
    // Near the right or bottom of the world the name tag would run off the
    // map, so it flips to the other side of the arrow.
    final world = coordinateSystem.effectiveSize;
    final tagOnLeft = world.width - screen.dx < RemoteCursor.maxTagWidth / zoom;
    final tagAbove = world.height - screen.dy < 48 / zoom;
    // Updates arrive about 20 times a second; gliding between them reads as
    // continuous motion instead of hops.
    return AnimatedPositioned(
      key: ValueKey(peer.sid),
      duration: const Duration(milliseconds: 90),
      curve: Curves.linear,
      left: screen.dx,
      top: screen.dy,
      child: Transform.scale(
        scale: 1 / zoom,
        alignment: Alignment.topLeft,
        child: RemoteCursor(
          name: peer.name,
          color: presenceColorFor(peer.uid),
          tagOnLeft: tagOnLeft,
          tagAbove: tagAbove,
        ),
      ),
    );
  }
}

/// An arrow with the person's name beside it. The arrow's tip is the
/// widget's top-left corner.
class RemoteCursor extends StatelessWidget {
  const RemoteCursor({
    super.key,
    required this.name,
    required this.color,
    this.tagOnLeft = false,
    this.tagAbove = false,
  });

  static const Size arrowSize = Size(14, 18);
  static const double maxTagWidth = 160;

  final String name;
  final Color color;
  final bool tagOnLeft;
  final bool tagAbove;

  @override
  Widget build(BuildContext context) {
    final tag = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxTagWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [Settings.cardForegroundBackdrop],
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Settings.presenceTagInk,
            height: 1.2,
          ),
        ),
      ),
    );
    return SizedBox.fromSize(
      size: arrowSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CustomPaint(size: arrowSize, painter: _ArrowPainter(color)),
          Positioned(
            left: tagOnLeft ? null : 10,
            right: tagOnLeft ? arrowSize.width + 2 : null,
            top: tagAbove ? null : 14,
            bottom: tagAbove ? arrowSize.height + 2 : null,
            child: tag,
          ),
        ],
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, h * 0.86)
      ..lineTo(w * 0.3, h * 0.62)
      ..lineTo(w * 0.52, h)
      ..lineTo(w * 0.68, h * 0.93)
      ..lineTo(w * 0.47, h * 0.56)
      ..lineTo(w, h * 0.56)
      ..close();
    canvas.drawPath(
      path.shift(const Offset(0, 1)),
      Paint()
        ..color = Settings.cardForegroundBackdrop.color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = Settings.presenceTagInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) => oldDelegate.color != color;
}
