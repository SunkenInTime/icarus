import 'dart:convert';

import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';

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

  /// The object as plain JSON, the same fields live sync sends. Only kinds
  /// that record field edits have one; drawings are only added and removed,
  /// and lineups keep their own history.
  Map<String, dynamic> toJson() {
    final Object encoded = switch (kind) {
      ActionObjectKind.agent => agent!.toJson(),
      ActionObjectKind.ability => ability!.toJson(),
      ActionObjectKind.text => text!.toJson(),
      ActionObjectKind.image => image!.toJson(),
      ActionObjectKind.utility => utility!.toJson(),
      ActionObjectKind.drawing ||
      ActionObjectKind.lineUp =>
        throw UnsupportedError('$kind records no field edits'),
    };
    return jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>;
  }

  factory ActionObjectState.fromJson(
    ActionObjectKind kind,
    Map<String, dynamic> json,
  ) {
    return switch (kind) {
      ActionObjectKind.agent =>
        ActionObjectState.agent(PlacedAgentNode.fromJson(json)),
      ActionObjectKind.ability =>
        ActionObjectState.ability(PlacedAbility.fromJson(json)),
      ActionObjectKind.text =>
        ActionObjectState.text(PlacedText.fromJson(json)),
      ActionObjectKind.image =>
        ActionObjectState.image(PlacedImage.fromJson(json)),
      ActionObjectKind.utility =>
        ActionObjectState.utility(PlacedUtility.fromJson(json)),
      ActionObjectKind.drawing ||
      ActionObjectKind.lineUp =>
        throw UnsupportedError('$kind records no field edits'),
    };
  }
}

/// [onto] with each top-level field that differs between [from] and [to] set
/// to its value in [to] (removed where [to] has none). Fields [from] and [to]
/// agree on keep their value in [onto], so writing one edit leaves everything
/// else changed since, a teammate's edits included, as it is.
Map<String, dynamic> writeChangedFields({
  required Map<String, dynamic> to,
  required Map<String, dynamic> from,
  required Map<String, dynamic> onto,
}) {
  final written = Map<String, dynamic>.from(onto);
  for (final field in {...to.keys, ...from.keys}) {
    if (cloudJsonEquivalent(to[field], from[field])) continue;
    if (to.containsKey(field)) {
      written[field] = to[field];
    } else {
      written.remove(field);
    }
  }
  return written;
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

  /// The object after undoing this edit on [current]: only the fields the
  /// edit changed go back to [before].
  ActionObjectState undoOnto(ActionObjectState current) =>
      _write(to: before!, from: after!, onto: current);

  /// The object after redoing this edit on [current]: only the fields the
  /// edit changed go to [after].
  ActionObjectState redoOnto(ActionObjectState current) =>
      _write(to: after!, from: before!, onto: current);

  static ActionObjectState _write({
    required ActionObjectState to,
    required ActionObjectState from,
    required ActionObjectState onto,
  }) {
    final toJson = to.toJson();
    final written = writeChangedFields(
      to: toJson,
      from: from.toJson(),
      onto: onto.toJson(),
    );
    // Nothing else changed the object since, so it is exactly [to]; keep
    // that copy rather than rebuilding it from JSON.
    if (cloudJsonEquivalent(written, toJson)) return to.clone();
    return ActionObjectState.fromJson(to.kind, written);
  }

  ObjectHistoryDelta clone() {
    return ObjectHistoryDelta(
      before: before?.clone(),
      after: after?.clone(),
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
