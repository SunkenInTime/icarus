import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/json_converters.dart';
import 'package:icarus/const/utilities.dart';
import 'package:json_annotation/json_annotation.dart';

part "placed_classes.g.dart";

Offset getFlippedPosition({
  required Offset position,
  required Offset scaledSize,
  bool isRotatable = false,
}) {
  final coordinateSystem = CoordinateSystem.instance;
  final wNorm = (scaledSize.dx / coordinateSystem.effectiveSize.width) *
      coordinateSystem.worldNormalizedWidth;
  final hNorm = (scaledSize.dy / coordinateSystem.effectiveSize.height) *
      coordinateSystem.normalizedHeight;
  final flippedX = coordinateSystem.worldNormalizedWidth - position.dx - wNorm;
  double flippedY = 0;

  if (isRotatable) {
    // Rotatable widgets are rendered with a different anchor (their visual
    // bounds shift when rotated/flipped). To keep their perceived position
    // consistent after flipping, we need to compensate for the extra vertical
    // offset introduced by rotation by subtracting the normalized height a
    // second time.
    flippedY = coordinateSystem.normalizedHeight - position.dy - hNorm - hNorm;
  } else {
    flippedY = coordinateSystem.normalizedHeight - position.dy - hNorm;
  }

  return Offset(flippedX, flippedY);
}

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
  PlacedText({
    required super.position,
    required super.id,
    this.size = 200,
    this.tagColorValue,
  });

  String text = "";
  double size;

  @JsonKey(defaultValue: null)
  int? tagColorValue;

  void commitText(String nextText) {
    final action = TextContentAction(text: text);
    _actionHistory.add(action);
    _poppedAction.clear();
    text = nextText;
  }

  void _undoText() {
    final action = TextContentAction(text: text);

    _poppedAction.add(action);
    text = (_actionHistory.last as TextContentAction).text;
    _actionHistory.removeLast();
  }

  void _redoText() {
    final action = TextContentAction(text: text);

    _actionHistory.add(action);
    text = (_poppedAction.last as TextContentAction).text;
    _poppedAction.removeLast();
  }

  @override
  void undoAction() {
    if (_actionHistory.isEmpty) return;

    if (_actionHistory.last is PositionAction) {
      _undoPosition();
    } else if (_actionHistory.last is TextContentAction) {
      _undoText();
    }
  }

  @override
  void redoAction() {
    if (_poppedAction.isEmpty) return;

    if (_poppedAction.last is PositionAction) {
      _redoPosition();
    } else if (_poppedAction.last is TextContentAction) {
      _redoText();
    }
  }

  factory PlacedText.fromJson(Map<String, dynamic> json) =>
      _$PlacedTextFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$PlacedTextToJson(this);

  void switchSides(Offset size) {
    position = getFlippedPosition(position: position, scaledSize: size);

    for (final (index, action) in _actionHistory.indexed) {
      if (action is PositionAction) {
        _actionHistory[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position, scaledSize: size));
      }
    }
    for (final (index, action) in _poppedAction.indexed) {
      if (action is PositionAction) {
        _poppedAction[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position, scaledSize: size));
      }
    }
  }
}

@JsonSerializable()
class PlacedImage extends PlacedWidget {
  PlacedImage({
    required super.position,
    required super.id,
    required this.aspectRatio,
    required this.scale,
    required this.fileExtension,
    this.tagColorValue,
  });

  final double aspectRatio;

  final String? fileExtension;
  double scale;

  @JsonKey(defaultValue: null)
  int? tagColorValue;

  String link = "";

  void updateLink(String link) {
    this.link = link;
  }

  void updateTagColor(int? colorValue) {
    tagColorValue = colorValue;
  }

