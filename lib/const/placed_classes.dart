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

sealed class PlacedAgentNode extends PlacedWidget {
  static const String plainKind = 'plain';
  static const String viewConeKind = 'viewCone';
  static const String circleKind = 'circle';

  @AgentTypeCompatConverter()
  final AgentType type;

  @JsonKey(defaultValue: true)
  bool isAlly;

  @AgentStateCompatConverter()
  @JsonKey(defaultValue: AgentState.none)
  AgentState state;

  PlacedAgentNode({
    required this.type,
    required super.position,
    required super.id,
    this.isAlly = true,
    this.state = AgentState.none,
  });

  String get kind;

  void switchSides(double agentSize) {
    final coordinateSystem = CoordinateSystem.instance;
    final agentScreenPx = coordinateSystem.scale(agentSize);
    final scaledSize = Offset(agentScreenPx, agentScreenPx);

    position = getFlippedPosition(position: position, scaledSize: scaledSize);
    _flipSharedPositionHistory(scaledSize);
  }

  void _flipSharedPositionHistory(Offset scaledSize) {
    for (final (index, action) in _actionHistory.indexed) {
      if (action is PositionAction) {
        _actionHistory[index] = action.copyWith(
          position: getFlippedPosition(
            position: action.position,
            scaledSize: scaledSize,
          ),
        );
      }
    }
    for (final (index, action) in _poppedAction.indexed) {
      if (action is PositionAction) {
        _poppedAction[index] = action.copyWith(
          position: getFlippedPosition(
            position: action.position,
            scaledSize: scaledSize,
          ),
        );
      }
    }
  }

  factory PlacedAgentNode.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String? ?? plainKind;
    switch (kind) {
      case viewConeKind:
        return PlacedViewConeAgent.fromJson(json);
      case circleKind:
        return PlacedCircleAgent.fromJson(json);
      case plainKind:
      default:
        return PlacedAgent.fromJson(json);
    }
  }
}

class PlacedAgentNodeConverter
    implements JsonConverter<PlacedAgentNode, Map<String, dynamic>> {
  const PlacedAgentNodeConverter();

  @override
  PlacedAgentNode fromJson(Map<String, dynamic> json) {
    return PlacedAgentNode.fromJson(json);
  }

  @override
  Map<String, dynamic> toJson(PlacedAgentNode object) {
    return object.toJson();
  }
}

@JsonSerializable()
class PlacedAgent extends PlacedAgentNode {
  final String? lineUpID;

  PlacedAgent({
    required super.type,
    required super.position,
    required super.id,
    super.isAlly = true,
    this.lineUpID,
    super.state = AgentState.none,
  });

  @override
  String get kind => PlacedAgentNode.plainKind;

  factory PlacedAgent.fromJson(Map<String, dynamic> json) =>
      _$PlacedAgentFromJson(json);

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        ..._$PlacedAgentToJson(this),
      };

  PlacedAgent copyWith({
    AgentType? type,
    Offset? position,
    String? id,
    bool? isAlly,
    String? lineUpID,
    AgentState? state,
  }) {
    final copied = PlacedAgent(
      type: type ?? this.type,
      position: position ?? this.position,
      id: id ?? this.id,
      isAlly: isAlly ?? this.isAlly,
      lineUpID: lineUpID ?? this.lineUpID,
      state: state ?? this.state,
    );
    copied.isDeleted = isDeleted;
    return copied;
  }
}

class ViewConeAgentGeometryAction extends WidgetAction {
  final double rotation;
  final double length;

  ViewConeAgentGeometryAction({
    required this.rotation,
    required this.length,
  });

  ViewConeAgentGeometryAction copyWith({
    double? rotation,
    double? length,
  }) {
    return ViewConeAgentGeometryAction(
      rotation: rotation ?? this.rotation,
      length: length ?? this.length,
    );
  }
}

class CircleAgentGeometryAction extends WidgetAction {
  final double diameterMeters;
  final int colorValue;
  final int opacityPercent;

  CircleAgentGeometryAction({
    required this.diameterMeters,
    required this.colorValue,
    required this.opacityPercent,
  });
}

