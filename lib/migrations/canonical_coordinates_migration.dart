import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/placed_media_geometry.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/strategy_page.dart';

abstract final class CanonicalCoordinatesMigration {
  static const int version = 97;
  static const double _virtualToWorld = 1000 / 831;

  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
    required MapValue map,
  }) {
    final mapScale = Maps.mapScale[map] ?? 1;
    return [
      for (final page in pages)
        page.isAttack ? page : _migrateDefensePage(page, mapScale),
    ];
  }

  static StrategyPage _migrateDefensePage(
    StrategyPage page,
    double mapScale,
  ) {
    return page.copyWith(
      agentData: [
        for (final agent in page.agentData) _migrateAgent(agent),
      ],
      abilityData: [
        for (final ability in page.abilityData)
          _migrateAbility(ability, mapScale),
      ],
      utilityData: [
        for (final utility in page.utilityData)
          _migrateUtility(utility, mapScale),
      ],
      textData: [
        for (final text in page.textData) _migrateText(text),
      ],
      imageData: [
        for (final image in page.imageData) _migrateImage(image),
      ],
      lineUpGroups: [
        for (final group in page.lineUpGroups)
          LineUpGroup(
            id: group.id,
            agent: _migrateAgent(group.agent) as PlacedAgent,
            items: [
              for (final item in group.items)
                item.copyWith(
                  ability: _migrateAbility(item.ability, mapScale),
                  images: item.images.map((image) => image.copyWith()).toList(),
                ),
            ],
          ),
      ],
    );
  }

  static PlacedAgentNode _migrateAgent(PlacedAgentNode agent) {
    final position = _reflect(
      agent.position,
      storedAnchorVirtual: const Offset(
        Settings.agentSize / 2,
        Settings.agentSize / 2,
      ),
    );

    return switch (agent) {
      PlacedAgent() => agent.copyWith(position: position),
      PlacedViewConeAgent() => agent.copyWith(
          position: position,
          rotation: agent.rotation - math.pi,
        ),
      PlacedCircleAgent() => agent.copyWith(position: position),
    };
  }

  static PlacedAbility _migrateAbility(
    PlacedAbility ability,
    double mapScale,
  ) {
    final data = ability.data.abilityData!;
    final shouldRotate = isRotatable(data) ||
        AbilityVisionConeSpec.forAbility(ability.data) != null;
    final migrated = ability.copyWith(
      position: _reflect(
        ability.position,
        storedAnchorVirtual: data.getAnchorPoint(
          mapScale: mapScale,
          abilitySize: Settings.abilitySize,
        ),
      ),
      rotation: shouldRotate ? ability.rotation - math.pi : ability.rotation,
    );
    migrated.isDeleted = ability.isDeleted;
    return migrated;
  }

  static PlacedUtility _migrateUtility(
    PlacedUtility utility,
    double mapScale,
  ) {
    final anchor = UtilityData.utilityWidgets[utility.type]!.getAnchorPoint(
      id: utility.id,
      length: utility.length,
      rotation: utility.rotation,
      mapScale: mapScale,
      agentSize: Settings.agentSize,
      abilitySize: Settings.abilitySize,
      diameterMeters: utility.customDiameter,
      widthMeters: utility.customWidth,
      rectLengthMeters: utility.customLength,
    );
    return utility.copyWith(
      position: _reflect(
        utility.position,
        storedAnchorVirtual: anchor,
      ),
      rotation: UtilityData.isViewCone(utility.type)
          ? utility.rotation - math.pi
          : utility.rotation,
    );
  }

  static PlacedText _migrateText(PlacedText text) {
    final footprint = PlacedMediaGeometry.legacyTextFootprintInWorld(text);
    return text.copyWith(
      position: _reflectWorld(text.position, footprint.center(Offset.zero)),
    );
  }

  static PlacedImage _migrateImage(PlacedImage image) {
    final footprint = PlacedMediaGeometry.legacyImageFootprintInWorld(image);
    final migrated = image.copyWith(
      position: _reflectWorld(image.position, footprint.center(Offset.zero)),
    );
    migrated.isDeleted = image.isDeleted;
    return migrated;
  }

  static Offset _reflect(
    Offset position, {
    required Offset storedAnchorVirtual,
  }) {
    return _reflectWorld(position, storedAnchorVirtual * _virtualToWorld);
  }

  static Offset _reflectWorld(Offset position, Offset storedAnchorWorld) {
    const worldSize = Size(1000 * (16 / 9), 1000);
    return Offset(
      worldSize.width - position.dx - (storedAnchorWorld.dx * 2),
      worldSize.height - position.dy - (storedAnchorWorld.dy * 2),
    );
  }
}
