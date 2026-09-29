import 'package:flutter/material.dart';

/// Positions an upright box from attack-canonical coordinates.
///
/// The defense projection needs the child's laid-out size, so a normal
/// [Positioned] cannot do this without a separate measurement pass. This
/// delegate keeps text and images exact even while their dimensions change.
class CanonicalPositionedBox extends StatelessWidget {
  const CanonicalPositionedBox({
    super.key,
    required this.attackScreenPosition,
    required this.isAttack,
    required this.child,
    this.pinnedScreenPosition,
  });

  final Offset attackScreenPosition;
  final bool isAttack;
  final Widget child;

  /// While set, the box keeps this on-screen top-left whatever its size.
  ///
  /// On defense the box mirrors attack, so it hangs from its bottom-right
  /// corner and growing it would move its top and left edges. A resize pins
  /// the top-left here so only the dragged edge moves.
  final Offset? pinnedScreenPosition;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _CanonicalBoxPositionDelegate(
          attackScreenPosition: attackScreenPosition,
          isAttack: isAttack,
          pinnedScreenPosition: pinnedScreenPosition,
        ),
        child: child,
      ),
    );
  }
}

class _CanonicalBoxPositionDelegate extends SingleChildLayoutDelegate {
  const _CanonicalBoxPositionDelegate({
    required this.attackScreenPosition,
    required this.isAttack,
    required this.pinnedScreenPosition,
  });

  final Offset attackScreenPosition;
  final bool isAttack;
  final Offset? pinnedScreenPosition;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    if (pinnedScreenPosition case final pinned?) return pinned;
    if (isAttack) return attackScreenPosition;
    return Offset(
      size.width - attackScreenPosition.dx - childSize.width,
      size.height - attackScreenPosition.dy - childSize.height,
    );
  }

  @override
  bool shouldRelayout(covariant _CanonicalBoxPositionDelegate oldDelegate) {
    return attackScreenPosition != oldDelegate.attackScreenPosition ||
        isAttack != oldDelegate.isAttack ||
        pinnedScreenPosition != oldDelegate.pinnedScreenPosition;
  }
}
