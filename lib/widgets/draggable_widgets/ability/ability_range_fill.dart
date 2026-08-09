import 'package:flutter/material.dart';

Color resolveAbilityRangeFillColor({
  required Color rangeOutlineColor,
  Color? rangeFillColor,
  int? opacity,
}) {
  return rangeFillColor ?? rangeOutlineColor.withAlpha(opacity ?? 70);
}

bool hasVisibleAbilityRangeFill({
  required Color rangeOutlineColor,
  Color? rangeFillColor,
  int? opacity,
}) {
  final fillColor = resolveAbilityRangeFillColor(
    rangeOutlineColor: rangeOutlineColor,
    rangeFillColor: rangeFillColor,
    opacity: opacity,
  );
  return fillColor.a > 0;
}
