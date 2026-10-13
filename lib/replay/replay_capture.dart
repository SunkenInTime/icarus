import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/replay_capture_record.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/replay_capture_queue_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/strategy/strategy_cloud_migration.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:uuid/uuid.dart';

/// Saves replay moments as pages of one strategy. The first capture creates
/// the strategy; later ones append to it, so a replay session builds one
/// strategy page by page.
///
/// Players and utility keep their replay ids on every page (in the cloud,
/// one root id, see page_copy_id.dart), so the editor's page transitions
/// move each player from one captured moment to the next.
class ReplayCapture {
  ReplayCapture({
    required this.newStore,
    required this.map,
    required this.name,
  });

  /// The library the next new strategy goes to, asked each time a capture
  /// has to start one.
  final ReplayCaptureStore Function() newStore;
  final MapValue map;

  /// The strategy's name when the first capture creates it.
  final String name;

  ReplayCaptureStore? _store;
  CapturedStrategy? _strategy;
  final List<String> _pageIds = [];
  Future<void> _tail = Future.value();

  /// The strategy captures go to, as the last capture or [reload] left it.
  CapturedStrategy? get strategy => _strategy;

  /// The pages captured into [strategy], in order.
  List<String> get pageIds => List.unmodifiable(_pageIds);

  /// Saves [frame] as a page named [pageName] and returns the strategy.
  /// Refuses, without writing, a frame holding a non-finite number. If the
  /// user deleted the strategy or moved it to another map, this starts a
  /// new one rather than writing this map's positions into it.
  ///
  /// Captures are written one after another, in the order asked for.
  Future<CapturedStrategy> capture(
    ReplayFrame frame, {
    required String pageName,
  }) {
    try {
      _checkFinite(frame);
    } catch (error, stackTrace) {
      return Future.error(error, stackTrace);
    }
    final page = (name: pageName, frame: frame);
    final written = _tail.then((_) => _write(page));
    _tail = written.then((_) {}, onError: (_) {});
    return written;
  }

  Future<CapturedStrategy> _write(CapturedPage page) async {
    final store = _store;
    final current = _strategy;
    if (store != null && current != null) {
      final appended = await store.append(current, page);
      if (appended != null) {
        _pageIds.add(appended.lastPageId);
        return _strategy = appended;
      }
    }
    final fresh = newStore();
    final created = await fresh.create(map, name, page);
    _store = fresh;
    _pageIds
      ..clear()
      ..add(created.lastPageId);
    return _strategy = created;
  }

  /// Reads the strategy again, after the editor may have changed it.
  Future<void> reload() async {
    await _tail;
    final store = _store;
    final current = _strategy;
    if (store == null || current == null) return;
    final found = await store.find(current);
    if (found == null) {
      _store = null;
      _pageIds.clear();
    }
    _strategy = found;
  }

  static void _checkFinite(ReplayFrame frame) {
    for (final widget in frame.widgets) {
      final geometry = <double>[
        widget.position.dx,
        widget.position.dy,
        ...switch (widget) {
          PlacedViewConeAgent(:final rotation, :final length) => [
              rotation,
              length,
            ],
          PlacedAbility(
            :final rotation,
            :final length,
            :final armLengthsMeters
          ) =>
            [rotation, length, ...armLengthsMeters],
          PlacedUtility(:final rotation, :final length) => [rotation, length],
          _ => const <double>[],
        },
      ];
      if (geometry.any((value) => !value.isFinite)) {
        throw StateError('Capture refused: ${widget.id} is not on the map.');
      }
    }
  }
}

/// One replay moment to save as a page.
typedef CapturedPage = ({String name, ReplayFrame frame});

/// The strategy a replay's captures fill, as it stood when last read.
typedef CapturedStrategy = ({
  String id,
  String name,
  MapValue map,
  StrategySource source,
  int pageCount,
  String lastPageId,
  bool lastPageIsAttack,
});

/// The library one strategy of captures lives in. Each store makes one
/// strategy and then appends to it.
abstract interface class ReplayCaptureStore {
  /// Makes a strategy on [map] named [name] with [page] as its only page.
  Future<CapturedStrategy> create(
    MapValue map,
    String name,
    CapturedPage page,
  );