@JsonSerializable()
class PlacedViewConeAgent extends PlacedAgentNode {
  @UtilityTypeCompatConverter()
  final UtilityType presetType;
  double rotation;
  double length;

  PlacedViewConeAgent({
    required super.type,
    required super.position,
    required super.id,
    required this.presetType,
    this.rotation = 0,
    this.length = 0,
    super.isAlly = true,
    super.state = AgentState.none,
  }) : assert(
          UtilityData.isViewConePresetType(presetType),
          'presetType must be a view cone preset.',
        );

  @override
  String get kind => PlacedAgentNode.viewConeKind;

  factory PlacedViewConeAgent.fromJson(Map<String, dynamic> json) =>
      _$PlacedViewConeAgentFromJson(json);

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        ..._$PlacedViewConeAgentToJson(this),
      };

  void updateGeometryHistory() {
    _actionHistory.add(
      ViewConeAgentGeometryAction(rotation: rotation, length: length),
    );
  }

  void updateGeometry({
    required double newRotation,
    required double newLength,
  }) {
    rotation = newRotation;
    length = newLength;
  }

  void _undoGeometry() {
    final action =
        ViewConeAgentGeometryAction(rotation: rotation, length: length);
    _poppedAction.add(action);
    final previous = _actionHistory.last as ViewConeAgentGeometryAction;
    rotation = previous.rotation;
    length = previous.length;
    _actionHistory.removeLast();
  }

  void _redoGeometry() {
    final action =
        ViewConeAgentGeometryAction(rotation: rotation, length: length);
    _actionHistory.add(action);
    final next = _poppedAction.last as ViewConeAgentGeometryAction;
    rotation = next.rotation;
    length = next.length;
    _poppedAction.removeLast();
  }

  @override
  void undoAction() {
    if (_actionHistory.isEmpty) return;
    if (_actionHistory.last is PositionAction) {
      _undoPosition();
    } else if (_actionHistory.last is ViewConeAgentGeometryAction) {
      _undoGeometry();
    }
  }

  @override
  void redoAction() {
    if (_poppedAction.isEmpty) return;
    if (_poppedAction.last is PositionAction) {
      _redoPosition();
    } else if (_poppedAction.last is ViewConeAgentGeometryAction) {
      _redoGeometry();
    }
  }

  @override
  void switchSides(double agentSize) {
    super.switchSides(agentSize);
    rotation = rotation + math.pi;

    for (final (index, action) in _actionHistory.indexed) {
      if (action is ViewConeAgentGeometryAction) {
        _actionHistory[index] = action.copyWith(
          rotation: action.rotation + math.pi,
        );
      }
    }
    for (final (index, action) in _poppedAction.indexed) {
      if (action is ViewConeAgentGeometryAction) {
        _poppedAction[index] = action.copyWith(
          rotation: action.rotation + math.pi,
        );
      }
    }
  }

  PlacedViewConeAgent copyWith({
    AgentType? type,
    Offset? position,
    String? id,
    bool? isAlly,
    AgentState? state,
    UtilityType? presetType,
    double? rotation,
    double? length,
  }) {
    final copied = PlacedViewConeAgent(
      type: type ?? this.type,
      position: position ?? this.position,
      id: id ?? this.id,
      isAlly: isAlly ?? this.isAlly,
      state: state ?? this.state,
      presetType: presetType ?? this.presetType,
      rotation: rotation ?? this.rotation,
      length: length ?? this.length,
    );
    copied.isDeleted = isDeleted;
    return copied;
  }
}

@JsonSerializable()
class PlacedCircleAgent extends PlacedAgentNode {
  double diameterMeters;
  int colorValue;
  int opacityPercent;

  PlacedCircleAgent({
    required super.type,
    required super.position,
    required super.id,
    this.diameterMeters = 0,
    this.colorValue = 0xFFFFFFFF,
    this.opacityPercent = 100,
    super.isAlly = true,
    super.state = AgentState.none,
  });

  @override
  String get kind => PlacedAgentNode.circleKind;

