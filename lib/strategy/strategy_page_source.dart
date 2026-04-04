import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

abstract class StrategyPageSource {
  Future<List<String>> listPageIds();
  Future<StrategyEditorPageData> loadPage(String pageId);
  Future<void> flushCurrentPage();
}

class LocalStrategyPageSource implements StrategyPageSource {
  LocalStrategyPageSource(
    this.ref, {
    required this.strategyId,
    required this.activePageId,
  });

  final Ref ref;
  final String strategyId;
  final String? Function() activePageId;

  @override
  Future<List<String>> listPageIds() async {
    final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(
      strategyId,
    );
    if (strategy == null) {
      return const [];
    }
    final pages = [...strategy.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return pages.map((page) => page.id).toList(growable: false);
  }

  @override
  Future<StrategyEditorPageData> loadPage(String pageId) async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final current = box.get(strategyId);
    if (current == null) {
      throw StateError('Strategy $strategyId not found.');
    }

    final migrated = StrategyMigrator.migrateToCurrentVersion(current);
    if (!identical(current, migrated)) {
      await box.put(migrated.id, migrated);
    }

    final orderedPages = [...migrated.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final page = orderedPages.firstWhere(
      (entry) => entry.id == pageId,
      orElse: () => orderedPages.first,
    );

    return StrategyEditorPageData(
      pageId: page.id,
      pageName: page.name,
      isAttack: page.isAttack,
      map: migrated.mapData,
      settings: page.settings,
      agents: page.agentData,
      abilities: page.abilityData,
      drawings: page.drawingData,
      texts: page.textData,
      images: page.imageData,
      utilities: page.utilityData,
      lineups: page.lineUps,
    );
  }

  @override
  Future<void> flushCurrentPage() async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategy = box.get(strategyId);
    if (strategy == null || strategy.pages.isEmpty) {
      return;
    }

    final pageId = activePageId() ?? strategy.pages.first.id;
    final index = strategy.pages.indexWhere((page) => page.id == pageId);
    if (index < 0) {
      return;
    }

    final updatedPage = strategy.pages[index].copyWith(
      drawingData: ref.read(drawingProvider).elements,
      agentData: ref.read(agentProvider),
      abilityData: ref.read(abilityProvider),
      textData: ref.read(textProvider.notifier).snapshotForPersistence(),
      imageData: ref.read(placedImageProvider).images,
      utilityData: ref.read(utilityProvider),
      isAttack: ref.read(mapProvider).isAttack,
      settings: ref.read(strategySettingsProvider),
      lineUps: ref.read(lineUpProvider).lineUps,
    );

    final strategyTheme = ref.read(strategyThemeProvider);
    final updatedPages = [...strategy.pages]..[index] = updatedPage;
    final updated = strategy.copyWith(
      pages: updatedPages,
      mapData: ref.read(mapProvider).currentMap,
      themeProfileId: strategyTheme.profileId,
      clearThemeProfileId: strategyTheme.profileId == null,
      themeOverridePalette: strategyTheme.overridePalette,
      clearThemeOverridePalette: strategyTheme.overridePalette == null,
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
  }
}

class CloudStrategyPageSource implements StrategyPageSource {
  CloudStrategyPageSource(
    this.ref, {
    required this.strategyId,
    required this.activePageId,
  });

  final Ref ref;
  final String strategyId;
  final String? Function() activePageId;

  RemoteStrategySnapshot get _snapshot {
    final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
    if (snapshot == null) {
      throw StateError('Remote snapshot unavailable for $strategyId.');
    }
    return snapshot;
  }