  void switchSides(Offset size) {
    position = getFlippedPosition(position: position, scaledSize: size);

    for (final (index, action) in _actionHistory.indexed) {
      if (action is PositionAction) {
        _actionHistory[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position, scaledSize: size));
      }
    }
    for (final (index, action) in _poppedAction.indexed) {
      if (action is PositionAction) {
        _poppedAction[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position, scaledSize: size));
      }
    }
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
    int? tagColorValue,
    bool? isDeleted,
    String? link,
  }) {
    final cloned = PlacedImage(
      position: position ?? this.position,
      id: id ?? this.id,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      scale: scale ?? this.scale,
      fileExtension: fileExtension ?? this.fileExtension,
      tagColorValue: tagColorValue ?? this.tagColorValue,
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

  @JsonKey(defaultValue: AgentState.none)
  AgentState state;

  final String? lineUpID;

  PlacedAgent({
    required this.type,
    required super.position,
    required super.id,
    this.isAlly = true, // Default parameter value
    this.lineUpID,
    this.state = AgentState.none,
  });

  factory PlacedAgent.fromJson(Map<String, dynamic> json) =>
      _$PlacedAgentFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$PlacedAgentToJson(this);

  void switchSides(double agentSize) {
    final coordinateSystem = CoordinateSystem.instance;
    final agentScreenPx = coordinateSystem.scale(agentSize);

    position = getFlippedPosition(
        position: position, scaledSize: Offset(agentScreenPx, agentScreenPx));

    for (final (index, action) in _actionHistory.indexed) {
      if (action is PositionAction) {
        _actionHistory[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position,
                scaledSize: Offset(agentScreenPx, agentScreenPx)));
      }
    }
    for (final (index, action) in _poppedAction.indexed) {
      if (action is PositionAction) {
        _poppedAction[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position,
                scaledSize: Offset(agentScreenPx, agentScreenPx)));
      }
    }
  }

  PlacedAgent copyWith({
    AgentType? type,
    Offset? position,
    String? id,
    bool? isAlly,
    String? lineUpID,
    AgentState? state,
  }) {
    return PlacedAgent(
      type: type ?? this.type,
      position: position ?? this.position,
      id: id ?? this.id,
      isAlly: isAlly ?? this.isAlly,
      lineUpID: lineUpID ?? this.lineUpID,
      state: state ?? this.state,
    );
  }
}

@JsonSerializable()
class PlacedAbility extends PlacedWidget {
  PlacedAbility({
    required this.data,
    required super.position,
    required super.id,
    this.isAlly = true,
    this.length = 0,
    this.lineUpID,
    this.rotation = 0,
  });

  @AbilityInfoConverter()
  final AbilityInfo data;

  @JsonKey(defaultValue: true)
  final bool isAlly;

  double rotation;

  double length;

  final String? lineUpID;

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

  void switchSides({required double mapScale, required double abilitySize}) {
    final fullAbilityWidgetSize =
        data.abilityData!.getSize(mapScale: mapScale, abilitySize: abilitySize);

    final scaledAbilitySize = fullAbilityWidgetSize.scale(
        CoordinateSystem.instance.scaleFactor,
        CoordinateSystem.instance.scaleFactor);

    Offset flippedPosition = getFlippedPosition(
        position: position,
        scaledSize: scaledAbilitySize,
        isRotatable: isRotatable(data.abilityData!));
    position = flippedPosition;

    if (isRotatable(data.abilityData!)) {
      rotation = rotation + math.pi;
    }

    for (final (index, action) in _actionHistory.indexed) {
      if (action is PositionAction) {
        _actionHistory[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position,
                scaledSize: scaledAbilitySize,
                isRotatable: isRotatable(data.abilityData!)));
      } else if (action is RotationAction) {
        _actionHistory[index] = action.copyWith(
            rotation: action.rotation + math.pi, length: action.length);
      }
    }

    for (final (index, action) in _poppedAction.indexed) {
      if (action is PositionAction) {
        _poppedAction[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position,
                scaledSize: scaledAbilitySize,
                isRotatable: isRotatable(data.abilityData!)));
      } else if (action is RotationAction) {
        _poppedAction[index] = action.copyWith(
            rotation: action.rotation + math.pi, length: action.length);
      }
    }
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

  PlacedAbility copyWith({
    AbilityInfo? data,
    Offset? position,
    double? rotation,
    double? length,
    String? id,
    bool? isAlly,
    String? lineUpID,
  }) {
    return PlacedAbility(
      id: id ?? this.id,
      data: data ?? this.data,
      position: position ?? this.position,
      isAlly: isAlly ?? this.isAlly,
      lineUpID: lineUpID ?? this.lineUpID,
      length: length ?? this.length,
      rotation: rotation ?? this.rotation,
    );
  }

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
  RotationAction copyWith({double? rotation, double? length}) {
    return RotationAction(
      rotation: rotation ?? this.rotation,
      length: length ?? this.length,
    );
  }
}

