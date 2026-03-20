import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:json_annotation/json_annotation.dart';
part "strategy_settings_provider.g.dart";

@JsonSerializable()
class StrategySettings extends HiveObject {
  final double agentSize;
  final double abilitySize;

  StrategySettings({
    this.agentSize = Settings.agentSize,
    this.abilitySize = Settings.abilitySize,
  });

  StrategySettings copyWith({
    double? agentSize,
    double? abilitySize,
    bool? isOpen,
  }) {
    return StrategySettings(
      agentSize: agentSize ?? this.agentSize,
      abilitySize: abilitySize ?? this.abilitySize,
    );
  }

  factory StrategySettings.fromJson(Map<String, dynamic> json) =>
      _$StrategySettingsFromJson(json);
  Map<String, dynamic> toJson() => _$StrategySettingsToJson(this);
}

final strategySettingsProvider =
    NotifierProvider<StrategySettingsProvider, StrategySettings>(
      StrategySettingsProvider.new,
    );

class StrategySettingsProvider extends Notifier<StrategySettings> {
  @override
  StrategySettings build() {
    return StrategySettings();
  }

  void fromHive(StrategySettings settings) {
    state = settings;
  }

  void openSettings() {
    state = state.copyWith(isOpen: true);
  }

  void closeSettings() {
    state = state.copyWith(isOpen: false);
  }

  StrategySettings fromJson(String jsonString) {
    final settings = StrategySettings.fromJson(jsonDecode(jsonString));
    return settings;
  }

  String toJson() {
    final jsonString = jsonEncode(state.toJson());
    return jsonString;
  }

  static String objectToJson(StrategySettings settings) {
    final jsonString = jsonEncode(settings.toJson());
    return jsonString;
  }

  void updateAgentSize(double size) {
    if (state.agentSize == size) {
      return;
    }

    final oldAgentSize = state.agentSize;
    final abilitySize = state.abilitySize;
    final currentMap = ref.read(mapProvider).currentMap;
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;

    ref
        .read(agentProvider.notifier)
        .reflowForAgentSizeChange(
          oldAgentSize: oldAgentSize,
          newAgentSize: size,
        );
    ref
        .read(lineUpProvider.notifier)
        .reflowForMarkerSizeChange(
          oldAgentSize: oldAgentSize,
          newAgentSize: size,
          oldAbilitySize: abilitySize,
          newAbilitySize: abilitySize,
          mapScale: mapScale,
        );
    state = state.copyWith(agentSize: size);
  }

  void updateAbilitySize(double size) {
    if (state.abilitySize == size) {
      return;
    }

    final oldAbilitySize = state.abilitySize;
    final agentSize = state.agentSize;
    final currentMap = ref.read(mapProvider).currentMap;
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;

    ref
        .read(abilityProvider.notifier)
        .reflowForAbilitySizeChange(
          oldAbilitySize: oldAbilitySize,
          newAbilitySize: size,
          mapScale: mapScale,
        );
    ref
        .read(lineUpProvider.notifier)
        .reflowForMarkerSizeChange(
          oldAgentSize: agentSize,
          newAgentSize: agentSize,
          oldAbilitySize: oldAbilitySize,
          newAbilitySize: size,
          mapScale: mapScale,
        );
    state = state.copyWith(abilitySize: size);
  }
}
