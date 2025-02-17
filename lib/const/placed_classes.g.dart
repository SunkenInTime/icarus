// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'placed_classes.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PlacedWidget _$PlacedWidgetFromJson(Map<String, dynamic> json) => PlacedWidget(
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$PlacedWidgetToJson(PlacedWidget instance) =>
    <String, dynamic>{
      'position': const OffsetConverter().toJson(instance.position),
    };

PlacedAgent _$PlacedAgentFromJson(Map<String, dynamic> json) => PlacedAgent(
      type: $enumDecode(_$AgentTypeEnumMap, json['type']),
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$PlacedAgentToJson(PlacedAgent instance) =>
    <String, dynamic>{
      'position': const OffsetConverter().toJson(instance.position),
      'type': _$AgentTypeEnumMap[instance.type]!,
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
};

PlacedAbility _$PlacedAbilityFromJson(Map<String, dynamic> json) =>
    PlacedAbility(
      data: const AbilityInfoConverter()
          .fromJson(json['data'] as Map<String, dynamic>),
      position: const OffsetConverter()
          .fromJson(json['position'] as Map<String, dynamic>),
    )..rotation = (json['rotation'] as num).toDouble();

Map<String, dynamic> _$PlacedAbilityToJson(PlacedAbility instance) =>
    <String, dynamic>{
      'position': const OffsetConverter().toJson(instance.position),
      'data': const AbilityInfoConverter().toJson(instance.data),
      'rotation': instance.rotation,
    };