  /// Adds [page] after the last page of [strategy]. Returns null, writing
  /// nothing, when [strategy] is known to be gone or now on another map.
  Future<CapturedStrategy?> append(
    CapturedStrategy strategy,
    CapturedPage page,
  );

  /// [strategy] as it is now; null when it is known to be gone or now on
  /// another map.
  Future<CapturedStrategy?> find(CapturedStrategy strategy);
}

/// Where a replay's next strategy goes: the cloud library while the user is
/// signed in, as New Strategy does (into the cloud folder open in My
/// Library, else the top level); the local library otherwise.
final replayCaptureStoreProvider =
    Provider<ReplayCaptureStore Function()>((ref) {
  return () {
    final strategies = ref.read(strategyProvider.notifier);
    final accountId = ref.read(cloudMediaAccountIdProvider);
    if (!ref.read(isCloudWorkspaceAvailableProvider) || accountId == null) {
      return LocalReplayCaptureStore(
        (map, name) =>
            strategies.createNewStrategy(map: map, name: name, local: true),
      );
    }
    return CloudReplayCaptureStore(
      queue: ref.read(replayCaptureQueueProvider.notifier),
      queueState: () => ref.read(replayCaptureQueueProvider),
      accountId: accountId,
      folderId: _ownedCloudFolder(ref),
      settings: strategies.newStrategySettings(),
      themeProfileId:
          ref.read(mapThemeProfilesProvider).defaultProfileIdForNewStrategies,
    );
  };
});

/// The cloud folder open in My Library, when it is this account's own. A
/// folder someone shared, or one not known to be owned yet, is no place to
/// make a strategy: the capture goes to the top level.
String? _ownedCloudFolder(Ref ref) {
  final folderId = ref
      .read(folderProvider.notifier)
      .currentFolderIdForWorkspace(LibraryWorkspace.cloud);
  if (folderId == null) return null;
  final folders = ref.read(cloudFolderTreeProvider).valueOrNull ?? const [];
  final owned = folders.any(
    (entry) => entry.folder.id == folderId && entry.role == 'owner',
  );
  return owned ? folderId : null;
}

/// Captures into the local library on this device.
class LocalReplayCaptureStore implements ReplayCaptureStore {
  LocalReplayCaptureStore(this.createStrategy);

  /// Makes the empty strategy the first capture fills, as the library's
  /// New Strategy does.
  final Future<StrategyData> Function(MapValue map, String name) createStrategy;

  Box<StrategyData> get _box =>
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

  @override
  Future<CapturedStrategy> create(
    MapValue map,
    String name,
    CapturedPage page,
  ) async {
    final blank = await createStrategy(map, name);
    // A new strategy comes with one blank page; the first capture takes
    // its place rather than following it.
    return _put(blank, const [], page);
  }

