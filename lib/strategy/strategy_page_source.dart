import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/strategy_capabilities.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy/cloud_element_decoding.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

sealed class PageHandover {
  const PageHandover();
}

final class SavedToLibrary extends PageHandover {
  const SavedToLibrary();
}

final class QueuedForServer extends PageHandover {
  const QueuedForServer();
}

final class NothingToHandOver extends PageHandover {
  const NothingToHandOver();
}

final class HeldOnCanvas extends PageHandover {
  const HeldOnCanvas(this.reason);

  final HeldReason reason;
}

enum HeldReason {
  strategyMissing,
  pageMissing,
  libraryWriteFailed,
  noServerRead,
  outboxWriteFailed,
  noAccount,
}

PageHandover _settled(PageHandover handover, {required bool anythingUnsaved}) =>
    handover is HeldOnCanvas && !anythingUnsaved
        ? const NothingToHandOver()
        : handover;

bool _anythingUnsaved(Ref ref) =>
    ref.read(strategySaveStateProvider).isDirty ||
    ref.read(textDraftProvider).isNotEmpty;

abstract class StrategyPageSource {
  RemoteEditorSnapshot? get loadedRemoteSnapshot;
  Future<List<String>> listPageIds();
  Future<StrategyEditorPageData> loadPage(String pageId);

  /// Hands the page on screen to its store: the library, or the op queue.
  /// [HeldOnCanvas] when it could not and the canvas has unsaved edits:
  /// they may be held nowhere else.
  @useResult
  Future<PageHandover> flushCurrentPage();
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
  RemoteEditorSnapshot? get loadedRemoteSnapshot => null;

  @override
  Future<List<String>> listPageIds() async {
    final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(
      strategyId,
    );
    if (strategy == null) {
      return const [];
    }
    final pages = [...strategy.pages]
      ..sortBySortIndex((item) => item.sortIndex);
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
      (await const LocalLibrary().replaceAfterMigration(migrated)).orThrow();
    }

