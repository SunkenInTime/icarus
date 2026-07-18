import 'package:flutter/widgets.dart';

class CustomBorderContainer extends StatelessWidget {
  const CustomBorderContainer({
    super.key,
    required this.color,
    required this.width,
    required this.height,
    required this.hasTop,
    required this.hasSide,
    required this.isTransparent,
  });

  final Color color;
  final double width;
  final double height;
  final bool hasTop;
  final bool hasSide;
  final bool isTransparent;
  @override
  Widget build(BuildContext context) {
    const double borderRadiusValue = 10.0;
    const double borderThickness = 2.0;
    final borderRadius = hasTop 
        ? const BorderRadius.only(
            topLeft: Radius.circular(borderRadiusValue),
            topRight: Radius.circular(borderRadiusValue),
          )
        : BorderRadius.zero;

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: color.withAlpha(isTransparent ? 0 : 100),
                borderRadius: borderRadius,
              ),
            ),
          ),

          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: borderRadius, 
                  border: Border(
                    top: hasTop
                        ? BorderSide(color: color, width: borderThickness + 1.0)
                        : BorderSide.none,
                    left: hasSide
                        ? BorderSide(color: color, width: borderThickness)
                        : BorderSide.none,
                    right: hasSide
                        ? BorderSide(color: color, width: borderThickness)
                        : BorderSide.none,
                    bottom: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
