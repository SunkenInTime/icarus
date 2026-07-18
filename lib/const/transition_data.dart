import 'dart:ui';

import 'package:icarus/const/agents.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
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
    if (widget is PlacedAgentNode) {
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
  double? mapScale,
  double? agentSize,
  double? abilitySize,
}) {
  final position = coordinatePosition ?? widget.position;
  var screen = coordinateSystem.coordinateToScreen(position);
  if (widget is PlacedAgentNode && agentSize != null) {
    screen += agentScreenPositionAdjustment(
      coordinateSystem: coordinateSystem,
      agentSize: agentSize,
    );
  }
  if (widget is PlacedAbility && mapScale != null && abilitySize != null) {
    screen += abilityScreenPositionAdjustment(
      ability: widget.data.abilityData!,
      coordinateSystem: coordinateSystem,
      mapScale: mapScale,
      abilitySize: abilitySize,
    );
  }
  if (widget is PlacedUtility &&
      mapScale != null &&
      agentSize != null &&
      abilitySize != null) {
    screen += utilityScreenPositionAdjustment(
      utility: widget,
      coordinateSystem: coordinateSystem,
      mapScale: mapScale,
      agentSize: agentSize,
      abilitySize: abilitySize,
    );
  }
  if (widget is PlacedAbility && widget.data.abilityData is CircleAbility) {
    // Pixel snapping keeps circles from visually drifting between static and
    // overlay renderers due to sub-pixel interpolation differences.
    return Offset(screen.dx.roundToDouble(), screen.dy.roundToDouble());
  }
  return screen;
}

/// The stored position of an agent-backed icon is its top-left at the
/// historical default marker size. Runtime scaling moves that top-left so the
/// icon center remains fixed without rewriting serialized strategy data.
Offset get storedAgentAnchor =>
    const Offset(Settings.agentSize / 2, Settings.agentSize / 2);

Offset agentScreenPositionAdjustment({
  required CoordinateSystem coordinateSystem,
  required double agentSize,
}) {
  final renderedAnchor = Offset(agentSize / 2, agentSize / 2);
  return (storedAgentAnchor - renderedAnchor).scale(
    coordinateSystem.scaleFactor,
    coordinateSystem.scaleFactor,
  );
}

Offset storedAgentPositionForRenderedScreenPosition({
  required CoordinateSystem coordinateSystem,
  required Offset renderedScreenPosition,
  required double agentSize,
}) {
  final adjustment = agentScreenPositionAdjustment(
    coordinateSystem: coordinateSystem,
    agentSize: agentSize,
  );
  return coordinateSystem.screenToCoordinate(
    renderedScreenPosition - adjustment,
  );
}

Offset screenAnchorForAgent({
  required PlacedAgentNode agent,
  required CoordinateSystem coordinateSystem,
  Offset? coordinatePosition,
}) {
  return screenPositionForWidget(
        widget: agent,
        coordinateSystem: coordinateSystem,
        coordinatePosition: coordinatePosition,
        agentSize: Settings.agentSize,
      ) +
      storedAgentAnchor.scale(
        coordinateSystem.scaleFactor,
        coordinateSystem.scaleFactor,
      );
}

/// The stored position of a placed ability is the top-left position it had at
/// the historical default marker size. Keeping that serialized contract means
/// old and new strategies remain visually identical without a migration.
Offset storedAbilityAnchor({
  required Ability ability,
  required double mapScale,
}) {
  return ability.getAnchorPoint(
    mapScale: mapScale,
    abilitySize: Settings.abilitySize,
  );
}

/// Runtime-only top-left adjustment that keeps [Ability.getAnchorPoint]
/// visually fixed while a strategy's ability marker size changes.
Offset abilityScreenPositionAdjustment({
  required Ability ability,
  required CoordinateSystem coordinateSystem,
  required double mapScale,
  required double abilitySize,
}) {
  final storedAnchor = storedAbilityAnchor(
    ability: ability,
    mapScale: mapScale,
  );
  final renderedAnchor = ability.getAnchorPoint(
    mapScale: mapScale,
    abilitySize: abilitySize,
  );
  return (storedAnchor - renderedAnchor).scale(
    coordinateSystem.scaleFactor,
    coordinateSystem.scaleFactor,
  );
}

/// Converts the rendered top-left from a drag/drop back to the stable position
/// persisted in strategy files.
Offset storedAbilityPositionForRenderedScreenPosition({
  required Ability ability,
  required CoordinateSystem coordinateSystem,
  required Offset renderedScreenPosition,
  required double mapScale,
  required double abilitySize,
}) {
  final adjustment = abilityScreenPositionAdjustment(
    ability: ability,
    coordinateSystem: coordinateSystem,
    mapScale: mapScale,
    abilitySize: abilitySize,
  );
  return coordinateSystem.screenToCoordinate(
    renderedScreenPosition - adjustment,
  );
}

