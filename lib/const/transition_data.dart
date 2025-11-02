import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:icarus/const/placed_classes.dart';

enum TransitionKind { move, appear, disappear, none }

/// One entry describing how a single PlacedWidget should animate.
class PageTransitionEntry {
  PageTransitionEntry.move({required this.from, required this.to})
      : kind = TransitionKind.move,
        id = to!.id;
  PageTransitionEntry.appear({required this.to})
      : kind = TransitionKind.appear,
        id = to!.id,
        from = null;
  PageTransitionEntry.disappear({required this.from})
      : kind = TransitionKind.disappear,
        id = from!.id,
        to = null;
  // For unchanged items we still want to render during the transition
  // so they remain visible while the base view is hidden.
  PageTransitionEntry.none({required this.to})
      : kind = TransitionKind.none,
        id = to!.id,
        from = null;

  final String id;
  final TransitionKind kind;
  final PlacedWidget? from; // null for appear
  final PlacedWidget? to; // null for disappear

  Offset get startPos => (from ?? to)!.position;
  Offset get endPos => (to ?? from)!.position;

  // Rotation is only relevant for some subtypes. Null when not applicable.
  static double? rotationOf(PlacedWidget w) {
    if (w is PlacedAbility) return w.rotation;
    if (w is PlacedUtility) return w.rotation;
    return null;
  }

  static double? lengthOf(PlacedWidget w) {
    if (w is PlacedAbility) return w.length;
    if (w is PlacedUtility) return w.length;
    return null;
  }

  double? get startRotation => from != null ? rotationOf(from!) : null;
  double? get endRotation => to != null ? rotationOf(to!) : null;

  double? get startLength => from != null ? lengthOf(from!) : null;
  double? get endLength => to != null ? lengthOf(to!) : null;
}
