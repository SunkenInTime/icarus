import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';

class CustomCircleWidget extends StatefulWidget {
  const CustomCircleWidget({
    super.key,
    required this.abilityInfo,
    required this.size,
    required this.outlineColor,
    required this.hasCenterDot,
    required this.isDouble,
    this.opacity,
    this.innerSize,
    this.innerColor,
  });

  final AbilityInfo abilityInfo;
  final double size;
  final Color outlineColor;
  final bool hasCenterDot;
  final bool isDouble;

  final int? opacity;
  final double? innerSize;
  final Color? innerColor;

  @override
  State<CustomCircleWidget> createState() => _CustomCircleWidgetState();
}

class _CustomCircleWidgetState extends State<CustomCircleWidget> {
  @override
  Widget build(BuildContext context) {
    CoordinateSystem coordinateSystem = CoordinateSystem.instance;

    double scaleSize =
        coordinateSystem.scale(widget.size) - coordinateSystem.scale(5);
    log(widget.innerSize.toString());
    double secondaryScaleSize = coordinateSystem.scale(widget.innerSize ?? 2) -
        coordinateSystem.scale(2);
    log(secondaryScaleSize.toString());
    // abilityInfo.updateCenterPoint(Offset(scaleSize / 2, scaleSize / 2));
    if (widget.hasCenterDot) {
      return !widget.isDouble
          ? Stack(
              children: [
                IgnorePointer(
                  child: Container(
                    width: scaleSize,
                    height: scaleSize,
                    decoration: BoxDecoration(
                      color:
                          widget.outlineColor.withAlpha(widget.opacity ?? 70),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: widget.outlineColor,
                        width: coordinateSystem.scale(5),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.center,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                      child: Container(
                        width: coordinateSystem.scale(25),
                        height: coordinateSystem.scale(25),
                        padding: EdgeInsets.all(coordinateSystem.scale(3)),
                        decoration: const BoxDecoration(
                          color: Color(0xFF1B1B1B),
                        ),
                        child: Image.asset(
                          widget.abilityInfo.iconPath,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : Stack(
              children: [
                IgnorePointer(
                  child: Container(
                    width: scaleSize,
                    height: scaleSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: widget.outlineColor,
                          width: coordinateSystem.scale(5)),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment.center,
                      child: IgnorePointer(
                        child: Container(
                          width: secondaryScaleSize,
                          height: secondaryScaleSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.innerColor!
                                .withAlpha(widget.opacity ?? 70),
                            border: Border.all(
                              color: widget.innerColor!,
                              width: coordinateSystem.scale(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.center,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                      child: Container(
                        width: coordinateSystem.scale(25),
                        height: coordinateSystem.scale(25),
                        padding: EdgeInsets.all(coordinateSystem.scale(3)),
                        decoration: const BoxDecoration(
                          color: Color(0xFF1B1B1B),
                        ),
                        child: Image.asset(
                          widget.abilityInfo.iconPath,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
    }

    return Container(
      width: scaleSize,
      height: scaleSize,
      decoration: BoxDecoration(
          color: widget.outlineColor.withAlpha(widget.opacity ?? 70),
          shape: BoxShape.circle,
          border: Border.all(
            color: widget.outlineColor,
            width: coordinateSystem.scale(5),
          )),
    );
  }
}