/// Screen-space position of the semantic widget anchor. It intentionally does
/// not depend on the current marker size.
Offset screenAnchorForAbility({
  required PlacedAbility ability,
  required CoordinateSystem coordinateSystem,
  required double mapScale,
  Offset? coordinatePosition,
}) {
  return screenPositionForWidget(
        widget: ability,
        coordinateSystem: coordinateSystem,
        coordinatePosition: coordinatePosition,
        mapScale: mapScale,
        abilitySize: Settings.abilitySize,
      ) +
      storedAbilityAnchor(
        ability: ability.data.abilityData!,
        mapScale: mapScale,
      ).scale(
        coordinateSystem.scaleFactor,
        coordinateSystem.scaleFactor,
      );
}

Offset utilityAnchorForScale({
  required PlacedUtility utility,
  required double mapScale,
  required double agentSize,
  required double abilitySize,
}) {
  return UtilityData.utilityWidgets[utility.type]!.getAnchorPoint(
    id: utility.id,
    length: utility.length,
    rotation: utility.rotation,
    mapScale: mapScale,
    agentSize: agentSize,
    abilitySize: abilitySize,
    diameterMeters: utility.customDiameter,
    widthMeters: utility.customWidth,
    rectLengthMeters: utility.customLength,
  );
}

Offset storedUtilityAnchor({
  required PlacedUtility utility,
  required double mapScale,
}) {
  return utilityAnchorForScale(
    utility: utility,
    mapScale: mapScale,
    agentSize: Settings.agentSize,
    abilitySize: Settings.abilitySize,
  );
}

Offset utilityScreenPositionAdjustment({
  required PlacedUtility utility,
  required CoordinateSystem coordinateSystem,
  required double mapScale,
  required double agentSize,
  required double abilitySize,
}) {
  final storedAnchor = storedUtilityAnchor(
    utility: utility,
    mapScale: mapScale,
  );
  final renderedAnchor = utilityAnchorForScale(
    utility: utility,
    mapScale: mapScale,
    agentSize: agentSize,
    abilitySize: abilitySize,
  );
  return (storedAnchor - renderedAnchor).scale(
    coordinateSystem.scaleFactor,
    coordinateSystem.scaleFactor,
  );
}

Offset storedUtilityPositionForRenderedScreenPosition({
  required PlacedUtility utility,
  required CoordinateSystem coordinateSystem,
  required Offset renderedScreenPosition,
  required double mapScale,
  required double agentSize,
  required double abilitySize,
}) {
  final adjustment = utilityScreenPositionAdjustment(
    utility: utility,
    coordinateSystem: coordinateSystem,
    mapScale: mapScale,
    agentSize: agentSize,
    abilitySize: abilitySize,
  );
  return coordinateSystem.screenToCoordinate(
    renderedScreenPosition - adjustment,
  );
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
    if (w is PlacedViewConeAgent) return w.rotation;
    return null;
  }

  static double? lengthOf(PlacedWidget w) {
    if (w is PlacedAbility) return w.length;
    if (w is PlacedUtility) return w.length;
    if (w is PlacedViewConeAgent) return w.length;
    return null;
  }

  static List<double>? armLengthsOf(PlacedWidget w) {
    if (w is PlacedAbility) {
      return List<double>.from(w.armLengthsMeters);
    }
    return null;
  }

  static double? scaleOf(PlacedWidget w) {
    if (w is PlacedImage) return w.scale;
    return null;
  }

  static double? textSizeOf(PlacedWidget w) {
    if (w is PlacedText) return w.size;
    return null;
  }

  static double? customDiameterOf(PlacedWidget w) {
    if (w is PlacedUtility) return w.customDiameter;
    if (w is PlacedCircleAgent) return w.diameterMeters;
    return null;
  }

  static double? customWidthOf(PlacedWidget w) {
    if (w is PlacedUtility) return w.customWidth;
    return null;
  }

  static double? customLengthOf(PlacedWidget w) {
    if (w is PlacedUtility) return w.customLength;
    return null;
  }

  static AgentState? agentStateOf(PlacedWidget w) {
    if (w is PlacedAgent) return w.state;
    return null;
  }

  double? get startRotation => from != null ? rotationOf(from!) : null;
  double? get endRotation => to != null ? rotationOf(to!) : null;

  double? get startLength => from != null ? lengthOf(from!) : null;
  double? get endLength => to != null ? lengthOf(to!) : null;
  List<double>? get startArmLengths =>
      from != null ? armLengthsOf(from!) : null;
  List<double>? get endArmLengths => to != null ? armLengthsOf(to!) : null;

  double? get startScale => from != null ? scaleOf(from!) : null;
  double? get endScale => to != null ? scaleOf(to!) : null;

  double? get startTextSize => from != null ? textSizeOf(from!) : null;
  double? get endTextSize => to != null ? textSizeOf(to!) : null;

  double? get startCustomDiameter =>
      from != null ? customDiameterOf(from!) : null;
  double? get endCustomDiameter => to != null ? customDiameterOf(to!) : null;

  double? get startCustomWidth => from != null ? customWidthOf(from!) : null;
  double? get endCustomWidth => to != null ? customWidthOf(to!) : null;

  double? get startCustomLength => from != null ? customLengthOf(from!) : null;
  double? get endCustomLength => to != null ? customLengthOf(to!) : null;

  AgentState? get startAgentState => from != null ? agentStateOf(from!) : null;
  AgentState? get endAgentState => to != null ? agentStateOf(to!) : null;
}
