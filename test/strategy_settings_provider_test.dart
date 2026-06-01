import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

void main() {
  test('strategy settings json defaults neutral team colors off', () {
    final settings = StrategySettings.fromJson(const {
      'agentSize': 35,
      'abilitySize': 25,
    });

    expect(settings.useNeutralTeamColors, isFalse);
  });

  test('strategy settings json persists neutral team colors', () {
    final settings = StrategySettings(useNeutralTeamColors: true);

    expect(settings.toJson()['useNeutralTeamColors'], isTrue);
    expect(
      StrategySettings.fromJson(settings.toJson()).useNeutralTeamColors,
      isTrue,
    );
  });

  test('neutral team shade keeps lightness and removes saturation', () {
    final original = HSLColor.fromColor(Settings.allyBGColor);
    final neutral = HSLColor.fromColor(
      Settings.neutralTeamShade(Settings.allyBGColor),
    );

    expect(neutral.saturation, 0);
    expect(neutral.lightness, closeTo(original.lightness, 0.001));
  });
}