  factory PlacedCircleAgent.fromJson(Map<String, dynamic> json) =>
      _$PlacedCircleAgentFromJson(json);

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        ..._$PlacedCircleAgentToJson(this),
      };

  void updateGeometry({
    required double newDiameterMeters,
    required int newColorValue,
    required int newOpacityPercent,
  }) {
    diameterMeters = newDiameterMeters;
    colorValue = newColorValue;
    opacityPercent = newOpacityPercent;
  }

  void updateGeometryHistory() {
    _actionHistory.add(
      CircleAgentGeometryAction(
        diameterMeters: diameterMeters,
        colorValue: colorValue,
        opacityPercent: opacityPercent,
      ),
    );
  }

  void _undoGeometry() {
    _poppedAction.add(
      CircleAgentGeometryAction(
        diameterMeters: diameterMeters,
        colorValue: colorValue,
        opacityPercent: opacityPercent,
      ),
    );
    final previous = _actionHistory.last as CircleAgentGeometryAction;
    diameterMeters = previous.diameterMeters;
    colorValue = previous.colorValue;
    opacityPercent = previous.opacityPercent;
    _actionHistory.removeLast();
  }

  void _redoGeometry() {
    _actionHistory.add(
      CircleAgentGeometryAction(
        diameterMeters: diameterMeters,
        colorValue: colorValue,
        opacityPercent: opacityPercent,
      ),
    );
    final next = _poppedAction.last as CircleAgentGeometryAction;
    diameterMeters = next.diameterMeters;
    colorValue = next.colorValue;
    opacityPercent = next.opacityPercent;
    _poppedAction.removeLast();
  }

  @override
  void undoAction() {
    if (_actionHistory.isEmpty) return;
    if (_actionHistory.last is PositionAction) {
      _undoPosition();
    } else if (_actionHistory.last is CircleAgentGeometryAction) {
      _undoGeometry();
    }
  }

  @override
  void redoAction() {
    if (_poppedAction.isEmpty) return;
    if (_poppedAction.last is PositionAction) {
      _redoPosition();
    } else if (_poppedAction.last is CircleAgentGeometryAction) {
      _redoGeometry();
    }
  }

  PlacedCircleAgent copyWith({
    AgentType? type,
    Offset? position,
    String? id,
    bool? isAlly,
    AgentState? state,
    double? diameterMeters,
    int? colorValue,
    int? opacityPercent,
  }) {
    final copied = PlacedCircleAgent(
      type: type ?? this.type,
      position: position ?? this.position,
      id: id ?? this.id,
      isAlly: isAlly ?? this.isAlly,
      state: state ?? this.state,
      diameterMeters: diameterMeters ?? this.diameterMeters,
      colorValue: colorValue ?? this.colorValue,
      opacityPercent: opacityPercent ?? this.opacityPercent,
    );
    copied.isDeleted = isDeleted;
    return copied;
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
    List<double>? armLengthsMeters,
  }) : armLengthsMeters = DeadlockBarrierMeshAbility.normalizeArmLengths(
          armLengthsMeters,
        );

  @AbilityInfoConverter()
  final AbilityInfo data;

  @JsonKey(defaultValue: true)
  final bool isAlly;

  double rotation;

  double length;

  final String? lineUpID;

  @JsonKey(defaultValue: <double>[10.0, 10.0, 10.0, 10.0])
  List<double> armLengthsMeters;

  void updateRotation(double newRotation, double newLength) {
    updateGeometry(newRotation: newRotation, newLength: newLength);
  }

  void updateGeometry({
    double? newRotation,
    double? newLength,
    List<double>? newArmLengthsMeters,
  }) {
    rotation = newRotation ?? rotation;
    length = newLength ?? length;
    armLengthsMeters = DeadlockBarrierMeshAbility.normalizeArmLengths(
      newArmLengthsMeters ?? armLengthsMeters,
    );
  }

  void updateArmLengths(List<double> newArmLengthsMeters) {
    updateGeometry(newArmLengthsMeters: newArmLengthsMeters);
  }

  void updateRotationHistory() {
    updateGeometryHistory();
  }

  void updateGeometryHistory() {
    final action = AbilityGeometryAction(
      rotation: rotation,
      length: length,
      armLengthsMeters: armLengthsMeters,
    );
    _actionHistory.add(action);
  }

  void _undoGeometry() {
    final action = AbilityGeometryAction(
      rotation: rotation,
      length: length,
      armLengthsMeters: armLengthsMeters,
    );

    _poppedAction.add(action);
    final previous = _actionHistory.last as AbilityGeometryAction;
    rotation = previous.rotation;
    length = previous.length;
    armLengthsMeters = List<double>.from(previous.armLengthsMeters);
    _actionHistory.removeLast();
  }

  void _redoGeometry() {
    if (_poppedAction.isEmpty) return;

    final action = AbilityGeometryAction(
      rotation: rotation,
      length: length,
      armLengthsMeters: armLengthsMeters,
    );

    _actionHistory.add(action);
    final next = _poppedAction.last as AbilityGeometryAction;
    rotation = next.rotation;
    length = next.length;
    armLengthsMeters = List<double>.from(next.armLengthsMeters);
    _poppedAction.removeLast();
  }

  void switchSides({required double mapScale, required double abilitySize}) {
    final fullAbilityWidgetSize =
        data.abilityData!.getSize(mapScale: mapScale, abilitySize: abilitySize);
    final abilityData = data.abilityData!;
    final shouldRotate = isRotatable(abilityData);
    final shouldUseRotatableFlipCompensation =
        shouldRotate && abilityData is! DeadlockBarrierMeshAbility;

    final scaledAbilitySize = fullAbilityWidgetSize.scale(
        CoordinateSystem.instance.scaleFactor,
        CoordinateSystem.instance.scaleFactor);

    Offset flippedPosition = getFlippedPosition(
        position: position,
        scaledSize: scaledAbilitySize,
        isRotatable: shouldUseRotatableFlipCompensation);
    position = flippedPosition;

    if (shouldRotate) {
      rotation = rotation + math.pi;
    }

    for (final (index, action) in _actionHistory.indexed) {
      if (action is PositionAction) {
        _actionHistory[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position,
                scaledSize: scaledAbilitySize,
                isRotatable: shouldUseRotatableFlipCompensation));
      } else if (action is AbilityGeometryAction) {
        _actionHistory[index] = action.copyWith(
          rotation: shouldRotate ? action.rotation + math.pi : action.rotation,
        );
      }
    }

    for (final (index, action) in _poppedAction.indexed) {
      if (action is PositionAction) {
        _poppedAction[index] = action.copyWith(
            position: getFlippedPosition(
                position: action.position,
                scaledSize: scaledAbilitySize,
                isRotatable: shouldUseRotatableFlipCompensation));
      } else if (action is AbilityGeometryAction) {
        _poppedAction[index] = action.copyWith(
          rotation: shouldRotate ? action.rotation + math.pi : action.rotation,
        );
      }
    }
  }

  @override
  void undoAction() {
    if (_actionHistory.isEmpty) return;

    if (_actionHistory.last is PositionAction) {
      _undoPosition();
    } else if (_actionHistory.last is AbilityGeometryAction) {
      _undoGeometry();
    }
  }

  @override
  void redoAction() {
    if (_poppedAction.isEmpty) return;

    if (_poppedAction.last is PositionAction) {
      _redoPosition();
    } else if (_poppedAction.last is AbilityGeometryAction) {
      _redoGeometry();
    }
  }

  PlacedAbility copyWith({
    AbilityInfo? data,
    Offset? position,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
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
      armLengthsMeters: List<double>.from(
        armLengthsMeters ?? this.armLengthsMeters,
      ),
    );
  }

  factory PlacedAbility.fromJson(Map<String, dynamic> json) =>
      _$PlacedAbilityFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$PlacedAbilityToJson(this);
}

