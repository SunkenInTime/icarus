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
  });

  final Offset attackScreenPosition;
  final bool isAttack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _CanonicalBoxPositionDelegate(
          attackScreenPosition: attackScreenPosition,
          isAttack: isAttack,
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
  });

  final Offset attackScreenPosition;
  final bool isAttack;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    if (isAttack) return attackScreenPosition;
    return Offset(
      size.width - attackScreenPosition.dx - childSize.width,
      size.height - attackScreenPosition.dy - childSize.height,
    );
  }

  @override
  bool shouldRelayout(covariant _CanonicalBoxPositionDelegate oldDelegate) {
    return attackScreenPosition != oldDelegate.attackScreenPosition ||
        isAttack != oldDelegate.isAttack;
  }
}
