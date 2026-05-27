import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/migrations/ability_scale_migration.dart';
import 'package:icarus/migrations/custom_circle_wrapper_migration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:uuid/uuid.dart';

class StrategyMigrator {
  static Future<void> migrateAllStrategies() async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    for (final strat in box.values) {
      final legacyMigrated = await migrateLegacyData(strat);
      final worldMigrated = migrateToWorld16x9(legacyMigrated);
      final abilityScaleMigrated = migrateAbilityScale(worldMigrated);
      final squareAoeMigrated = migrateSquareAoeCenter(abilityScaleMigrated);
      final customCircleMigrated =
          migrateCustomCircleWrapper(squareAoeMigrated);
      if (customCircleMigrated != squareAoeMigrated) {
        await box.put(customCircleMigrated.id, customCircleMigrated);
      } else if (squareAoeMigrated != abilityScaleMigrated) {
        await box.put(squareAoeMigrated.id, squareAoeMigrated);
      } else if (abilityScaleMigrated != worldMigrated) {
        await box.put(abilityScaleMigrated.id, abilityScaleMigrated);
      } else if (worldMigrated != legacyMigrated) {
        await box.put(worldMigrated.id, worldMigrated);
      } else if (legacyMigrated != strat) {
        await box.put(legacyMigrated.id, legacyMigrated);
      }
    }
  }

  static StrategyData migrateAbilityScale(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= AbilityScaleMigration.version) {
      return strat;
    }

    final migratedPages = AbilityScaleMigration.migratePages(
      pages: strat.pages,
      map: strat.mapData,
    );

    final hasPageChanged = migratedPages.length == strat.pages.length &&
        migratedPages.asMap().entries.any((entry) {
          final index = entry.key;
          return entry.value != strat.pages[index];
        });

    if (!hasPageChanged && !force) {
      return strat;
    }

    return strat.copyWith(
      pages: migratedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );
  }

  static StrategyData migrateSquareAoeCenter(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= SquareAoeCenterMigration.version) {
      return strat;
    }

    final migratedPages = SquareAoeCenterMigration.migratePages(
      pages: strat.pages,
    );

    final hasPageChanged = migratedPages.length == strat.pages.length &&
        migratedPages.asMap().entries.any((entry) {
          final index = entry.key;
          return entry.value != strat.pages[index];
        });

    if (!hasPageChanged && !force) {
      return strat;
    }

    return strat.copyWith(
      pages: migratedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );
  }

  static StrategyData migrateCustomCircleWrapper(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= CustomCircleWrapperMigration.version) {
      return strat;
    }

    final migratedPages = CustomCircleWrapperMigration.migratePages(
      pages: strat.pages,
      map: strat.mapData,
    );

    final hasPageChanged = migratedPages.length == strat.pages.length &&
        migratedPages.asMap().entries.any((entry) {
          final index = entry.key;
          return entry.value != strat.pages[index];
        });

    if (!hasPageChanged && !force) {
      return strat;
    }

    return strat.copyWith(
      pages: migratedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );
  }

  static StrategyData migrateToCurrentVersion(StrategyData strat,
      {bool forceAbilityScale = false}) {
    final worldMigrated = migrateToWorld16x9(strat);
    final abilityScaleMigrated =
        migrateAbilityScale(worldMigrated, force: forceAbilityScale);
    final squareAoeMigrated = migrateSquareAoeCenter(abilityScaleMigrated);
    return migrateCustomCircleWrapper(squareAoeMigrated);
  }

  static Future<StrategyData> migrateLegacyData(StrategyData strat) async {
    if (strat.pages.isNotEmpty) {
      return migrateToCurrentVersion(strat);
    }
    if (strat.versionNumber > 15) {
      return migrateToCurrentVersion(strat);
    }
    final originalVersion = strat.versionNumber;
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    final abilityData = [...strat.abilityData];
    if (strat.versionNumber < 7) {
      for (final a in abilityData) {
        if (a.data.abilityData! is SquareAbility) {
          a.position = a.position.translate(0, -7.5);
        }
      }
    }

    final firstPage = StrategyPage(
      id: const Uuid().v4(),
      name: 'Page 1',
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      drawingData: [...strat.drawingData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      agentData: [...strat.agentData],
      abilityData: abilityData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      textData: [...strat.textData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      imageData: [...strat.imageData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      utilityData: [...strat.utilityData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      isAttack: strat.isAttack,
      // ignore: deprecated_member_use_from_same_package
      settings: strat.strategySettings,
      sortIndex: 0,
    );

    final updated = strat.copyWith(
      pages: [firstPage],
      agentData: [],
      abilityData: [],
      drawingData: [],
      utilityData: [],
      textData: [],
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );

    final worldMigrated = migrateToWorld16x9(updated,
        force: originalVersion < Settings.versionNumber);
    final abilityScaleMigrated = migrateAbilityScale(
      worldMigrated,
      force: originalVersion < AbilityScaleMigration.version,
    );
    final squareAoeMigrated = migrateSquareAoeCenter(
      abilityScaleMigrated,
      force: originalVersion < SquareAoeCenterMigration.version,
    );
    return migrateCustomCircleWrapper(
      squareAoeMigrated,
      force: originalVersion < CustomCircleWrapperMigration.version,
    );
  }

  static StrategyData migrateToWorld16x9(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= 38) return strat;

    const double normalizedHeight = 1000.0;
    const double mapAspectRatio = 1.24;
    const double worldAspectRatio = 16 / 9;
    const mapWidth = normalizedHeight * mapAspectRatio;
    const worldWidth = normalizedHeight * worldAspectRatio;
    const padding = (worldWidth - mapWidth) / 2;

    Offset shift(Offset offset) => offset.translate(padding, 0);

    List<PlacedAgentNode> shiftAgentNodes(List<PlacedAgentNode> agents) {
      return [
        for (final agent in agents)
          switch (agent) {
            PlacedAgent() => agent.copyWith(position: shift(agent.position))
              ..isDeleted = agent.isDeleted,
            PlacedViewConeAgent() =>
              agent.copyWith(position: shift(agent.position))
                ..isDeleted = agent.isDeleted,
            PlacedCircleAgent() =>
              agent.copyWith(position: shift(agent.position))
                ..isDeleted = agent.isDeleted,
          },
      ];
    }

    List<PlacedAbility> shiftAbilities(List<PlacedAbility> abilities) {
      return [
        for (final ability in abilities)
          ability.copyWith(position: shift(ability.position))
            ..isDeleted = ability.isDeleted
      ];
    }

    List<PlacedText> shiftTexts(List<PlacedText> texts) {
      return [
        for (final text in texts)
          text.copyWith(
            position: shift(text.position),
          )
      ];
    }

    List<PlacedImage> shiftImages(List<PlacedImage> images) {
      return [
        for (final image in images)
          image.copyWith(position: shift(image.position))
            ..isDeleted = image.isDeleted
      ];
    }

    List<PlacedUtility> shiftUtilities(List<PlacedUtility> utilities) {
      return [
        for (final utility in utilities)
          PlacedUtility(
            type: utility.type,
            position: shift(utility.position),
            id: utility.id,
            angle: utility.angle,
            customDiameter: utility.customDiameter,
            customWidth: utility.customWidth,
            customLength: utility.customLength,
            customColorValue: utility.customColorValue,
            customOpacityPercent: utility.customOpacityPercent,
          )
            ..rotation = utility.rotation
            ..length = utility.length
            ..isDeleted = utility.isDeleted
      ];
    }

    List<LineUp> shiftLineUps(List<LineUp> lineUps) {
      return [
        for (final lineUp in lineUps)
          () {
            final shiftedAgent = lineUp.agent.copyWith(
              position: shift(lineUp.agent.position),
            )..isDeleted = lineUp.agent.isDeleted;
            final shiftedAbility = lineUp.ability.copyWith(
              position: shift(lineUp.ability.position),
            )..isDeleted = lineUp.ability.isDeleted;
            return lineUp.copyWith(
              agent: shiftedAgent,
              ability: shiftedAbility,
            );
          }()
      ];
    }

    BoundingBox? shiftBoundingBox(BoundingBox? boundingBox) {
      if (boundingBox == null) return null;
      return BoundingBox(
        min: shift(boundingBox.min),
        max: shift(boundingBox.max),
      );
    }

    List<DrawingElement> shiftDrawings(List<DrawingElement> drawings) {
      return drawings
          .map((element) {
            if (element is Line) {
              return Line(
                lineStart: shift(element.lineStart),
                lineEnd: shift(element.lineEnd),
                color: element.color,
                thickness: element.thickness,
                boundingBox: shiftBoundingBox(element.boundingBox),
                isDotted: element.isDotted,
                hasArrow: element.hasArrow,
                id: element.id,
                showTraversalTime: element.showTraversalTime,
                traversalSpeedProfile: element.traversalSpeedProfile,
              );
            }
            if (element is FreeDrawing) {
              final shiftedPoints =
                  element.listOfPoints.map(shift).toList(growable: false);

              return FreeDrawing(
                listOfPoints: shiftedPoints,
                color: element.color,
                thickness: element.thickness,
                boundingBox: shiftBoundingBox(element.boundingBox),
                isDotted: element.isDotted,
                hasArrow: element.hasArrow,
                id: element.id,
                showTraversalTime: element.showTraversalTime,
                traversalSpeedProfile: element.traversalSpeedProfile,
              );
            }
            if (element is RectangleDrawing) {
              return RectangleDrawing(
                start: shift(element.start),
                end: shift(element.end),
                color: element.color,
                thickness: element.thickness,
                boundingBox: shiftBoundingBox(element.boundingBox),
                isDotted: element.isDotted,
                hasArrow: element.hasArrow,
                id: element.id,
              );
            }
            return element;
          })
          .cast<DrawingElement>()
          .toList(growable: false);
    }

    final updatedPages = strat.pages
        .map((page) => page.copyWith(
              sortIndex: page.sortIndex,
              name: page.name,
              id: page.id,
              agentData: shiftAgentNodes(page.agentData),
              abilityData: shiftAbilities(page.abilityData),
              textData: shiftTexts(page.textData),
              imageData: shiftImages(page.imageData),
              utilityData: shiftUtilities(page.utilityData),
              drawingData: shiftDrawings(page.drawingData),
              lineUps: shiftLineUps(page.lineUps),
            ))
        .toList(growable: false);

    final migrated = strat.copyWith(
      pages: updatedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );

    return migrated;
  }
}
