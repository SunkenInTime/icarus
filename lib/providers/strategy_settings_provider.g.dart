// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'strategy_settings_provider.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

StrategySettings _$StrategySettingsFromJson(Map<String, dynamic> json) =>
    StrategySettings(
      agentSize: (json['agentSize'] as num?)?.toDouble() ?? Settings.agentSize,
      abilitySize:
          (json['abilitySize'] as num?)?.toDouble() ?? Settings.abilitySize,
      useNeutralTeamColors: json['useNeutralTeamColors'] as bool? ?? false,
    );

Map<String, dynamic> _$StrategySettingsToJson(StrategySettings instance) =>
    <String, dynamic>{
      'agentSize': instance.agentSize,
      'abilitySize': instance.abilitySize,
      'useNeutralTeamColors': instance.useNeutralTeamColors,
    };
