import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
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

  /// The strategy captures go to, as the last capture or [reload] left it.
  CapturedStrategy? get strategy => _strategy;

  /// Saves [frame] as a page named [pageName] and returns the strategy.
  /// Refuses, without writing, a frame holding a non-finite number. If the
  /// user deleted the strategy or moved it to another map, this starts a
  /// new one rather than writing this map's positions into it.
  Future<CapturedStrategy> capture(
    ReplayFrame frame, {
    required String pageName,
  }) async {
    _checkFinite(frame);
    final page = (name: pageName, frame: frame);
    final store = _store;
    final current = _strategy;
    if (store != null && current != null) {
      final appended = await store.append(current, page);
      if (appended != null) return _strategy = appended;
    }
    final fresh = newStore();
    final created = await fresh.create(map, name, page);
    _store = fresh;
    return _strategy = created;
  }

  /// Reads the strategy again, after the editor may have changed it.
  Future<void> reload() async {
    final store = _store;
    final current = _strategy;
    if (store == null || current == null) return;
    final found = await store.find(current);
    if (found == null) _store = null;
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

/// A capture the user is told about in words: nothing was saved.
class CaptureRefused implements Exception {
  const CaptureRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

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
  /// nothing, when [strategy] is gone or now on another map.
  Future<CapturedStrategy?> append(
    CapturedStrategy strategy,
    CapturedPage page,
  );

  /// [strategy] as it is now; null when it is gone or now on another map.
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
      repository: ref.read(convexStrategyRepositoryProvider),
      accountId: accountId,
      currentAccountId: () => ref.read(cloudMediaAccountIdProvider),
      isOnline: () => ref.read(convexConnectionSnapshotProvider),
      folderId: ref
          .read(folderProvider.notifier)
          .currentFolderIdForWorkspace(LibraryWorkspace.cloud),
      settings: strategies.newStrategySettings(),
      themeProfileId:
          ref.read(mapThemeProfilesProvider).defaultProfileIdForNewStrategies,
    );
  };
});

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

/// Captures into the signed-in user's cloud library, straight to the
/// server: a capture lands whole (the page and everything on it) or throws.
/// Nothing is queued, so offline it refuses: a cloud strategy can't be made
/// offline, and the replay is still there to capture from once online.
///
/// Every item gets a fresh id, since the server keeps one row per item id
/// across all strategies and a replay's ids repeat in every strategy
/// captured from it. Each player keeps one root id across pages (see
/// [MovedItemIds]), so page transitions still pair them.
class CloudReplayCaptureStore implements ReplayCaptureStore {
  CloudReplayCaptureStore({
    required this.repository,
    required this.accountId,
    required this.currentAccountId,
    required this.isOnline,
    required this.folderId,
    required this.settings,
    required this.themeProfileId,
  });

  final ConvexStrategyRepository repository;

  /// The account the strategy is made in.
  final String accountId;
  final String? Function() currentAccountId;
  final bool Function() isOnline;
  final String? folderId;
  final StrategySettings settings;
  final String? themeProfileId;

  final _ids = MovedItemIds();
  final _clientId = const Uuid().v4();

  @override
  Future<CapturedStrategy> create(
    MapValue map,
    String name,
    CapturedPage page,
  ) async {
    _requireReachable();
    final id = const Uuid().v4();
    final pageId = const Uuid().v4();
    await repository.createStrategyWithInitialPage(
      publicId: id,
      name: name,
      mapData: Maps.mapNames[map]!,
      initialPagePublicId: pageId,
      initialPageName: page.name,
      initialPageIsAutoNamed: false,
      initialPageIsAttack: page.frame.isAttack,
      initialPageSettings: settings.toJson(),
      folderPublicId: folderId,
      themeProfileId: themeProfileId,
    );
    try {
      _requireAllLanded(await _send(id, _itemOps(page, pageId)));
    } catch (_) {
      // A strategy holding part of a moment, or none of it, is not what
      // the user captured.
      try {
        final shell = await repository.fetchShell(id);
        await repository.deleteStrategy(
          strategyPublicId: id,
          expectedRevision: shell.header.revision,
        );
      } catch (_) {
        throw const CaptureRefused(
          "Couldn't capture this moment. Part of it may be in your library "
          'as a new strategy.',
        );
      }
      rethrow;
    }
    return (
      id: id,
      name: name,
      map: map,
      source: StrategySource.cloud,
      pageCount: 1,
      lastPageId: pageId,
      lastPageIsAttack: page.frame.isAttack,
    );
  }

