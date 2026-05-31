import 'dart:ui';

import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/placed_media_dimensions.dart';

class ActionHistoryTransformContext {
  final double agentSize;
  final double abilitySize;
  final double mapScale;

  const ActionHistoryTransformContext({
    required this.agentSize,
    required this.abilitySize,
    required this.mapScale,
  });
}

class ActionObjectState {
  final String id;
  final ActionObjectKind kind;
  final PlacedAgentNode? agent;
  final PlacedAbility? ability;
  final DrawingElement? drawing;
  final PlacedText? text;
  final PlacedImage? image;
  final PlacedUtility? utility;
  final LineUp? lineUp;

  const ActionObjectState._({
    required this.id,
    required this.kind,
    this.agent,
    this.ability,
    this.drawing,
    this.text,
    this.image,
    this.utility,
    this.lineUp,
  });

  factory ActionObjectState.agent(PlacedAgentNode value) => ActionObjectState._(
        id: value.id,
        kind: ActionObjectKind.agent,
        agent: clonePlacedAgentNode(value),
      );

  factory ActionObjectState.ability(PlacedAbility value) => ActionObjectState._(
        id: value.id,
        kind: ActionObjectKind.ability,
        ability: clonePlacedAbility(value),
      );

  factory ActionObjectState.drawing(DrawingElement value) =>
      ActionObjectState._(
        id: value.id,
        kind: ActionObjectKind.drawing,
        drawing: cloneDrawingElement(value),
      );

  factory ActionObjectState.text(PlacedText value) => ActionObjectState._(
        id: value.id,
        kind: ActionObjectKind.text,
        text: clonePlacedText(value),
      );

  factory ActionObjectState.image(PlacedImage value) => ActionObjectState._(
        id: value.id,
        kind: ActionObjectKind.image,
        image: clonePlacedImage(value),
      );

  factory ActionObjectState.utility(PlacedUtility value) => ActionObjectState._(
        id: value.id,
        kind: ActionObjectKind.utility,
        utility: clonePlacedUtility(value),
      );

  factory ActionObjectState.lineUp(LineUp value) => ActionObjectState._(
        id: value.id,
        kind: ActionObjectKind.lineUp,
        lineUp: cloneLineUp(value),
      );

  ActionObjectState clone() {
    return switch (kind) {
      ActionObjectKind.agent => ActionObjectState.agent(agent!),
      ActionObjectKind.ability => ActionObjectState.ability(ability!),
      ActionObjectKind.drawing => ActionObjectState.drawing(drawing!),
      ActionObjectKind.text => ActionObjectState.text(text!),
      ActionObjectKind.image => ActionObjectState.image(image!),
      ActionObjectKind.utility => ActionObjectState.utility(utility!),
      ActionObjectKind.lineUp => ActionObjectState.lineUp(lineUp!),
    };
  }

  ActionObjectState switchSides(ActionHistoryTransformContext context) {
    return switch (kind) {
      ActionObjectKind.agent => ActionObjectState.agent(
          clonePlacedAgentNode(agent!)..switchSides(context.agentSize),
        ),
      ActionObjectKind.ability => ActionObjectState.ability(
          clonePlacedAbility(ability!)
            ..switchSides(
              mapScale: context.mapScale,
              abilitySize: context.abilitySize,
            ),
        ),
      ActionObjectKind.drawing => ActionObjectState.drawing(
          switchDrawingElementSides(cloneDrawingElement(drawing!)),
        ),
      ActionObjectKind.text => _switchTextSides(),
      ActionObjectKind.image => _switchImageSides(),
      ActionObjectKind.utility => ActionObjectState.utility(
          clonePlacedUtility(utility!)
            ..switchSides(
              mapScale: context.mapScale,
              agentSize: context.agentSize,
              abilitySize: context.abilitySize,
            ),
        ),
      ActionObjectKind.lineUp => ActionObjectState.lineUp(
          cloneLineUp(lineUp!)
            ..switchSides(
              agentSize: context.agentSize,
              abilitySize: context.abilitySize,
              mapScale: context.mapScale,
            ),
        ),
    };
  }

  ActionObjectState _switchTextSides() {
    final value = clonePlacedText(text!);
    final size = PlacedTextDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      widthWorld: value.size,
      fontSizeWorld: value.fontSize,
      text: value.text,
    );

    return ActionObjectState.text(
      value..switchSides(Offset(size.width, size.height)),
    );
  }

  ActionObjectState _switchImageSides() {
    final value = clonePlacedImage(image!);
    final size = PlacedImageDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      scale: value.scale,
      aspectRatio: value.aspectRatio,
    );

    return ActionObjectState.image(
      value..switchSides(Offset(size.width, size.height)),
    );
  }
}

enum ActionObjectKind {
  agent,
  ability,
  drawing,
  text,
  image,
  utility,
  lineUp,
}

class ObjectHistoryDelta {
  final ActionObjectState? before;
  final ActionObjectState? after;

  const ObjectHistoryDelta({
    this.before,
    this.after,
  });

  String get id => after?.id ?? before!.id;

  ObjectHistoryDelta clone() {
    return ObjectHistoryDelta(
      before: before?.clone(),
      after: after?.clone(),
    );
  }

  ObjectHistoryDelta switchSides(ActionHistoryTransformContext context) {
    return ObjectHistoryDelta(
      before: before?.switchSides(context),
      after: after?.switchSides(context),
    );
  }
}

