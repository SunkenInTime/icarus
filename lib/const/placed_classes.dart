import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/json_converters.dart';
import 'package:icarus/const/utilities.dart';
import 'package:json_annotation/json_annotation.dart';

part "placed_classes.g.dart";

/// Converter for [Offset] to and from JSON.
class BaseOffsetConverter {
  const BaseOffsetConverter();

  Offset fromJson(Map<String, dynamic> json) {
    return Offset(
      (json['dx'] as num).toDouble(),
      (json['dy'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson(Offset offset) {
    return {'dx': offset.dx, 'dy': offset.dy};
  }
}

@JsonSerializable()
class PlacedWidget extends HiveObject {
  PlacedWidget({
    required this.position,
    required this.id,
    this.isDeleted = false,
  });

  final String id;

  @JsonKey(defaultValue: false)
  bool isDeleted;

  @JsonKey(includeToJson: false, includeFromJson: false)
  final List<WidgetAction> _actionHistory = [];

  @JsonKey(includeToJson: false, includeFromJson: false)
  final List<WidgetAction> _poppedAction = [];

  @OffsetConverter()
  Offset position;

  void updatePosition(Offset newPosition) {
    final action = PositionAction(position: position);
    _actionHistory.add(action);
    position = newPosition;
  }

  void undoAction() {
    if (_actionHistory.isEmpty) return;

    if (_actionHistory.last is PositionAction) {
      _undoPosition();
    }
  }

  void _undoPosition() {
    final action = PositionAction(position: position);

    _poppedAction.add(action);
    position = (_actionHistory.last as PositionAction).position;
    _actionHistory.removeLast();
  }

  void redoAction() {
    if (_poppedAction.isEmpty) return;

    if (_poppedAction.last is PositionAction) {
      _redoPosition();
    }
  }

  void _redoPosition() {
    final action = PositionAction(position: position);

    _actionHistory.add(action);
    position = (_poppedAction.last as PositionAction).position;
    _poppedAction.removeLast();
  }

  factory PlacedWidget.fromJson(Map<String, dynamic> json) =>
      _$PlacedWidgetFromJson(json);
  Map<String, dynamic> toJson() => _$PlacedWidgetToJson(this);

  static int getIndexByID(String id, List<PlacedWidget> elements) {
    return elements.indexWhere(
      (element) => element.id == id,
    );
  }
}

@JsonSerializable()
class PlacedText extends PlacedWidget {
  PlacedText({required super.position, required super.id, this.size = 200});

  String text = "";
  double size;

  factory PlacedText.fromJson(Map<String, dynamic> json) =>
      _$PlacedTextFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$PlacedTextToJson(this);
}

@JsonSerializable()
class PlacedImage extends PlacedWidget {
  PlacedImage({
    required super.position,
    required super.id,
    required this.aspectRatio,
    required this.scale,
    required this.fileExtension,
  });

  final double aspectRatio;

  final String? fileExtension;
  double scale;

  String link = "";

  void updateLink(String link) {
    this.link = link;
  }

  /// Returns a new independent [PlacedImage] object. None of the internal
  /// action history / redo stacks from the base [PlacedWidget] are carried
  /// over, ensuring this is a clean clone (useful when duplicating pages or
  /// creating a new page from existing data).
  ///
  /// Supply any parameter to override the corresponding value.
  PlacedImage copyWith({
    String? id,
    Offset? position,
    double? aspectRatio,
    double? scale,
    String? fileExtension,
    bool? isDeleted,
    String? link,
  }) {
    final cloned = PlacedImage(
      position: position ?? this.position,
      id: id ?? this.id,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      scale: scale ?? this.scale,
      fileExtension: fileExtension ?? this.fileExtension,
    );
    // Base class field
    // cloned.isDeleted = isDeleted ?? this.isDeleted;
    // Mutable field specific to PlacedImage
    cloned.link = this.link;
    return cloned;
  }

  factory PlacedImage.fromJson(Map<String, dynamic> json) =>
      _$PlacedImageFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$PlacedImageToJson(this);
}

class Uint8ListConverter {
  /// Serializes a [Uint8List] into a Base64-encoded string.
  static String serialize(Uint8List data) {
    return base64Encode(data);
  }

  /// Deserializes a Base64-encoded string back into a [Uint8List].
  static Uint8List deserialize(String base64String) {
    return Uint8List.fromList(base64Decode(base64String));
  }
}

@JsonSerializable()
class PlacedAgent extends PlacedWidget {
  final AgentType type;
  @JsonKey(defaultValue: true)
  bool isAlly;

  PlacedAgent({
    required this.type,
    required super.position,
    required super.id,
    this.isAlly = true, // Default parameter value
  });

  factory PlacedAgent.fromJson(Map<String, dynamic> json) =>
      _$PlacedAgentFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$PlacedAgentToJson(this);
}

@JsonSerializable()
class PlacedAbility extends PlacedWidget {
  @AbilityInfoConverter()
  final AbilityInfo data;

  @JsonKey(defaultValue: true)
  final bool isAlly;

  double rotation = 0;

  double length = 0;

  void updateRotation(double newRotation, double newLength) {
    rotation = newRotation;
    length = newLength;
  }

  void updateRotationHistory() {
    final action = RotationAction(rotation: rotation, length: length);
    _actionHistory.add(action);
  }

  void _undoRotation() {
    final action = RotationAction(rotation: rotation, length: length);

    _poppedAction.add(action);
    rotation = (_actionHistory.last as RotationAction).rotation;
    length = (_actionHistory.last as RotationAction).length;
    _actionHistory.removeLast();
  }

  void _redoRotation() {
    if (_poppedAction.isEmpty) return;

    final action = RotationAction(rotation: rotation, length: length);

    _actionHistory.add(action);
    rotation = (_poppedAction.last as RotationAction).rotation;
    length = (_poppedAction.last as RotationAction).length;
    _poppedAction.removeLast();
  }

  @override
  void undoAction() {
    if (_actionHistory.isEmpty) return;

    if (_actionHistory.last is PositionAction) {
      _undoPosition();
    } else if (_actionHistory.last is RotationAction) {
      _undoRotation();
    }
  }

  @override
  void redoAction() {
    if (_poppedAction.isEmpty) return;

    if (_poppedAction.last is PositionAction) {
      _redoPosition();
    } else if (_poppedAction.last is RotationAction) {
      _redoRotation();
    }
  }

  PlacedAbility({
    required this.data,
    required super.position,
    required super.id,
    this.isAlly = true,
    this.length = 0,
  });

  factory PlacedAbility.fromJson(Map<String, dynamic> json) =>
      _$PlacedAbilityFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$PlacedAbilityToJson(this);
}

abstract class WidgetAction {}

class RotationAction extends WidgetAction {
  final double rotation;
  final double length;
  RotationAction({required this.rotation, required this.length});
}

class PositionAction extends WidgetAction {
  final Offset position;

  PositionAction({required this.position});
}

@JsonSerializable()
class PlacedUtility extends PlacedWidget {
  final UtilityType type;

  double rotation = 0;
  double length = 0;

  void updateRotation(double newRotation, double newLength) {
    rotation = newRotation;
    length = newLength;
  }

  void updateRotationHistory() {
    final action = RotationAction(rotation: rotation, length: length);
    _actionHistory.add(action);
  }

  void _undoRotation() {
    final action = RotationAction(rotation: rotation, length: length);

    _poppedAction.add(action);
    rotation = (_actionHistory.last as RotationAction).rotation;
    length = (_actionHistory.last as RotationAction).length;
    _actionHistory.removeLast();
  }

  void _redoRotation() {
    if (_poppedAction.isEmpty) return;

    final action = RotationAction(rotation: rotation, length: length);

    _actionHistory.add(action);
    rotation = (_poppedAction.last as RotationAction).rotation;
    length = (_poppedAction.last as RotationAction).length;
    _poppedAction.removeLast();
  }

  @override
  void undoAction() {
    if (_actionHistory.isEmpty) return;

    if (_actionHistory.last is PositionAction) {
      _undoPosition();
    } else if (_actionHistory.last is RotationAction) {
      _undoRotation();
    }
  }

  @override
  void redoAction() {
    if (_poppedAction.isEmpty) return;

    if (_poppedAction.last is PositionAction) {
      _redoPosition();
    } else if (_poppedAction.last is RotationAction) {
      _redoRotation();
    }
  }

  PlacedUtility({
    required this.type,
    required super.position,
    required super.id,
  });

  factory PlacedUtility.fromJson(Map<String, dynamic> json) =>
      _$PlacedUtilityFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$PlacedUtilityToJson(this);
}
