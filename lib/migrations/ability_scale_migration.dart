import 'dart:ui';

import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_page.dart';

class AbilityScaleMigration {
  static const int version = 39;

  static const double _oldInGameMeters = 5.5;
  static const double _oldInGameMetersDiameter = _oldInGameMeters * 2;
  static const double _metersRatioNewOverOld =
      AgentData.inGameMeters / _oldInGameMeters;

  static const Map<MapValue, double> _oldMapScale = {
    MapValue.ascent: 1.0,
    MapValue.breeze: 1.02,
    MapValue.lotus: 1.25,
    MapValue.icebox: 1.05,
    MapValue.split: 1.18,
    MapValue.haven: 1.09,
    MapValue.fracture: 1.0,
    MapValue.pearl: 1.185,
    MapValue.abyss: 1.167,
    MapValue.sunset: 1.048,
    MapValue.bind: 0.835,
    MapValue.corrode: 0.985,
  };

  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
    required MapValue map,
  }) {
    return [
      for (final page in pages)
        page.copyWith(
          abilityData: [
            for (final ability in page.abilityData)
              migratePlacedAbilityPosition(ability: ability, map: map),
          ],
          lineUps: [
            for (final lineUp in page.lineUps)
              _migrateLineUpAbilityPosition(lineUp: lineUp, map: map),
          ],
        ),
    ];
  }

  static LineUp _migrateLineUpAbilityPosition({
    required LineUp lineUp,
    required MapValue map,
  }) {
    final migratedAbility =
        migratePlacedAbilityPosition(ability: lineUp.ability, map: map);
    if (migratedAbility == lineUp.ability) return lineUp;
    return lineUp.copyWith(ability: migratedAbility);
  }

  static PlacedAbility migratePlacedAbilityPosition({
    required PlacedAbility ability,
    required MapValue map,
  }) {
    final data = ability.data.abilityData;
    if (data == null) return ability;

    final oldMapScale = _oldMapScale[map] ?? 1.0;
    final newMapScale = Maps.mapScale[map] ?? 1.0;

    final oldAnchor = _oldAnchor(
      data: data,
      type: ability.data.type,
      index: ability.data.index,
      oldMapScale: oldMapScale,
    );
    final newAnchor = _newAnchor(
      data: data,
      type: ability.data.type,
      index: ability.data.index,
      newMapScale: newMapScale,
    );

    final delta = oldAnchor - newAnchor;
    if (delta == Offset.zero) return ability;

    return ability.copyWith(
      position: ability.position.translate(delta.dx, delta.dy),
    );
  }

  static Offset _newAnchor({
    required Ability data,
    required AgentType type,
    required int index,
    required double newMapScale,
  }) {
    return data.getAnchorPoint(
      mapScale: newMapScale,
      abilitySize: Settings.abilitySize,
    );
  }

  static Offset _oldAnchor({
    required Ability data,
    required AgentType type,
    required int index,
    required double oldMapScale,
  }) {
    if (data is BaseAbility) {
      return const Offset(Settings.abilitySize / 2, Settings.abilitySize / 2);
    }

    if (data is CircleAbility) {
      final oldSize = data.size *
          (_oldInGameMetersDiameter / AgentData.inGameMetersDiameter);
      return Offset((oldSize * oldMapScale) / 2, (oldSize * oldMapScale) / 2);
    }

    if (data is ImageAbility) {
      final spec =
          _imageAbilitySpecs[_abilityKey(type, index)] ?? _imageDefaultSpec;
      final oldSize = _toOldMeterValue(data.size, spec.sizeUsesMeters);
      return Offset((oldSize * oldMapScale) / 2, (oldSize * oldMapScale) / 2);
    }

    if (data is ResizableSquareAbility) {
      final spec = _resizableSquareSpecs[_abilityKey(type, index)] ??
          _resizableSquareDefaultSpec;
      final oldWidth = _toOldMeterValue(data.width, spec.widthUsesMeters);
      final oldHeight = _toOldMeterValue(data.height, spec.heightUsesMeters);
      final oldDistance =
          _toOldMeterValue(data.distanceBetweenAOE, spec.distanceUsesMeters);

      return Offset(
        (data.isWall ? Settings.abilitySize * 2 : oldWidth * oldMapScale) / 2,
        (oldHeight * oldMapScale) + (oldDistance * oldMapScale) + 7.5,
      );
    }

    if (data is SquareAbility) {
      final spec =
          _squareAbilitySpecs[_abilityKey(type, index)] ?? _squareDefaultSpec;
      final oldWidth = _toOldMeterValue(data.width, spec.widthUsesMeters);
      final oldHeight = _toOldMeterValue(data.height, spec.heightUsesMeters);
      final oldDistance =
          _toOldMeterValue(data.distanceBetweenAOE, spec.distanceUsesMeters);

      return Offset(
        (data.isWall ? Settings.abilitySize * 2 : oldWidth * oldMapScale) / 2,
        (oldHeight * oldMapScale) + (oldDistance * oldMapScale) + 7.5,
      );
    }

    if (data is CenterSquareAbility) {
      final spec = _centerSquareSpecs[_abilityKey(type, index)] ??
          _centerSquareDefaultSpec;
      final oldHeight = _toOldMeterValue(data.height, spec.heightUsesMeters);
      return Offset(
        Settings.abilitySize / 2,
        (oldHeight * oldMapScale) / 2,
      );
    }

    if (data is RotatableImageAbility) {
      final spec = _rotatableImageSpecs[_abilityKey(type, index)] ??
          _rotatableImageDefaultSpec;
      final oldWidth = _toOldMeterValue(data.width, spec.widthUsesMeters);
      final oldHeight = _toOldMeterValue(data.height, spec.heightUsesMeters);
      return Offset(
        (oldWidth * oldMapScale) / 2,
        ((oldHeight * oldMapScale) / 2) + 30,
      );
    }

    return data.getAnchorPoint(
      mapScale: oldMapScale,
      abilitySize: Settings.abilitySize,
    );
  }

  static String _abilityKey(AgentType type, int index) => '${type.name}:$index';

  static double _toOldMeterValue(double current, bool usesMeters) {
    if (!usesMeters) return current;
    return current / _metersRatioNewOverOld;
  }
}