  @override
  Future<List<String>> listPageIds() async {
    final pages = [..._snapshot.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return pages.map((page) => page.publicId).toList(growable: false);
  }

  @override
  Future<StrategyEditorPageData> loadPage(String pageId) async {
    final snapshot = _snapshot;
    final pages = [...snapshot.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final page = pages.firstWhere(
      (entry) => entry.publicId == pageId,
      orElse: () => pages.first,
    );

    final projected = ref.read(activePageLiveSyncProvider.notifier).projectPageState(
          strategyPublicId: strategyId,
          pageId: page.publicId,
        );
    if (projected != null &&
        (page.publicId == activePageId() ||
            ref.read(activePageLiveSyncProvider.notifier).hasOverlayForPage(page.publicId))) {
      return _hydrateProjectedPage(snapshot, page, projected);
    }

    final elements = snapshot.elementsByPage[page.publicId] ?? const [];
    final lineups = snapshot.lineupsByPage[page.publicId] ?? const [];

    final agents = <PlacedAgentNode>[];
    final abilities = <PlacedAbility>[];
    final drawings = <DrawingElement>[];
    final texts = <PlacedText>[];
    final images = <PlacedImage>[];
    final utilities = <PlacedUtility>[];

    for (final element in elements) {
      if (element.deleted) {
        continue;
      }
      final payload = element.decodedPayload();
      try {
        switch (element.elementType) {
          case 'agent':
            agents.add(PlacedAgentNode.fromJson(payload));
            break;
          case 'ability':
            abilities.add(PlacedAbility.fromJson(payload));
            break;
          case 'drawing':
            final decoded = DrawingProvider.fromJson(jsonEncode([payload]));
            if (decoded.isNotEmpty) {
              drawings.add(decoded.first);
            }
            break;
          case 'text':
            texts.add(PlacedText.fromJson(payload));
            break;
          case 'image':
            images.add(PlacedImage.fromJson(payload));
            break;
          case 'utility':
            utilities.add(PlacedUtility.fromJson(payload));
            break;
        }
      } catch (_) {
        // Ignore malformed payloads during hydration.
      }
    }

    final parsedLineups = <LineUp>[];
    for (final lineup in lineups) {
      if (lineup.deleted) {
        continue;
      }
      try {
        final decoded = jsonDecode(lineup.payload);
        if (decoded is Map<String, dynamic>) {
          parsedLineups.add(LineUp.fromJson(decoded));
        } else if (decoded is Map) {
          parsedLineups.add(LineUp.fromJson(Map<String, dynamic>.from(decoded)));
        }
      } catch (_) {
        // Ignore malformed payloads during hydration.
      }
    }

    final mapValue = Maps.mapNames.entries.firstWhere(
      (entry) => entry.value == snapshot.header.mapData,
      orElse: () => const MapEntry(MapValue.ascent, 'ascent'),
    );

    StrategySettings pageSettings = StrategySettings();
    if (page.settings != null && page.settings!.isNotEmpty) {
      try {
        pageSettings =
            ref.read(strategySettingsProvider.notifier).fromJson(page.settings!);
      } catch (_) {
        pageSettings = StrategySettings();
      }
    }

    return StrategyEditorPageData(
      pageId: page.publicId,
      pageName: page.name,
      isAttack: page.isAttack,
      map: mapValue.key,
      settings: pageSettings,
      agents: agents,
      abilities: abilities,
      drawings: drawings,
      texts: texts,
      images: images,
      utilities: utilities,
      lineups: parsedLineups,
    );
  }

  @override
  Future<void> flushCurrentPage() async {
    final pageId = activePageId();
    if (pageId == null) {
      return;
    }

    final desiredOpsByEntityKey =
        ref.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: strategyId,
              pageId: pageId,
            );
    ref.read(strategyOpQueueProvider.notifier).syncDesiredOpsForPage(
          pageId: pageId,
          desiredOpsByEntityKey: desiredOpsByEntityKey,
          flushImmediately: false,
        );
  }

  StrategyEditorPageData _hydrateProjectedPage(
    RemoteStrategySnapshot snapshot,
    RemotePage page,
    ActivePageProjectedState projected,
  ) {
    final agents = <PlacedAgentNode>[];
    final abilities = <PlacedAbility>[];
    final drawings = <DrawingElement>[];
    final texts = <PlacedText>[];
    final images = <PlacedImage>[];
    final utilities = <PlacedUtility>[];

    for (final element in projected.elements) {
      final payload = _decodeJsonObject(element.payload);
      try {
        switch (element.elementType) {
          case 'agent':
            agents.add(PlacedAgentNode.fromJson(payload));
            break;
          case 'ability':
            abilities.add(PlacedAbility.fromJson(payload));
            break;
          case 'drawing':
            final decoded = DrawingProvider.fromJson(jsonEncode([payload]));
            if (decoded.isNotEmpty) {
              drawings.add(decoded.first);
            }
            break;
          case 'text':
            texts.add(PlacedText.fromJson(payload));
            break;
          case 'image':
            images.add(PlacedImage.fromJson(payload));
            break;
          case 'utility':
            utilities.add(PlacedUtility.fromJson(payload));
            break;
        }
      } catch (_) {
        // Ignore malformed payloads during hydration.
      }
    }

    final parsedLineups = <LineUp>[];
    for (final lineup in projected.lineups) {
      try {
        final decoded = jsonDecode(lineup.payload);
        if (decoded is Map<String, dynamic>) {
          parsedLineups.add(LineUp.fromJson(decoded));
        } else if (decoded is Map) {
          parsedLineups.add(LineUp.fromJson(Map<String, dynamic>.from(decoded)));
        }
      } catch (_) {
        // Ignore malformed payloads during hydration.
      }
    }

    final mapValue = Maps.mapNames.entries.firstWhere(
      (entry) => entry.value == snapshot.header.mapData,
      orElse: () => const MapEntry(MapValue.ascent, 'ascent'),
    );

    final settings = _parsePageSettings(projected.settingsJson);

    return StrategyEditorPageData(
      pageId: projected.pageId,
      pageName: page.name,
      isAttack: projected.isAttack,
      map: mapValue.key,
      settings: settings,
      agents: agents,
      abilities: abilities,
      drawings: drawings,
      texts: texts,
      images: images,
      utilities: utilities,
      lineups: parsedLineups,
    );
  }

  StrategySettings _parsePageSettings(String? settingsJson) {
    if (settingsJson == null || settingsJson.isEmpty) {
      return StrategySettings();
    }
    try {
      return ref.read(strategySettingsProvider.notifier).fromJson(settingsJson);
    } catch (_) {
      return StrategySettings();
    }
  }

  Map<String, dynamic> _decodeJsonObject(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Ignore malformed payloads during hydration.
    }
    return <String, dynamic>{};
  }

}