PlacedAgentNode clonePlacedAgentNode(PlacedAgentNode value) {
  return switch (value) {
    PlacedAgent() => value.copyWith(),
    PlacedViewConeAgent() => value.copyWith(),
    PlacedCircleAgent() => value.copyWith(),
  };
}

PlacedAbility clonePlacedAbility(PlacedAbility value) =>
    value.copyWith()..isDeleted = value.isDeleted;

PlacedText clonePlacedText(PlacedText value) => value.copyWith(
      text: value.text,
      isDeleted: value.isDeleted,
    )..isDeleted = value.isDeleted;

PlacedImage clonePlacedImage(PlacedImage value) =>
    value.copyWith(isDeleted: value.isDeleted)..isDeleted = value.isDeleted;

PlacedUtility clonePlacedUtility(PlacedUtility value) =>
    value.copyWith()..isDeleted = value.isDeleted;

LineUp cloneLineUp(LineUp value) {
  return LineUp(
    id: value.id,
    agent: clonePlacedAgentNode(value.agent) as PlacedAgent,
    ability: clonePlacedAbility(value.ability),
    youtubeLink: value.youtubeLink,
    images: value.images.map((image) => image.copyWith()).toList(),
    notes: value.notes,
  );
}

DrawingElement cloneDrawingElement(DrawingElement value) {
  if (value is FreeDrawing) {
    return value.copyWith(
      listOfPoints: [...value.listOfPoints],
      boundingBox: cloneBoundingBox(value.boundingBox),
      cachedPolylineLengthUnits: value.cachedPolylineLengthUnits,
    );
  }
  if (value is Line) {
    return value.copyWith(
      boundingBox: cloneBoundingBox(value.boundingBox),
    );
  }
  if (value is RectangleDrawing) {
    return RectangleDrawing(
      start: value.start,
      end: value.end,
      color: value.color,
      thickness: value.thickness,
      boundingBox: cloneBoundingBox(value.boundingBox),
      isDotted: value.isDotted,
      hasArrow: value.hasArrow,
      id: value.id,
    );
  }
  if (value is EllipseDrawing) {
    return EllipseDrawing(
      start: value.start,
      end: value.end,
      color: value.color,
      thickness: value.thickness,
      boundingBox: cloneBoundingBox(value.boundingBox),
      isDotted: value.isDotted,
      hasArrow: value.hasArrow,
      id: value.id,
    );
  }
  throw UnsupportedError('Unsupported drawing element: ${value.runtimeType}');
}

BoundingBox? cloneBoundingBox(BoundingBox? value) {
  if (value == null) {
    return null;
  }
  return BoundingBox(min: value.min, max: value.max);
}

DrawingElement switchDrawingElementSides(DrawingElement value) {
  final flipped = cloneDrawingElement(value);
  if (flipped is FreeDrawing) {
    flipped.replacePoints(
      flipped.listOfPoints.map(_flipCoordinatePoint).toList(),
    );
    flipped.boundingBox = _boundingBoxForPoints(flipped.listOfPoints);
    flipped.rebuildPath(CoordinateSystem.instance);
    return flipped;
  }
  if (flipped is Line) {
    final start = _flipCoordinatePoint(flipped.lineStart);
    final end = _flipCoordinatePoint(flipped.lineEnd);
    return flipped.copyWith(
      lineStart: start,
      lineEnd: end,
      boundingBox: _lineBoundingBox(start, end),
    );
  }
  if (flipped is RectangleDrawing) {
    final start = _flipCoordinatePoint(flipped.start);
    final end = _flipCoordinatePoint(flipped.end);
    return RectangleDrawing(
      start: start,
      end: end,
      color: flipped.color,
      thickness: flipped.thickness,
      boundingBox: _lineBoundingBox(start, end),
      isDotted: flipped.isDotted,
      hasArrow: flipped.hasArrow,
      id: flipped.id,
    );
  }
  if (flipped is EllipseDrawing) {
    final start = _flipCoordinatePoint(flipped.start);
    final end = _flipCoordinatePoint(flipped.end);
    return EllipseDrawing(
      start: start,
      end: end,
      color: flipped.color,
      thickness: flipped.thickness,
      boundingBox: _lineBoundingBox(start, end),
      isDotted: flipped.isDotted,
      hasArrow: flipped.hasArrow,
      id: flipped.id,
    );
  }
  return flipped;
}

Offset _flipCoordinatePoint(Offset point) {
  final coordinateSystem = CoordinateSystem.instance;
  return Offset(
    coordinateSystem.worldNormalizedWidth - point.dx,
    coordinateSystem.normalizedHeight - point.dy,
  );
}

BoundingBox _lineBoundingBox(Offset start, Offset end) {
  return BoundingBox(
    min: Offset(
      start.dx < end.dx ? start.dx : end.dx,
      start.dy < end.dy ? start.dy : end.dy,
    ),
    max: Offset(
      start.dx > end.dx ? start.dx : end.dx,
      start.dy > end.dy ? start.dy : end.dy,
    ),
  );
}

BoundingBox? _boundingBoxForPoints(List<Offset> points) {
  if (points.isEmpty) {
    return null;
  }
  double minX = points.first.dx;
  double minY = points.first.dy;
  double maxX = points.first.dx;
  double maxY = points.first.dy;
  for (final point in points.skip(1)) {
    if (point.dx < minX) minX = point.dx;
    if (point.dy < minY) minY = point.dy;
    if (point.dx > maxX) maxX = point.dx;
    if (point.dy > maxY) maxY = point.dy;
  }
  return BoundingBox(min: Offset(minX, minY), max: Offset(maxX, maxY));
}