class _ImageAbilitySpec {
  const _ImageAbilitySpec({required this.sizeUsesMeters});
  final bool sizeUsesMeters;
}

class _SquareAbilitySpec {
  const _SquareAbilitySpec({
    required this.widthUsesMeters,
    required this.heightUsesMeters,
    required this.distanceUsesMeters,
  });
  final bool widthUsesMeters;
  final bool heightUsesMeters;
  final bool distanceUsesMeters;
}

class _CenterSquareSpec {
  const _CenterSquareSpec({required this.heightUsesMeters});
  final bool heightUsesMeters;
}

class _RotatableImageSpec {
  const _RotatableImageSpec({
    required this.widthUsesMeters,
    required this.heightUsesMeters,
  });
  final bool widthUsesMeters;
  final bool heightUsesMeters;
}

const _imageDefaultSpec = _ImageAbilitySpec(sizeUsesMeters: false);
const _squareDefaultSpec = _SquareAbilitySpec(
  widthUsesMeters: true,
  heightUsesMeters: true,
  distanceUsesMeters: true,
);
const _resizableSquareDefaultSpec = _squareDefaultSpec;
const _centerSquareDefaultSpec = _CenterSquareSpec(heightUsesMeters: false);
const _rotatableImageDefaultSpec = _RotatableImageSpec(
  widthUsesMeters: true,
  heightUsesMeters: true,
);

const Map<String, _ImageAbilitySpec> _imageAbilitySpecs = {
  'jett:0': _ImageAbilitySpec(sizeUsesMeters: false),
  'astra:2': _ImageAbilitySpec(sizeUsesMeters: true),
  'viper:1': _ImageAbilitySpec(sizeUsesMeters: true),
  'brimstone:2': _ImageAbilitySpec(sizeUsesMeters: true),
  'omen:2': _ImageAbilitySpec(sizeUsesMeters: true),
  'clove:2': _ImageAbilitySpec(sizeUsesMeters: true),
  'harbor:2': _ImageAbilitySpec(sizeUsesMeters: true),
};

const Map<String, _SquareAbilitySpec> _squareAbilitySpecs = {
  // Fixed-width walls/boxes still scale by mapScale but not by inGameMeters.
  'pheonix:0': _SquareAbilitySpec(
    widthUsesMeters: false,
    heightUsesMeters: true,
    distanceUsesMeters: true,
  ),
  'viper:2': _SquareAbilitySpec(
    widthUsesMeters: false,
    heightUsesMeters: true,
    distanceUsesMeters: true,
  ),
};

const Map<String, _SquareAbilitySpec> _resizableSquareSpecs = {
  'cypher:0': _SquareAbilitySpec(
    widthUsesMeters: false,
    heightUsesMeters: true,
    distanceUsesMeters: true,
  ),
};

const Map<String, _CenterSquareSpec> _centerSquareSpecs = {
  'astra:3': _CenterSquareSpec(heightUsesMeters: false),
};

const Map<String, _RotatableImageSpec> _rotatableImageSpecs = {
  'sage:0': _RotatableImageSpec(widthUsesMeters: true, heightUsesMeters: true),
};

class SquareAoeCenterMigration {
  static const int version = 40;

  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
  }) {
    return [
      for (final page in pages)
        page.copyWith(
          abilityData: [
            for (final ability in page.abilityData) migratePlacedAbility(ability),
          ],
          lineUps: [
            for (final lineUp in page.lineUps)
              lineUp.copyWith(ability: migratePlacedAbility(lineUp.ability)),
          ],
        ),
    ];
  }

  static PlacedAbility migratePlacedAbility(PlacedAbility ability) {
    final abilityData = ability.data.abilityData;
    if (abilityData is! SquareAbility && abilityData is! ResizableSquareAbility) {
      return ability;
    }

    final deltaY = Settings.abilitySize / 2;
    return ability.copyWith(
      position: ability.position.translate(0, deltaY),
    );
  }
}