  @override
  Future<CapturedStrategy?> append(
    CapturedStrategy strategy,
    CapturedPage page,
  ) async {
    final stored = _stored(strategy);
    if (stored == null) return null;
    final pages = [...stored.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return _put(stored, pages, page);
  }

  @override
  Future<CapturedStrategy?> find(CapturedStrategy strategy) async {
    final stored = _stored(strategy);
    if (stored == null) return null;
    final last = stored.pages.firstWhere(
      (page) => page.id == strategy.lastPageId,
      orElse: () => stored.pages.last,
    );
    return _captured(stored, last);
  }

  StrategyData? _stored(CapturedStrategy strategy) {
    final stored = _box.get(strategy.id);
    return stored?.mapData == strategy.map && stored!.pages.isNotEmpty
        ? stored
        : null;
  }

  Future<CapturedStrategy> _put(
    StrategyData target,
    List<StrategyPage> pages,
    CapturedPage captured,
  ) async {
    final frame = captured.frame;
    final page = StrategyPage(
      id: const Uuid().v4(),
      name: captured.name,
      isAutoNamed: false,
      drawingData: const [],
      agentData: frame.agents,
      abilityData: frame.abilities,
      textData: const [],
      imageData: const [],
      utilityData: frame.utilities,
      sortIndex: pages.length,
      isAttack: frame.isAttack,
      settings: target.pages.first.settings,
    );
    final updated = target.copyWith(
      pages: [...pages, page],
      lastEdited: DateTime.now(),
    );
    await _box.put(updated.id, updated);
    return _captured(updated, page);
  }

  static CapturedStrategy _captured(StrategyData strategy, StrategyPage last) {
    return (
      id: strategy.id,
      name: strategy.name,
      map: strategy.mapData,
      source: StrategySource.local,
      pageCount: strategy.pages.length,
      lastPageId: last.id,
      lastPageIsAttack: last.isAttack,
    );
  }
}

/// Captures into the signed-in user's cloud library. A capture is stored on
/// this device with every id it will have in the cloud, and the
/// [ReplayCaptureQueue] sends it, so capturing never waits on the network
/// and captures made offline go once the connection is back.
///
/// Every item gets a fresh id, since the server keeps one row per item id
/// across all strategies and a replay's ids repeat in every strategy
/// captured from it. Each player keeps one root id across pages (see
/// [MovedItemIds]), so page transitions still pair them.
class CloudReplayCaptureStore implements ReplayCaptureStore {
  CloudReplayCaptureStore({
    required this.queue,
    required this.queueState,
    required this.accountId,
    required this.folderId,
    required this.settings,
    required this.themeProfileId,
  });

  final ReplayCaptureQueue queue;
  final ReplayCaptureQueueState Function() queueState;

  /// The account the strategy is made in.
  final String accountId;
  final String? folderId;
  final StrategySettings settings;
  final String? themeProfileId;

  final _ids = MovedItemIds();
  final _clientId = const Uuid().v4();
  var _captured = 0;

  @override
  Future<CapturedStrategy> create(
    MapValue map,
    String name,
    CapturedPage page,
  ) {
    return _store(
      strategyId: const Uuid().v4(),
      name: name,
      map: map,
      page: page,
    );
  }

  @override
  Future<CapturedStrategy?> append(
    CapturedStrategy strategy,
    CapturedPage page,
  ) async {
    if (_lost(strategy.id)) return null;
    return _store(
      strategyId: strategy.id,
      name: strategy.name,
      map: strategy.map,
      page: page,
    );
  }

  @override
  Future<CapturedStrategy?> find(CapturedStrategy strategy) async =>
      _lost(strategy.id) ? null : strategy;

  /// Whether delivering found the strategy deleted or on another map. The
  /// next capture then starts a new one.
  bool _lost(String strategyId) =>
      queueState().lostStrategyIds.contains(strategyId);

  Future<CapturedStrategy> _store({
    required String strategyId,
    required String name,
    required MapValue map,
    required CapturedPage page,
  }) async {
    const uuid = Uuid();
    final pageId = uuid.v4();
    final frame = page.frame;
    final items = <StrategyOp>[];
    appendMovedPageOps(
      items,
      StrategyPage(
        id: pageId,
        name: page.name,
        isAutoNamed: false,
        drawingData: const [],
        agentData: frame.agents,
        abilityData: frame.abilities,
        textData: const [],
        imageData: const [],
        utilityData: frame.utilities,
        sortIndex: 0,
        isAttack: frame.isAttack,
        settings: settings,
      ),
      cloudPageId: pageId,
      ids: _ids,
    );
    await queue.add(ReplayCaptureRecord(
      id: uuid.v4(),
      accountId: accountId,
      strategyId: strategyId,
      clientId: _clientId,
      strategyName: name,
      mapData: Maps.mapNames[map]!,
      folderId: folderId,
      themeProfileId: themeProfileId,
      index: _captured,
      createsStrategy: _captured == 0,
      createdAt: DateTime.now(),
      pageId: pageId,
      pageName: page.name,
      isAttack: frame.isAttack,
      settings: settings.toJson(),
      pageOpId: uuid.v4(),
      items: items,
    ));
    _captured++;
    return (
      id: strategyId,
      name: name,
      map: map,
      source: StrategySource.cloud,
      pageCount: _captured,
      lastPageId: pageId,
      lastPageIsAttack: frame.isAttack,
    );
  }
}
