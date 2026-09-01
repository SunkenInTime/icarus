import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/placed_media_geometry.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/migrations/canonical_coordinates_migration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

const _worldSize = Size(1000 * (16 / 9), 1000);
const _virtualToWorld = 1000 / 831;

Offset _legacyDefensePosition(Offset canonical, Offset anchorWorld) {
  return Offset(
    _worldSize.width - canonical.dx - (anchorWorld.dx * 2),
    _worldSize.height - canonical.dy - (anchorWorld.dy * 2),
  );
}

Offset _virtualAnchorToWorld(Offset anchor) => anchor * _virtualToWorld;

void _expectOffset(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 0.0001));
  expect(actual.dy, closeTo(expected.dy, 0.0001));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CanonicalCoordinatesMigration', () {
    test('converts every defense-page object family back to attack storage',
        () {
      const map = MapValue.bind;
      final mapScale = Maps.mapScale[map]!;
      const agentCanonical = Offset(120, 210);
      const abilityCanonical = Offset(330, 145);
      const utilityCanonical = Offset(640, 430);
      const textCanonical = Offset(80, 720);
      const imageCanonical = Offset(980, 90);
      const lineupAgentCanonical = Offset(250, 670);
      const lineupAbilityCanonical = Offset(1180, 310);
      const abilityRotation = 0.65;
      const utilityRotation = 1.15;

      final abilityInfo = AgentData.agents[AgentType.deadlock]!.abilities[2];
      final abilityAnchor = _virtualAnchorToWorld(
        abilityInfo.abilityData!.getAnchorPoint(
          mapScale: mapScale,
          abilitySize: Settings.abilitySize,
        ),
      );
      final utilityPrototype = PlacedUtility(
        id: 'view-cone',
        type: UtilityType.viewCone90,
        position: Offset.zero,
      )
        ..rotation = utilityRotation + math.pi
        ..length = 110;
      final utilityAnchor = _virtualAnchorToWorld(
        UtilityData.utilityWidgets[utilityPrototype.type]!.getAnchorPoint(
          id: utilityPrototype.id,
          length: utilityPrototype.length,
          rotation: utilityPrototype.rotation,
          mapScale: mapScale,
          agentSize: Settings.agentSize,
          abilitySize: Settings.abilitySize,
        ),
      );
      final text = PlacedText(
        id: 'text',
        position: Offset.zero,
        size: 220,
        fontSize: 16,
        sizeVersion: worldSizedMediaVersion,
      )..text = 'Default hold\nRetake on contact';
      final textFootprint =
          PlacedMediaGeometry.legacyTextFootprintInWorld(text);
      final image = PlacedImage(
        id: 'image',
        position: Offset.zero,
        aspectRatio: 16 / 9,
        scale: 240,
        fileExtension: '.png',
        sizeVersion: worldSizedMediaVersion,
      );
      final imageFootprint =
          PlacedMediaGeometry.legacyImageFootprintInWorld(image);

      final page = StrategyPage(
        id: 'defense-page',
        name: 'Defense',
        sortIndex: 0,
        isAttack: false,
        settings: StrategySettings(),
        drawingData: const [],
        agentData: [
          PlacedViewConeAgent(
            id: 'agent',
            type: AgentType.sova,
            presetType: UtilityType.viewCone90,
            position: _legacyDefensePosition(
              agentCanonical,
              _virtualAnchorToWorld(
                const Offset(Settings.agentSize / 2, Settings.agentSize / 2),
              ),
            ),
            rotation: 0.35 + math.pi,
          ),
        ],
        abilityData: [
          PlacedAbility(
            id: 'ability',
            data: abilityInfo,
            position: _legacyDefensePosition(
              abilityCanonical,
              abilityAnchor,
            ),
            rotation: abilityRotation + math.pi,
          ),
        ],
        utilityData: [
          utilityPrototype.copyWith(
            position: _legacyDefensePosition(
              utilityCanonical,
              utilityAnchor,
            ),
          ),
        ],
        textData: [
          text.copyWith(
            position: _legacyDefensePosition(
              textCanonical,
              textFootprint.center(Offset.zero),
            ),
          ),
        ],
        imageData: [
          image.copyWith(
            position: _legacyDefensePosition(
              imageCanonical,
              imageFootprint.center(Offset.zero),
            ),
          ),
        ],
        lineUpGroups: [
          LineUpGroup(
            id: 'lineup',
            agent: PlacedAgent(
              id: 'lineup-agent',
              type: AgentType.harbor,
              position: _legacyDefensePosition(
                lineupAgentCanonical,
                _virtualAnchorToWorld(
                  const Offset(
                    Settings.agentSize / 2,
                    Settings.agentSize / 2,
                  ),
                ),
              ),
            ),
            items: [
              LineUpItem(
                id: 'lineup-item',
                ability: PlacedAbility(
                  id: 'lineup-ability',
                  data: abilityInfo,
                  position: _legacyDefensePosition(
                    lineupAbilityCanonical,
                    abilityAnchor,
                  ),
                  rotation: abilityRotation + math.pi,
                ),
              ),
            ],
          ),
        ],
      );
      final strategy = StrategyData(
        id: 'legacy-defense',
        name: 'Legacy defense',
        mapData: map,
        versionNumber: CanonicalCoordinatesMigration.version - 1,
        lastEdited: DateTime.utc(2026, 1, 1),
        folderID: null,
        pages: [page],
      );

      final migrated = StrategyProvider.migrateToCurrentVersion(strategy);
      final migratedPage = migrated.pages.single;

      expect(migrated.versionNumber, Settings.versionNumber);
      expect(migratedPage.isAttack, isFalse);
      _expectOffset(migratedPage.agentData.single.position, agentCanonical);
      expect(
        (migratedPage.agentData.single as PlacedViewConeAgent).rotation,
        closeTo(0.35, 0.0001),
      );
      _expectOffset(migratedPage.abilityData.single.position, abilityCanonical);
      expect(
        migratedPage.abilityData.single.rotation,
        closeTo(abilityRotation, 0.0001),
      );
      _expectOffset(migratedPage.utilityData.single.position, utilityCanonical);
      expect(
        migratedPage.utilityData.single.rotation,
        closeTo(utilityRotation, 0.0001),
      );
      _expectOffset(migratedPage.textData.single.position, textCanonical);
      _expectOffset(migratedPage.imageData.single.position, imageCanonical);
      _expectOffset(
        migratedPage.lineUpGroups.single.agent.position,
        lineupAgentCanonical,
      );
      _expectOffset(
        migratedPage.lineUpGroups.single.items.single.ability.position,
        lineupAbilityCanonical,
      );
      expect(
        migratedPage.lineUpGroups.single.items.single.ability.rotation,
        closeTo(abilityRotation, 0.0001),
      );
    });

    test('does not rewrite attack-page coordinates', () {
      final page = StrategyPage(
        id: 'attack-page',
        name: 'Attack',
        sortIndex: 0,
        isAttack: true,
        settings: StrategySettings(),
        drawingData: const [],
        agentData: [
          PlacedAgent(
            id: 'agent',
            type: AgentType.jett,
            position: const Offset(123, 456),
          ),
        ],
        abilityData: const [],
        utilityData: const [],
        textData: const [],
        imageData: const [],
      );
      final strategy = StrategyData(
        id: 'legacy-attack',
        name: 'Legacy attack',
        mapData: MapValue.ascent,
        versionNumber: CanonicalCoordinatesMigration.version - 1,
        lastEdited: DateTime.utc(2026, 1, 1),
        folderID: null,
        pages: [page],
      );

      final migrated = StrategyProvider.migrateToCurrentVersion(strategy);

      expect(identical(migrated.pages.single, page), isTrue);
      _expectOffset(
        migrated.pages.single.agentData.single.position,
        const Offset(123, 456),
      );
    });

    test('is idempotent for current-version strategies', () {
      final strategy = StrategyData(
        id: 'current',
        name: 'Current',
        mapData: MapValue.ascent,
        versionNumber: Settings.versionNumber,
        lastEdited: DateTime.utc(2026, 1, 1),
        folderID: null,
        pages: const [],
      );

      expect(
        identical(StrategyProvider.migrateToCurrentVersion(strategy), strategy),
        isTrue,
      );
    });
  });
}
