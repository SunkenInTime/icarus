import 'dart:ui';

import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';

enum TransitionKind { move, appear, disappear, none }

enum PageTransitionDirection { forward, backward }

enum PageVisualLayer {
  customUtility,
  viewConeUtility,
  ability,
  agent,
  text,
  image,
  utility,
}

class PageLayering {
  const PageLayering._();

  static bool isCustomShapeUtility(PlacedUtility utility) {
    return UtilityData.isCustomShape(utility.type);
  }

  static bool isViewConeUtility(PlacedUtility utility) {
    return UtilityData.isViewCone(utility.type);
  }

  static bool isTopUtility(PlacedUtility utility) {
    return !isCustomShapeUtility(utility) && !isViewConeUtility(utility);
  }

  static PageVisualLayer layerOfWidget(PlacedWidget widget) {
    if (widget is PlacedUtility) {
      if (isCustomShapeUtility(widget)) {
        return PageVisualLayer.customUtility;
      }
      if (isViewConeUtility(widget)) {
        return PageVisualLayer.viewConeUtility;
      }
      return PageVisualLayer.utility;
    }
    if (widget is PlacedAbility) {
      return PageVisualLayer.ability;
    }
    if (widget is PlacedAgent) {
      return PageVisualLayer.agent;
    }
    if (widget is PlacedText) {
      return PageVisualLayer.text;
    }
    if (widget is PlacedImage) {
      return PageVisualLayer.image;
    }
    return PageVisualLayer.utility;
  }

  static int zIndexForWidget(PlacedWidget widget) {
    return layerOfWidget(widget).index;
  }

  static int comparePlacedWidgets(PlacedWidget a, PlacedWidget b) {
    final zCompare = zIndexForWidget(a).compareTo(zIndexForWidget(b));
    if (zCompare != 0) {
      return zCompare;
    }
    return a.id.compareTo(b.id);
  }

  static int compareEntries(PageTransitionEntry a, PageTransitionEntry b) {
    final zCompare = zIndexForWidget(a.visualWidget)
        .compareTo(zIndexForWidget(b.visualWidget));
    if (zCompare != 0) {
      return zCompare;
    }
    final orderCompare = a.order.compareTo(b.order);
    if (orderCompare != 0) {
      return orderCompare;
    }
    return a.id.compareTo(b.id);
  }
}

Offset screenPositionForWidget({
  required PlacedWidget widget,
  required CoordinateSystem coordinateSystem,
  Offset? coordinatePosition,
}) {
  final position = coordinatePosition ?? widget.position;
  final screen = coordinateSystem.coordinateToScreen(position);
  if (widget is PlacedAbility && widget.data.abilityData is CircleAbility) {
    // Pixel snapping keeps circles from visually drifting between static and
    // overlay renderers due to sub-pixel interpolation differences.
    return Offset(screen.dx.roundToDouble(), screen.dy.roundToDouble());
  }
  return screen;
}

/// One entry describing how a single PlacedWidget should animate.
class PageTransitionEntry {
  PageTransitionEntry.move(
      {required this.from, required this.to, this.order = 0})
      : kind = TransitionKind.move,
        id = to!.id;
  PageTransitionEntry.appear({required this.to, this.order = 0})
      : kind = TransitionKind.appear,
        id = to!.id,
        from = null;
  PageTransitionEntry.disappear({required this.from, this.order = 0})
      : kind = TransitionKind.disappear,
        id = from!.id,
        to = null;
  // For unchanged items we still want to render during the transition
  // so they remain visible while the base view is hidden.
  PageTransitionEntry.none({required this.to, this.order = 0})
      : kind = TransitionKind.none,
        id = to!.id,
        from = null;

  final String id;
  final TransitionKind kind;
  final int order;
  final PlacedWidget? from; // null for appear
  final PlacedWidget? to; // null for disappear
  PlacedWidget get visualWidget => (to ?? from)!;

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
