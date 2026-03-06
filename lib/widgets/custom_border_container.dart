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
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: color.withAlpha(isTransparent ? 0 : 100),
            ),
          ),

          if (hasTop)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SizedBox(
                height: 3,
                child: ColoredBox(
                  color: color,
                ),
              ),
            ),

          // Left border
          if (hasSide)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 2,
              child: ColoredBox(
                color: color,
              ),
            ),
          // Right border
          if (hasSide)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 2,
              child: ColoredBox(
                color: color,
              ),
            ),
        ],
      ),
    );
  }
}

