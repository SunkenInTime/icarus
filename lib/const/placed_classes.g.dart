// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'placed_classes.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PlacedWidget _$PlacedWidgetFromJson(Map<String, dynamic> json) => PlacedWidget(
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      isDeleted: json['isDeleted'] as bool? ?? false,
    );

Map<String, dynamic> _$PlacedWidgetToJson(PlacedWidget instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
    };

PlacedText _$PlacedTextFromJson(Map<String, dynamic> json) => PlacedText(
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      size: (json['size'] as num?)?.toDouble() ?? 200,
      tagColorValue: (json['tagColorValue'] as num?)?.toInt(),
    )
      ..isDeleted = json['isDeleted'] as bool? ?? false
      ..text = json['text'] as String;

Map<String, dynamic> _$PlacedTextToJson(PlacedText instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'text': instance.text,
      'size': instance.size,
      'tagColorValue': instance.tagColorValue,
    };

PlacedImage _$PlacedImageFromJson(Map<String, dynamic> json) => PlacedImage(
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      aspectRatio: (json['aspectRatio'] as num).toDouble(),
      scale: (json['scale'] as num).toDouble(),
      fileExtension: json['fileExtension'] as String?,
      tagColorValue: (json['tagColorValue'] as num?)?.toInt(),
    )
      ..isDeleted = json['isDeleted'] as bool? ?? false
      ..link = json['link'] as String;

Map<String, dynamic> _$PlacedImageToJson(PlacedImage instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'aspectRatio': instance.aspectRatio,
      'fileExtension': instance.fileExtension,
      'scale': instance.scale,
      'tagColorValue': instance.tagColorValue,
      'link': instance.link,
    };

PlacedAgent _$PlacedAgentFromJson(Map<String, dynamic> json) => PlacedAgent(
      type: const AgentTypeCompatConverter().fromJson(json['type']),
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      isAlly: json['isAlly'] as bool? ?? true,
      lineUpID: json['lineUpID'] as String?,
      state: json['state'] == null
          ? AgentState.none
          : const AgentStateCompatConverter().fromJson(json['state']),
    )..isDeleted = json['isDeleted'] as bool? ?? false;

Map<String, dynamic> _$PlacedAgentToJson(PlacedAgent instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'type': const AgentTypeCompatConverter().toJson(instance.type),
      'isAlly': instance.isAlly,
      'state': const AgentStateCompatConverter().toJson(instance.state),
      'lineUpID': instance.lineUpID,
    };

PlacedViewConeAgent _$PlacedViewConeAgentFromJson(Map<String, dynamic> json) =>
    PlacedViewConeAgent(
      type: const AgentTypeCompatConverter().fromJson(json['type']),
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      presetType:
          const UtilityTypeCompatConverter().fromJson(json['presetType']),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      length: (json['length'] as num?)?.toDouble() ?? 0,
      isAlly: json['isAlly'] as bool? ?? true,
      state: json['state'] == null
          ? AgentState.none
          : const AgentStateCompatConverter().fromJson(json['state']),
    )..isDeleted = json['isDeleted'] as bool? ?? false;

Map<String, dynamic> _$PlacedViewConeAgentToJson(
        PlacedViewConeAgent instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'type': const AgentTypeCompatConverter().toJson(instance.type),
      'isAlly': instance.isAlly,
      'state': const AgentStateCompatConverter().toJson(instance.state),
      'presetType':
          const UtilityTypeCompatConverter().toJson(instance.presetType),
      'rotation': instance.rotation,
      'length': instance.length,
    };

PlacedCircleAgent _$PlacedCircleAgentFromJson(Map<String, dynamic> json) =>
    PlacedCircleAgent(
      type: const AgentTypeCompatConverter().fromJson(json['type']),
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      diameterMeters: (json['diameterMeters'] as num?)?.toDouble() ?? 0,
      colorValue: (json['colorValue'] as num?)?.toInt() ?? 0xFFFFFFFF,
      opacityPercent: (json['opacityPercent'] as num?)?.toInt() ?? 100,
      isAlly: json['isAlly'] as bool? ?? true,
      state: json['state'] == null
          ? AgentState.none
          : const AgentStateCompatConverter().fromJson(json['state']),
    )..isDeleted = json['isDeleted'] as bool? ?? false;

Map<String, dynamic> _$PlacedCircleAgentToJson(PlacedCircleAgent instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'type': const AgentTypeCompatConverter().toJson(instance.type),
      'isAlly': instance.isAlly,
      'state': const AgentStateCompatConverter().toJson(instance.state),
      'diameterMeters': instance.diameterMeters,
      'colorValue': instance.colorValue,
      'opacityPercent': instance.opacityPercent,
    };

PlacedAbility _$PlacedAbilityFromJson(Map<String, dynamic> json) =>
    PlacedAbility(
      data: const AbilityInfoConverter()
          .fromJson(json['data'] as Map<String, dynamic>),
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      isAlly: json['isAlly'] as bool? ?? true,
      length: (json['length'] as num?)?.toDouble() ?? 0,
      lineUpID: json['lineUpID'] as String?,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      armLengthsMeters: (json['armLengthsMeters'] as List<dynamic>?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          [10.0, 10.0, 10.0, 10.0],
    )..isDeleted = json['isDeleted'] as bool? ?? false;

Map<String, dynamic> _$PlacedAbilityToJson(PlacedAbility instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'data': const AbilityInfoConverter().toJson(instance.data),
      'isAlly': instance.isAlly,
      'rotation': instance.rotation,
      'length': instance.length,
      'lineUpID': instance.lineUpID,
      'armLengthsMeters': instance.armLengthsMeters,
    };

PlacedUtility _$PlacedUtilityFromJson(Map<String, dynamic> json) =>
    PlacedUtility(
      type: const UtilityTypeCompatConverter().fromJson(json['type']),
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      isAlly: json['isAlly'] as bool? ?? true,
      angle: (json['angle'] as num?)?.toDouble() ?? 0.0,
      customDiameter: (json['customDiameter'] as num?)?.toDouble(),
      customWidth: (json['customWidth'] as num?)?.toDouble(),
      customLength: (json['customLength'] as num?)?.toDouble(),
      customColorValue: (json['customColorValue'] as num?)?.toInt(),
      customOpacityPercent: (json['customOpacityPercent'] as num?)?.toInt(),
    )
      ..isDeleted = json['isDeleted'] as bool? ?? false
      ..rotation = (json['rotation'] as num).toDouble()
      ..length = (json['length'] as num).toDouble();

Map<String, dynamic> _$PlacedUtilityToJson(PlacedUtility instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'type': const UtilityTypeCompatConverter().toJson(instance.type),
      'rotation': instance.rotation,
      'length': instance.length,
      'angle': instance.angle,
      'customDiameter': instance.customDiameter,
      'customWidth': instance.customWidth,
      'customLength': instance.customLength,
      'customColorValue': instance.customColorValue,
      'customOpacityPercent': instance.customOpacityPercent,
      'isAlly': instance.isAlly,
    };
