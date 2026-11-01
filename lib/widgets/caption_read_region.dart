import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/widgets/caption_markers.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

/// How a reader who can't touch placed items reaches their captions: by
/// pointing at them, or tapping on a touch screen. It sits under the lineups,
/// which keep their hover and taps, and takes nothing from anything below.
class CaptionReadRegion extends ConsumerStatefulWidget {
  const CaptionReadRegion({super.key});

  @override
  ConsumerState<CaptionReadRegion> createState() => _CaptionReadRegionState();
}

class _CaptionReadRegionState extends ConsumerState<CaptionReadRegion> {
  /// A finger needs more room than the small items here have.
  static const _touchTarget = 44.0;

  String? _hovered;
  Offset? _pressedAt;

  CaptionCardNotifier get _card => ref.read(captionCardProvider.notifier);

  /// The topmost captioned item at [position], reaching [target] across.
  String? _itemAt(Offset position, {double target = 0}) {
    final stack = context.findAncestorRenderObjectOfType<RenderStack>();
    final registry = CanvasItemRegistryScope.maybeOf(context);
    if (stack == null || registry == null) return null;
    final captioned = ref.read(captionedItemsProvider).all;
    String? found;
    for (final (:item, :corners) in registry.itemsIn(stack)) {
      if (!captioned.contains(item.id)) continue;
      var bounds = Rect.fromPoints(corners.first, corners.first);
      for (final corner in corners) {
        bounds = bounds.expandToInclude(Rect.fromPoints(corner, corner));
      }
      final reach = Rect.fromCenter(
        center: bounds.center,
        width: bounds.width < target ? target : bounds.width,
        height: bounds.height < target ? target : bounds.height,
      );
      if (reach.contains(position)) found = item.id;
    }
    return found;
  }

  void _setHovered(String? id) {
    if (id == _hovered) return;
    if (_hovered case final left?) _card.itemExited(left);
    _hovered = id;
    if (id != null) _card.itemEntered(id);
  }

  @override
  void dispose() {
    final left = _hovered;
    if (left != null) _card.itemExited(left);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(captionedItemsProvider);
    return MouseRegion(
      opaque: false,
      hitTestBehavior: HitTestBehavior.translucent,
      onHover: (event) => _setHovered(_itemAt(event.localPosition)),
      onExit: (_) => _setHovered(null),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) => _pressedAt =
            event.kind == PointerDeviceKind.touch ? event.localPosition : null,
        onPointerUp: (event) {
          final pressedAt = _pressedAt;
          _pressedAt = null;
          if (pressedAt == null ||
              (event.localPosition - pressedAt).distance > kTouchSlop) {
            return;
          }
          final id = _itemAt(pressedAt, target: _touchTarget);
          if (id != null) _card.openNow(id);
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}