    final orderedPages = [...migrated.pages]
      ..sortBySortIndex((item) => item.sortIndex);
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
      lineUpGraph: page.lineUpGraph,
      unshown: UnshownCloudContent.none,
    );
  }

  @override
  Future<PageHandover> flushCurrentPage() async => _settled(
        await _writeCurrentPage(),
        anythingUnsaved: _anythingUnsaved(ref),
      );

  Future<PageHandover> _writeCurrentPage() async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategy = box.get(strategyId);
    if (strategy == null) {
      return const HeldOnCanvas(HeldReason.strategyMissing);
    }

    final pageId = activePageId() ?? strategy.pages.firstOrNull?.id;
    final index = strategy.pages.indexWhere((page) => page.id == pageId);
    if (index < 0) {
      return const HeldOnCanvas(HeldReason.pageMissing);
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
      lineUpGraph: ref.read(lineUpProvider).graph,
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
    try {
      (await const LocalLibrary().savePageOnScreen(updated)).orThrow();
    } on Object catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'The page on screen could not be written to the library.',
        source: 'strategy_page_source',
        error: error,
        stackTrace: stackTrace,
      );
      return const HeldOnCanvas(HeldReason.libraryWriteFailed);
    }
    return const SavedToLibrary();
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
  RemoteEditorSnapshot? _loadedRemoteSnapshot;

  @override
  RemoteEditorSnapshot? get loadedRemoteSnapshot => _loadedRemoteSnapshot;

  RemoteEditorSnapshot get _snapshot {
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    if (snapshot == null) {
      throw StateError('Remote snapshot unavailable for $strategyId.');
    }
    return snapshot;
  }

  @override
  Future<List<String>> listPageIds() async {
    final pages = [..._snapshot.pages]
      ..sortBySortIndex((item) => item.sortIndex);
    return pages.map((page) => page.publicId).toList(growable: false);
  }

  @override
  Future<StrategyEditorPageData> loadPage(String pageId) => _loadPage(pageId);

  Future<StrategyEditorPageData> loadAuthoritativePage(
    String pageId, {
    required Set<EntitySyncKey> discardedEntities,
  }) =>
      _loadPage(pageId, excludedOverlays: discardedEntities);

  Future<StrategyEditorPageData> _loadPage(
    String pageId, {
    Set<EntitySyncKey> excludedOverlays = const {},
  }) async {
    if (ref
            .read(remoteEditorSnapshotProvider)
            .valueOrNull
            ?.activePage
            ?.page
            .publicId !=
        pageId) {
      await ref
          .read(remoteEditorSnapshotProvider.notifier)
          .setActivePage(pageId);
    }
    final snapshot = _snapshot;
    _loadedRemoteSnapshot = snapshot;
    final pages = [...snapshot.pages]
      ..sortBySortIndex((item) => item.sortIndex);
    final page = pages.firstWhere(
      (entry) => entry.publicId == pageId,
      orElse: () => pages.first,
    );

    ref.read(activePageLiveSyncProvider.notifier).dropSatisfiedOverlays(
          page.publicId,
        );
    final projected =
        ref.read(activePageLiveSyncProvider.notifier).projectPageState(
              strategyPublicId: strategyId,
              pageId: page.publicId,
              excludedOverlays: excludedOverlays,
            );
    if (projected != null &&
        (page.publicId == activePageId() ||
            projected.drawsQueuedWork ||
            ref
                .read(activePageLiveSyncProvider.notifier)
                .hasOverlayForPage(page.publicId))) {
      return _hydrateProjectedPage(snapshot, page, projected);
    }

    final pageSnapshot = snapshot.activePage;
    if (pageSnapshot == null || pageSnapshot.page.publicId != page.publicId) {
      throw StateError(
          'Remote page snapshot unavailable for ${page.publicId}.');
    }
    final mapData = drawnStrategyHeader(ref, snapshot.header).mapData;
    final elements = pageSnapshot.elements;
    final lineups = pageSnapshot.lineups;

    final canvas = _readElements(snapshot, [
      for (final element in elements)
        if (!element.deleted)
          ProjectedPageElement(
            publicId: element.publicId,
            elementType: element.elementType,
            payload: element.payload,
            sortIndex: element.sortIndex,
          ),
    ]);

    final cloudLineups = lineUpGraphFromCloudRows([
      for (final lineup in lineups)
        if (!lineup.deleted) CloudLineupRow.remote(lineup),
    ]);
    ref
        .read(activePageLiveSyncProvider.notifier)
        .noteLineupGroups(page.publicId, cloudLineups.groupOf);

    final mapValue = Maps.mapNames.entries.firstWhere(
      (entry) => entry.value == mapData,
      orElse: () => const MapEntry(MapValue.ascent, 'ascent'),
    );

    final settings = _readPageSettings(pageSnapshot.content.settings);

    return canvas.pageData(
      pageId: page.publicId,
      pageName: page.name,
      isAttack: page.isAttack,
      map: mapValue.key,
      settings: settings,
      lineUpGraph: cloudLineups.graph,
    );
  }

  /// The canvas can only be diffed against the server's version of the
  /// page it was drawn from. Without that version (a read failed or is
  /// reloading, the page is still loading, or a teammate deleted it) nothing
  /// is queued ([HeldReason.noServerRead]) and the save state keeps the
  /// edits on screen unsaved until a handover works.
  @override
  Future<PageHandover> flushCurrentPage() async {
    final saveState = ref.read(strategySaveStateProvider.notifier);
    final marksBefore = saveState.dirtyMarks;
    final dirtyBefore = ref.read(strategySaveStateProvider).isDirty;
    final handover = _settled(
      await _handOverCanvas(),
      anythingUnsaved: dirtyBefore || _anythingUnsaved(ref),
    );
    if (ref.read(strategyProvider).strategyId == strategyId) {
      saveState.noteCanvasHandover(handover, marksBefore: marksBefore);
    }
    return handover;
  }

  Future<PageHandover> _handOverCanvas() async {
    // Whether this work is made live is judged as the canvas hands it over,
    // before it waits on anything (see StrategyOpQueueNotifier.liveStamp).
    final pageId = activePageId();
    final madeLive = pageId == null
        ? null
        : ref
            .read(activePageLiveSyncProvider.notifier)
            .liveStampForEdits(pageId);
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    if (snapshot == null || snapshot.header.publicId != strategyId) {
      return const HeldOnCanvas(HeldReason.noServerRead);
    }
    if (!StrategyCapabilities.fromCloudRole(snapshot.header.role)
        .canEditPages) {
      return const NothingToHandOver();
    }
    if (pageId == null) {
      return const HeldOnCanvas(HeldReason.pageMissing);
    }

    await ref.read(strategyProvider.notifier).syncStrategyMetadata();

    final desiredOpsByEntityKey =
        ref.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: strategyId,
              pageId: pageId,
            );
    if (desiredOpsByEntityKey == null) {
      return const HeldOnCanvas(HeldReason.noServerRead);
    }
    return switch (
        await ref.read(strategyOpQueueProvider.notifier).syncDesiredOpsForPage(
              pageId: pageId,
              desiredOpsByEntityKey: desiredOpsByEntityKey,
              flushImmediately: false,
              madeLive: madeLive,
            )) {
      OutboxWrite.written => const QueuedForServer(),
      OutboxWrite.failed => const HeldOnCanvas(HeldReason.outboxWriteFailed),
      OutboxWrite.noAccount => const HeldOnCanvas(HeldReason.noAccount),
    };
  }

  StrategyEditorPageData _hydrateProjectedPage(
    RemoteEditorSnapshot snapshot,
    RemotePage page,
    ActivePageProjectedState projected,
  ) {
    final canvas = _readElements(snapshot, projected.elements);

    final cloudLineups = lineUpGraphFromCloudRows([
      for (final lineup in projected.lineups)
        CloudLineupRow(publicId: lineup.publicId, payload: lineup.payload),
    ]);
    ref
        .read(activePageLiveSyncProvider.notifier)
        .noteLineupGroups(page.publicId, cloudLineups.groupOf);

    final mapValue = Maps.mapNames.entries.firstWhere(
      (entry) =>
          entry.value == drawnStrategyHeader(ref, snapshot.header).mapData,
      orElse: () => const MapEntry(MapValue.ascent, 'ascent'),
    );

    return canvas.pageData(
      pageId: projected.pageId,
      pageName: page.name,
      isAttack: projected.isAttack,
      map: mapValue.key,
      settings: _readPageSettings(projected.settingsPayload),
      lineUpGraph: cloudLineups.graph,
    );
  }

  _CanvasElements _readElements(
    RemoteEditorSnapshot snapshot,
    Iterable<ProjectedPageElement> rows,
  ) {
    final canvas = _CanvasElements();
    for (final row in rows) {
      final reading =
          readCloudElement(row.elementType, cloudPayloadData(row.payload));
      switch (reading) {
        case DrawnCloudElement(item: final PlacedAgentNode agent):
          canvas.agents.add(agent);
        case DrawnCloudElement(item: final PlacedAbility ability):
          canvas.abilities.add(ability);
        case DrawnCloudElement(item: final DrawingElement drawing):
          canvas.drawings.add(drawing);
        case DrawnCloudElement(item: final PlacedText text):
          canvas.texts.add(text);
        case DrawnCloudElement(item: final PlacedImage image):
          canvas.images.add(image);
          final remoteAsset = snapshot.assetsById[image.pictureId];
          if (remoteAsset != null) {
            ref.read(cloudMediaCacheProvider.notifier).ensureAssetCached(
                  strategyId: strategyId,
                  strategyPublicId: strategyId,
                  asset: remoteAsset,
                );
          }
        case DrawnCloudElement(item: final PlacedUtility utility):
          canvas.utilities.add(utility);
        case DrawnCloudElement() ||
              UnreadableCloudElement() ||
              UnknownKindCloudElement():
          if (reading case UnreadableCloudElement(:final error)) {
            AppErrorReporter.reportWarning(
              'Cloud element ${row.publicId} (${row.elementType}) '
              'could not be read.',
              source: 'strategy:cloud_hydration',
              error: error,
            );
          }
          canvas.unshown.add(UnshownCloudElement(
            publicId: row.publicId,
            payload: row.payload,
            sortIndex: row.sortIndex,
          ));
      }
    }
    return canvas;
  }

  ({StrategySettings shown, UnshownSettings? unshown}) _readPageSettings(
    CloudPayload? payload,
  ) {
    if (payload == null || payload.isEmpty) {
      return (shown: StrategySettings(), unshown: null);
    }
    try {
      return (shown: StrategySettings.fromJson(payload), unshown: null);
    } on Object catch (error) {
      AppErrorReporter.reportWarning(
        'Cloud page settings could not be read.',
        source: 'strategy:cloud_hydration',
        error: error,
      );
      final shown = StrategySettings();
      return (shown: shown, unshown: (payload: payload, shownInstead: shown));
    }
  }
}

class _CanvasElements {
  final agents = <PlacedAgentNode>[];
  final abilities = <PlacedAbility>[];
  final drawings = <DrawingElement>[];
  final texts = <PlacedText>[];
  final images = <PlacedImage>[];
  final utilities = <PlacedUtility>[];
  final unshown = <UnshownCloudElement>[];

  StrategyEditorPageData pageData({
    required String pageId,
    required String pageName,
    required bool isAttack,
    required MapValue map,
    required ({StrategySettings shown, UnshownSettings? unshown}) settings,
    required LineUpGraph lineUpGraph,
  }) =>
      StrategyEditorPageData(
        pageId: pageId,
        pageName: pageName,
        isAttack: isAttack,
        map: map,
        settings: settings.shown,
        agents: agents,
        abilities: abilities,
        drawings: drawings,
        texts: texts,
        images: images,
        utilities: utilities,
        lineUpGraph: lineUpGraph,
        unshown: UnshownCloudContent(
          elements: unshown,
          settings: settings.unshown,
        ),
      );
}
