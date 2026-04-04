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
import 'package:uuid/uuid.dart';

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

  List<_CollabElementEnvelope> _collectLocalElementEnvelopes() {
    final envelopes = <_CollabElementEnvelope>[];

    for (final agent in ref.read(agentProvider)) {
      final payload = Map<String, dynamic>.from(agent.toJson())
        ..putIfAbsent('elementType', () => 'agent');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: agent.id,
          elementType: 'agent',
          payload: payload,
        ),
      );
    }

    for (final ability in ref.read(abilityProvider)) {
      final payload = Map<String, dynamic>.from(ability.toJson())
        ..putIfAbsent('elementType', () => 'ability');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: ability.id,
          elementType: 'ability',
          payload: payload,
        ),
      );
    }

    for (final drawing in ref.read(drawingProvider).elements) {
      final encoded = jsonDecode(DrawingProvider.objectToJson([drawing])) as List;
      final payload = Map<String, dynamic>.from(
        (encoded.isEmpty ? <String, dynamic>{} : encoded.first) as Map,
      )..putIfAbsent('elementType', () => 'drawing');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: drawing.id,
          elementType: 'drawing',
          payload: payload,
        ),
      );
    }

    for (final text in ref.read(textProvider)) {
      final payload = Map<String, dynamic>.from(text.toJson())
        ..putIfAbsent('elementType', () => 'text');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: text.id,
          elementType: 'text',
          payload: payload,
        ),
      );
    }

    for (final image in ref.read(placedImageProvider).images) {
      final payload = Map<String, dynamic>.from(image.toJson())
        ..putIfAbsent('elementType', () => 'image');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: image.id,
          elementType: 'image',
          payload: payload,
        ),
      );
    }

    for (final utility in ref.read(utilityProvider)) {
      final payload = Map<String, dynamic>.from(utility.toJson())
        ..putIfAbsent('elementType', () => 'utility');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: utility.id,
          elementType: 'utility',
          payload: payload,
        ),
      );
    }

    return envelopes;
  }

  List<StrategyOp> _buildOpsFromCurrentPageSnapshot(String pageId) {
    final remoteElements = _snapshot.elementsByPage[pageId] ?? const <RemoteElement>[];
    final remoteById = {
      for (final element in remoteElements) element.publicId: element,
    };

    final local = _collectLocalElementEnvelopes();
    final localById = {
      for (var i = 0; i < local.length; i++) local[i].publicId: (local[i], i),
    };

    final ops = <StrategyOp>[];
    for (final entry in localById.entries) {
      final localEnvelope = entry.value.$1;
      final localIndex = entry.value.$2;
      final remote = remoteById[entry.key];
      final payload = jsonEncode(localEnvelope.payload);

      if (remote == null || remote.deleted) {
        ops.add(
          StrategyOp(
            opId: const Uuid().v4(),
            kind: StrategyOpKind.add,
            entityType: StrategyOpEntityType.element,
            entityPublicId: localEnvelope.publicId,
            pagePublicId: pageId,
            payload: payload,
            sortIndex: localIndex,
          ),
        );
        continue;
      }

      if (remote.payload != payload ||
          remote.sortIndex != localIndex ||
          remote.elementType != localEnvelope.elementType) {
        ops.add(
          StrategyOp(
            opId: const Uuid().v4(),
            kind: StrategyOpKind.patch,
            entityType: StrategyOpEntityType.element,
            entityPublicId: localEnvelope.publicId,
            pagePublicId: pageId,
            payload: payload,
            sortIndex: localIndex,
          ),
        );
      }
    }

    for (final remote in remoteElements) {
      if (remote.deleted || localById.containsKey(remote.publicId)) {
        continue;
      }
      ops.add(
        StrategyOp(
          opId: const Uuid().v4(),
          kind: StrategyOpKind.delete,
          entityType: StrategyOpEntityType.element,
          entityPublicId: remote.publicId,
          pagePublicId: pageId,
        ),
      );
    }

    final remoteLineups = _snapshot.lineupsByPage[pageId] ?? const <RemoteLineup>[];
    final remoteLineupsById = {
      for (final lineup in remoteLineups) lineup.publicId: lineup,
    };
    final localLineups = ref.read(lineUpProvider).lineUps;
    final localLineupsById = {
      for (var i = 0; i < localLineups.length; i++) localLineups[i].id: (localLineups[i], i),
    };

    for (final entry in localLineupsById.entries) {
      final lineup = entry.value.$1;
      final localIndex = entry.value.$2;
      final payload = jsonEncode(lineup.toJson());
      final remote = remoteLineupsById[entry.key];

      if (remote == null || remote.deleted) {
        ops.add(
          StrategyOp(
            opId: const Uuid().v4(),
            kind: StrategyOpKind.add,
            entityType: StrategyOpEntityType.lineup,
            entityPublicId: lineup.id,
            pagePublicId: pageId,
            payload: payload,
            sortIndex: localIndex,
          ),
        );
        continue;
      }

      if (remote.payload != payload || remote.sortIndex != localIndex) {
        ops.add(
          StrategyOp(
            opId: const Uuid().v4(),
            kind: StrategyOpKind.patch,
            entityType: StrategyOpEntityType.lineup,
            entityPublicId: lineup.id,
            pagePublicId: pageId,
            payload: payload,
            sortIndex: localIndex,
          ),
        );
      }
    }

    for (final remote in remoteLineups) {
      if (remote.deleted || localLineupsById.containsKey(remote.publicId)) {
        continue;
      }
      ops.add(
        StrategyOp(
          opId: const Uuid().v4(),
          kind: StrategyOpKind.delete,
          entityType: StrategyOpEntityType.lineup,
          entityPublicId: remote.publicId,
          pagePublicId: pageId,
        ),
      );
    }

    final page = _snapshot.pages.firstWhere(
      (entry) => entry.publicId == pageId,
      orElse: () => _snapshot.pages.first,
    );
    final latestSettings = ref.read(strategySettingsProvider.notifier).toJson();
    if (page.settings != latestSettings || page.isAttack != ref.read(mapProvider).isAttack) {
      ops.add(
        StrategyOp(
          opId: const Uuid().v4(),
          kind: StrategyOpKind.patch,
          entityType: StrategyOpEntityType.page,
          entityPublicId: page.publicId,
          payload: jsonEncode(
            {
              'settings': latestSettings,
              'isAttack': ref.read(mapProvider).isAttack,
            },
          ),
        ),
      );
    }

    return ops;
  }
}

class _CollabElementEnvelope {
  const _CollabElementEnvelope({
    required this.publicId,
    required this.elementType,
    required this.payload,
  });

  final String publicId;
  final String elementType;
  final Map<String, dynamic> payload;
}