  @override
  Future<CapturedStrategy?> append(
    CapturedStrategy strategy,
    CapturedPage page,
  ) async {
    // Made under another account, it is out of reach under this one.
    if (currentAccountId() != accountId) return null;
    _requireReachable();
    final shell = await _shell(strategy);
    if (shell == null) return null;
    final pageId = const Uuid().v4();
    final pageOp = PageAddOp(
      opId: const Uuid().v4(),
      pagePublicId: pageId,
      payload: {
        'name': page.name,
        'isAutoNamed': false,
        'isAttack': page.frame.isAttack,
        'settings': settings.toJson(),
      },
      sortIndex: shell.pages.length,
      expectedStrategyRevision: shell.header.revision,
    );
    // One batch is one transaction: the page and its items land together,
    // unless the server refuses some of them.
    final acks = await _send(strategy.id, [pageOp, ..._itemOps(page, pageId)]);
    if (acks.whereType<AppliedOpAck>().any((ack) => ack.opId == pageOp.opId) &&
        acks.any((ack) => !ack.isAck)) {
      await _removePage(strategy.id, pageId);
    }
    _requireAllLanded(acks);
    return (
      id: strategy.id,
      name: shell.header.name,
      map: strategy.map,
      source: StrategySource.cloud,
      pageCount: shell.pages.length + 1,
      lastPageId: pageId,
      lastPageIsAttack: page.frame.isAttack,
    );
  }

  @override
  Future<CapturedStrategy?> find(CapturedStrategy strategy) async {
    if (currentAccountId() != accountId) return null;
    final shell = await _shell(strategy);
    if (shell == null) return null;
    final pages = [...shell.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    if (pages.isEmpty) return null;
    final last = pages.firstWhere(
      (page) => page.publicId == strategy.lastPageId,
      orElse: () => pages.last,
    );
    return (
      id: strategy.id,
      name: shell.header.name,
      map: strategy.map,
      source: StrategySource.cloud,
      pageCount: pages.length,
      lastPageId: last.publicId,
      lastPageIsAttack: last.isAttack,
    );
  }

  void _requireReachable() {
    if (currentAccountId() != accountId) {
      throw const CaptureRefused(
        "You signed in to another account, so this moment wasn't captured.",
      );
    }
    if (!isOnline()) {
      throw const CaptureRefused(
        "Can't reach the cloud, so this moment wasn't captured. "
        'Try again when you are online.',
      );
    }
  }

  /// [strategy]'s shell; null when the server no longer has it or it is
  /// now on another map.
  Future<RemoteStrategyShell?> _shell(CapturedStrategy strategy) async {
    try {
      final shell = await repository.fetchShell(strategy.id);
      return shell.header.mapData == Maps.mapNames[strategy.map] ? shell : null;
    } catch (error) {
      if (isTypedConvexNotFoundError(error)) return null;
      rethrow;
    }
  }

  List<StrategyOp> _itemOps(CapturedPage page, String pageId) {
    final frame = page.frame;
    final ops = <StrategyOp>[];
    appendMovedPageOps(
      ops,
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
    return ops;
  }

  Future<List<OpAck>> _send(String strategyId, List<StrategyOp> ops) async {
    // Bound to the account it was asked under: the server refuses it under
    // another sign-in.
    final acks = await repository.applyBatch(
      strategyPublicId: strategyId,
      clientId: _clientId,
      ops: ops,
      accountSubject: accountId,
    );
    if (acks.length != ops.length) {
      throw StateError('The server answered ${acks.length} of ${ops.length}.');
    }
    return acks;
  }

  static void _requireAllLanded(List<OpAck> acks) {
    final refused = acks.where((ack) => !ack.isAck).toList();
    if (refused.isEmpty) return;
    throw StateError(
      'The server did not accept every item: '
      '${refused.map((ack) => ack.reason ?? ack.status).toSet().join(', ')}',
    );
  }

  /// Takes back a page the server added without all of its items.
  Future<void> _removePage(String strategyId, String pageId) async {
    try {
      final shell = await repository.fetchShell(strategyId);
      final acks = await _send(strategyId, [
        PageDeleteOp(
          opId: const Uuid().v4(),
          pagePublicId: pageId,
          expectedStrategyRevision: shell.header.revision,
        ),
      ]);
      _requireAllLanded(acks);
    } catch (_) {
      throw const CaptureRefused(
        "Couldn't capture all of this moment. Its page may be missing "
        'players or utility.',
      );
    }
  }
}