class PositionAction extends WidgetAction {
  final Offset position;

  PositionAction({required this.position});

  PositionAction copyWith({Offset? position}) {
    return PositionAction(position: position ?? this.position);
  }
}

class CustomShapeGeometryAction extends WidgetAction {
  final Offset position;
  final double? customDiameter;
  final double? customWidth;
  final double? customLength;

  CustomShapeGeometryAction({
    required this.position,
    required this.customDiameter,
    required this.customWidth,
    required this.customLength,
  });

  CustomShapeGeometryAction copyWith({
    Offset? position,
    double? customDiameter,
    double? customWidth,
    double? customLength,
  }) {
    return CustomShapeGeometryAction(
      position: position ?? this.position,
      customDiameter: customDiameter ?? this.customDiameter,
      customWidth: customWidth ?? this.customWidth,
      customLength: customLength ?? this.customLength,
    );
  }
}

class TextContentAction extends WidgetAction {
  final String text;

  TextContentAction({required this.text});
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

  _getIsRotationUtility(UtilityType type) {
    return UtilityData.isViewCone(type);
  }

  Offset _getEffectiveUtilitySize({required double mapScale}) {
    final utility = UtilityData.utilityWidgets[type]!;
    if (type == UtilityType.customCircle) {
      assert(customDiameter != null,
          'customDiameter is required for custom circle utility.');
      if (customDiameter == null) {
        return Offset.zero;
      }
      return utility.getSize(
          diameterMeters: customDiameter, mapScale: mapScale);
    }
    if (type == UtilityType.customRectangle) {
      assert(customWidth != null && customLength != null,
          'customWidth and customLength are required for custom rectangle utility.');
      if (customWidth == null || customLength == null) {
        return Offset.zero;
      }
      return utility.getSize(
        widthMeters: customWidth,
        rectLengthMeters: customLength,
        mapScale: mapScale,
      );
    }
    return utility.getSize();
  }

