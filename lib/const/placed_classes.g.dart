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
    };

PlacedImage _$PlacedImageFromJson(Map<String, dynamic> json) => PlacedImage(
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      aspectRatio: (json['aspectRatio'] as num).toDouble(),
      scale: (json['scale'] as num).toDouble(),
      fileExtension: json['fileExtension'] as String?,
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
      'link': instance.link,
    };

PlacedAgent _$PlacedAgentFromJson(Map<String, dynamic> json) => PlacedAgent(
      type: $enumDecode(_$AgentTypeEnumMap, json['type']),
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
      isAlly: json['isAlly'] as bool? ?? true,
    )..isDeleted = json['isDeleted'] as bool? ?? false;

Map<String, dynamic> _$PlacedAgentToJson(PlacedAgent instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'type': _$AgentTypeEnumMap[instance.type]!,
      'isAlly': instance.isAlly,
    };

const _$AgentTypeEnumMap = {
  AgentType.jett: 'jett',
  AgentType.raze: 'raze',
  AgentType.pheonix: 'pheonix',
  AgentType.astra: 'astra',
  AgentType.clove: 'clove',
  AgentType.breach: 'breach',
  AgentType.iso: 'iso',
  AgentType.viper: 'viper',
  AgentType.deadlock: 'deadlock',
  AgentType.yoru: 'yoru',
  AgentType.sova: 'sova',
  AgentType.skye: 'skye',
  AgentType.kayo: 'kayo',
  AgentType.killjoy: 'killjoy',
  AgentType.brimstone: 'brimstone',
  AgentType.cypher: 'cypher',
  AgentType.chamber: 'chamber',
  AgentType.fade: 'fade',
  AgentType.gekko: 'gekko',
  AgentType.harbor: 'harbor',
  AgentType.neon: 'neon',
  AgentType.omen: 'omen',
  AgentType.reyna: 'reyna',
  AgentType.sage: 'sage',
  AgentType.vyse: 'vyse',
  AgentType.tejo: 'tejo',
  AgentType.waylay: 'waylay',
  AgentType.veto: 'veto',
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
    )
      ..isDeleted = json['isDeleted'] as bool? ?? false
      ..rotation = (json['rotation'] as num).toDouble();

Map<String, dynamic> _$PlacedAbilityToJson(PlacedAbility instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'data': const AbilityInfoConverter().toJson(instance.data),
      'isAlly': instance.isAlly,
      'rotation': instance.rotation,
      'length': instance.length,
    };

PlacedUtility _$PlacedUtilityFromJson(Map<String, dynamic> json) =>
    PlacedUtility(
      type: $enumDecode(_$UtilityTypeEnumMap, json['type']),
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
      id: json['id'] as String,
    )
      ..isDeleted = json['isDeleted'] as bool? ?? false
      ..rotation = (json['rotation'] as num).toDouble()
      ..length = (json['length'] as num).toDouble();

Map<String, dynamic> _$PlacedUtilityToJson(PlacedUtility instance) =>
    <String, dynamic>{
      'id': instance.id,
      'isDeleted': instance.isDeleted,
      'position': const OffsetConverter().toJson(instance.position),
      'type': _$UtilityTypeEnumMap[instance.type]!,
      'rotation': instance.rotation,
      'length': instance.length,
    };

const _$UtilityTypeEnumMap = {
  UtilityType.spike: 'spike',
};
