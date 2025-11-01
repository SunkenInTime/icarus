import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/settings.dart';
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
        StrategySettingsProvider.new);

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

  void updateAgentSize(double size) {
    state = state.copyWith(agentSize: size);
  }

  void updateAbilitySize(double size) {
    state = state.copyWith(abilitySize: size);
  }
}