  void switchSides({required double mapScale}) {
    final size = _getEffectiveUtilitySize(mapScale: mapScale);
    final scaledSize = size.scale(CoordinateSystem.instance.scaleFactor,
        CoordinateSystem.instance.scaleFactor);

    final flippedPosition = getFlippedPosition(
        position: position,
        scaledSize: scaledSize,
        isRotatable: _getIsRotationUtility(type));

    position = flippedPosition;

    if (_getIsRotationUtility(type)) {
      rotation = rotation + math.pi;
    }

    for (final (index, action) in _actionHistory.indexed) {
      if (action is PositionAction) {
        Offset actionFlippedPosition = getFlippedPosition(
            position: action.position,
            scaledSize: scaledSize,
            isRotatable: _getIsRotationUtility(type));

        _actionHistory[index] =
            action.copyWith(position: actionFlippedPosition);
      } else if (action is RotationAction) {
        _actionHistory[index] =
            action.copyWith(rotation: action.rotation + math.pi);
      } else if (action is CustomShapeGeometryAction) {
        final actionFlippedPosition = getFlippedPosition(
            position: action.position,
            scaledSize: scaledSize,
            isRotatable: _getIsRotationUtility(type));
        _actionHistory[index] =
            action.copyWith(position: actionFlippedPosition);
      }
    }
    for (final (index, action) in _poppedAction.indexed) {
      if (action is PositionAction) {
        Offset actionFlippedPosition = getFlippedPosition(
            position: action.position,
            scaledSize: scaledSize,
            isRotatable: _getIsRotationUtility(type));

        _poppedAction[index] = action.copyWith(position: actionFlippedPosition);
      } else if (action is RotationAction) {
        _poppedAction[index] =
            action.copyWith(rotation: action.rotation + math.pi);
      } else if (action is CustomShapeGeometryAction) {
        final actionFlippedPosition = getFlippedPosition(
            position: action.position,
            scaledSize: scaledSize,
            isRotatable: _getIsRotationUtility(type));
        _poppedAction[index] = action.copyWith(position: actionFlippedPosition);
      }
    }
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

  void updateCustomShapeGeometry({
    Offset? newPosition,
    double? newDiameter,
    double? newWidth,
    double? newLength,
  }) {
    final action = CustomShapeGeometryAction(
      position: position,
      customDiameter: customDiameter,
      customWidth: customWidth,
      customLength: customLength,
    );
    _actionHistory.add(action);
    position = newPosition ?? position;
    customDiameter = newDiameter ?? customDiameter;
    customWidth = newWidth ?? customWidth;
    customLength = newLength ?? customLength;
  }

  void updateCustomShapeSize({
    double? newDiameter,
    double? newWidth,
    double? newLength,
  }) {
    updateCustomShapeGeometry(
      newDiameter: newDiameter,
      newWidth: newWidth,
      newLength: newLength,
    );
  }

  void _undoCustomShapeGeometry() {
    final action = CustomShapeGeometryAction(
      position: position,
      customDiameter: customDiameter,
      customWidth: customWidth,
      customLength: customLength,
    );

    _poppedAction.add(action);
    final previous = _actionHistory.last as CustomShapeGeometryAction;
    position = previous.position;
    customDiameter = previous.customDiameter;
    customWidth = previous.customWidth;
    customLength = previous.customLength;
    _actionHistory.removeLast();
  }

  void _redoCustomShapeGeometry() {
    if (_poppedAction.isEmpty) return;

    final action = CustomShapeGeometryAction(
      position: position,
      customDiameter: customDiameter,
      customWidth: customWidth,
      customLength: customLength,
    );

    _actionHistory.add(action);
    final next = _poppedAction.last as CustomShapeGeometryAction;
    position = next.position;
    customDiameter = next.customDiameter;
    customWidth = next.customWidth;
    customLength = next.customLength;
    _poppedAction.removeLast();
  }

  @override
  void undoAction() {
    if (_actionHistory.isEmpty) return;

    if (_actionHistory.last is PositionAction) {
      _undoPosition();
    } else if (_actionHistory.last is RotationAction) {
      _undoRotation();
    } else if (_actionHistory.last is CustomShapeGeometryAction) {
      _undoCustomShapeGeometry();
    }
  }

  @override
  void redoAction() {
    if (_poppedAction.isEmpty) return;

    if (_poppedAction.last is PositionAction) {
      _redoPosition();
    } else if (_poppedAction.last is RotationAction) {
      _redoRotation();
    } else if (_poppedAction.last is CustomShapeGeometryAction) {
      _redoCustomShapeGeometry();
    }
  }

  @JsonKey(defaultValue: 0.0)
  double angle;

  @JsonKey(defaultValue: null)
  String? attachedAgentId;

  @JsonKey(defaultValue: null)
  double? customDiameter;

  @JsonKey(defaultValue: null)
  double? customWidth;

  @JsonKey(defaultValue: null)
  double? customLength;

  @JsonKey(defaultValue: null)
  int? customColorValue;

  @JsonKey(defaultValue: null)
  int? customOpacityPercent;

  PlacedUtility({
    required this.type,
    required super.position,
    required super.id,
    this.angle = 0.0,
    this.attachedAgentId,
    this.customDiameter,
    this.customWidth,
    this.customLength,
    this.customColorValue,
    this.customOpacityPercent,
  });

  factory PlacedUtility.fromJson(Map<String, dynamic> json) =>
      _$PlacedUtilityFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$PlacedUtilityToJson(this);
}
// ...existing code...

// Add this at the end of the file
extension PlacedWidgetCopy on PlacedWidget {
  T deepCopy<T extends PlacedWidget>() {
    final json = toJson();

    if (this is PlacedText) {
      return PlacedText.fromJson(json) as T;
    } else if (this is PlacedImage) {
      return PlacedImage.fromJson(json) as T;
    } else if (this is PlacedAgent) {
      return PlacedAgent.fromJson(json) as T;
    } else if (this is PlacedAbility) {
      return PlacedAbility.fromJson(json) as T;
    } else if (this is PlacedUtility) {
      return PlacedUtility.fromJson(json) as T;
    } else {
      return PlacedWidget.fromJson(json) as T;
    }
  }
}