abstract class WidgetAction {}

class AbilityGeometryAction extends WidgetAction {
  final double rotation;
  final double length;
  final List<double> armLengthsMeters;

  AbilityGeometryAction({
    required this.rotation,
    required this.length,
    required List<double> armLengthsMeters,
  }) : armLengthsMeters = List<double>.from(armLengthsMeters);

  AbilityGeometryAction copyWith({
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
  }) {
    return AbilityGeometryAction(
      rotation: rotation ?? this.rotation,
      length: length ?? this.length,
      armLengthsMeters: armLengthsMeters ?? this.armLengthsMeters,
    );
  }
}

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

  void switchSides({
    required double mapScale,
  }) {
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

  static const Object _noChange = Object();

  PlacedUtility copyWith({
    UtilityType? type,
    Offset? position,
    String? id,
    double? angle,
    Object? customDiameter = _noChange,
    Object? customWidth = _noChange,
    Object? customLength = _noChange,
    Object? customColorValue = _noChange,
    Object? customOpacityPercent = _noChange,
    double? rotation,
    double? length,
    bool? isDeleted,
  }) {
    final copied = PlacedUtility(
      type: type ?? this.type,
      position: position ?? this.position,
      id: id ?? this.id,
      angle: angle ?? this.angle,
      customDiameter: identical(customDiameter, _noChange)
          ? this.customDiameter
          : customDiameter as double?,
      customWidth: identical(customWidth, _noChange)
          ? this.customWidth
          : customWidth as double?,
      customLength: identical(customLength, _noChange)
          ? this.customLength
          : customLength as double?,
      customColorValue: identical(customColorValue, _noChange)
          ? this.customColorValue
          : customColorValue as int?,
      customOpacityPercent: identical(customOpacityPercent, _noChange)
          ? this.customOpacityPercent
          : customOpacityPercent as int?,
    );
    copied.rotation = rotation ?? this.rotation;
    copied.length = length ?? this.length;
    copied.isDeleted = isDeleted ?? this.isDeleted;
    return copied;
  }
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
    } else if (this is PlacedViewConeAgent) {
      return PlacedViewConeAgent.fromJson(json) as T;
    } else if (this is PlacedCircleAgent) {
      return PlacedCircleAgent.fromJson(json) as T;
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

  /// Agent/utility bulk-delete and transaction snapshots need preserved
  /// undo/redo stacks. `deepCopy()` intentionally drops that JSON-excluded
  /// state, while the other providers still rely on shallow list snapshots.
  T snapshotCopy<T extends PlacedWidget>() {
    final copied = _snapshotCloneWidget();
    _copyHistoryTo(copied);
    return copied as T;
  }

  PlacedWidget _snapshotCloneWidget() {
    if (this is PlacedAgent) {
      return (this as PlacedAgent).copyWith();
    } else if (this is PlacedViewConeAgent) {
      return (this as PlacedViewConeAgent).copyWith();
    } else if (this is PlacedCircleAgent) {
      return (this as PlacedCircleAgent).copyWith();
    } else if (this is PlacedUtility) {
      return (this as PlacedUtility).copyWith();
    }

    throw UnsupportedError(
      'Snapshot copy is only supported for agent and utility widgets.',
    );
  }

  void _copyHistoryTo(PlacedWidget target) {
    target._actionHistory.addAll(_actionHistory.map(_cloneWidgetAction));
    target._poppedAction.addAll(_poppedAction.map(_cloneWidgetAction));
  }

  WidgetAction _cloneWidgetAction(WidgetAction action) {
    if (action is PositionAction) {
      return PositionAction(position: action.position);
    } else if (action is ViewConeAgentGeometryAction) {
      return ViewConeAgentGeometryAction(
        rotation: action.rotation,
        length: action.length,
      );
    } else if (action is CircleAgentGeometryAction) {
      return CircleAgentGeometryAction(
        diameterMeters: action.diameterMeters,
        colorValue: action.colorValue,
        opacityPercent: action.opacityPercent,
      );
    } else if (action is RotationAction) {
      return RotationAction(rotation: action.rotation, length: action.length);
    } else if (action is CustomShapeGeometryAction) {
      return CustomShapeGeometryAction(
        position: action.position,
        customDiameter: action.customDiameter,
        customWidth: action.customWidth,
        customLength: action.customLength,
      );
    }

    throw UnsupportedError(
      'Unsupported action type ${action.runtimeType} for snapshot copying.',
    );
  }
}
