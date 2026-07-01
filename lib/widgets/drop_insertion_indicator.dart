import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';

enum DropInsertionSide {
  before,
  after,
}

class DropInsertionIndicator extends StatelessWidget {
  const DropInsertionIndicator({
    super.key,
    required this.side,
    required this.height,
    this.horizontalOutset = 6,
  });

  final DropInsertionSide side;
  final double height;
  final double horizontalOutset;

  @override
  Widget build(BuildContext context) {
    final alignment = side == DropInsertionSide.before
        ? Alignment.centerLeft
        : Alignment.centerRight;
    final offset = side == DropInsertionSide.before
        ? Offset(-horizontalOutset, 0)
        : Offset(horizontalOutset, 0);
    final indicatorColor = Settings.tacticalVioletTheme.primary;

    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: Transform.translate(
          offset: offset,
          child: SizedBox(
            width: 7,
            height: height,
            child: Center(
              child: Container(
                width: 2,
                height: height,
                decoration: BoxDecoration(
                  color: indicatorColor.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
