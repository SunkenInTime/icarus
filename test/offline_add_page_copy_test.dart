import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/drawn_cloud_pages_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_copy_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'collab/strategy_copy_fixtures.dart';

/// "+" in a cloud strategy while the server can't make the copy: this
/// computer copies the page, the new page opens and takes edits at once,
/// and everything lands once the connection is back. Runs the real queue,
/// editor snapshot, page session and outbox against a server that applies
/// ops the way convex/ops.ts does for what these tests send.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  late _Server server;
  late _Outbox outbox;
  late MemoryCloudStrategyCopyStore copies;

  setUp(() async {
    // This computer keeps the strategy's image files here.
    final files = await Directory.systemTemp.createTemp('offline_add_page');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProvider, (_) async => files.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(pathProvider, null);
      await files.delete(recursive: true);
    });
    server = _Server();
    outbox = _Outbox();
    copies = MemoryCloudStrategyCopyStore();
  });

  /// The app, started with [online] as the connection.
  Future<ProviderContainer> start({required bool online}) async {
    server.reachable = online;
    final connected = StateProvider<bool>((ref) => online);
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(
        ConvexStrategyRepository(IcarusConvexApi(server)),
      ),
      authProvider.overrideWith(_ReadyAuth.new),
      durableStrategyOutboxStoreProvider.overrideWithValue(outbox),
      convexConnectionSnapshotProvider
          .overrideWith((ref) => ref.watch(connected)),
      convexConnectionProvider
          .overrideWith((ref) => Stream.value(ref.watch(connected))),
      cloudOfflineProvider.overrideWith((ref) => !ref.watch(connected)),
      cloudStrategyCopyStoreProvider.overrideWithValue(copies),
      cloudCopyScopeProvider.overrideWith(
        (ref) => CloudCopyScope.begin(
          deploymentUrl: 'https://one.convex.cloud',
          accountId: 'account-a',
        ),
      ),
      strategyCopyRefresherProvider.overrideWith(_IdleRefresher.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue('account-a'),
      _connection.overrideWith((ref) => connected),
    ]);
    addTearDown(container.dispose);
    container.listen(strategyPageSessionProvider, (_, __) {});
    await container.read(remoteEditorSnapshotProvider.future);
    await container
        .read(remoteEditorSnapshotProvider.notifier)
        .openStrategy('strategy', activePagePublicId: 'p1');
    container.read(strategyProvider.notifier).setFromState(const StrategyState(
          strategyId: 'strategy',
          strategyName: 'Strategy',
          source: StrategySource.cloud,
          storageDirectory: null,
          isOpen: true,
        ));
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
          preferredPageId: 'p1',
        );
    await _settle();
    if (online) {
      // The page as this build saves it: what it rewrites on first open
      // (settings and payloads the fixtures leave in an older shape) lands
      // before the test starts.
      await _drain(container);
      server.landed.clear();
    }
    return container;
  }

  void setOnline(ProviderContainer container, bool online) {
    server.reachable = online;
    container.read(container.read(_connection).notifier).state = online;
  }

  /// Brings the connection back and lets the queue send until it is empty.
  Future<void> reconnect(ProviderContainer container) async {
    setOnline(container, true);
    await _drain(container);
  }

  /// Whether everything queued is for page 1 (the fixtures' rows are
  /// rewritten there as this build saves them).
  bool onlyPage1(ProviderContainer container) => container
      .read(strategyOpQueueProvider)
      .pending
      .every((pending) => pending.op.pagePublicId == 'p1');

  String? activePage(ProviderContainer container) =>
      container.read(strategyPageSessionProvider).activePageId;

  test('offline "+" copies the page here, with fresh ids, and opens it',
      () async {
    final app = await start(online: true);
    setOnline(app, false);

    final gaps = await app.read(strategyProvider.notifier).addPage();
    await _settle();

    expect(
        gaps, (unsavedEdits: false, waitingForCloud: false, notSaved: false));
    final pageId = activePage(app)!;
    expect(pageId, isNot('p1'));
    expect(server.pageIds, ['p1'], reason: 'nothing reached the server');
    final drawn = app.read(drawnCloudPagesProvider)!.pages;
    expect(drawn.map((page) => page.publicId), ['p1', pageId]);
    expect(drawn.last.name, 'Page 2');

    // The canvas shows the copy: the same items under copy ids.
    final agent = app.read(agentProvider).single;
    expect(agent.id, isNot('agent-1'));
    expect(pageCopyRoot(agent.id), 'agent-1');
    final image = app.read(placedImageProvider).images.single;
    expect(pageCopyRoot(image.id), 'image-1');
    expect(image.pictureId, 'picture-1');
    final lineups = app.read(lineUpProvider).graph;
    expect(lineups.links.map((link) => pageCopyRoot(link.id)), ['lineup-1']);
    expect(lineups.links.single.id, isNot('lineup-1'));
    expect(
      lineups.origins.map((spot) => spot.id),
      [lineups.links.single.originId],
    );
    expect(
      lineups.landings.map((spot) => spot.id),
      [lineups.links.single.landingId],
    );
    expect(lineups.origins.single.agent.lineUpID, lineups.origins.single.id);
    expect(
        lineups.landings.single.ability.lineUpID, lineups.landings.single.id);

    // Queued: the add, copying nothing on the server, then its content.
    final queued = app.read(strategyOpQueueProvider).pending.map((p) => p.op);
    final add = queued.whereType<PageAddOp>().single;
    expect(add.pagePublicId, pageId);
    expect(add.copyContentFromPagePublicId, isNull);
    expect(
      queued.whereType<ElementAddOp>().map((op) => op.elementPublicId),
      unorderedEquals([agent.id, image.id]),
    );
    expect(queued.whereType<LineupAddOp>().single.pagePublicId, pageId);
  });

  test(
      'the page made offline takes an edit, survives a restart, and lands '
      'once, add first, when the connection is back', () async {
    var app = await start(online: true);
    setOnline(app, false);
    await app.read(strategyProvider.notifier).addPage();
    await _settle();
    final pageId = activePage(app)!;
    final agentId = app.read(agentProvider).single.id;

    // An edit on the new page.
    app.read(agentProvider.notifier).updatePosition(
          const Offset(300, 200),
          agentId,
        );
    await app
        .read(strategyProvider.notifier)
        .notifyCloudMutation(flushImmediately: true);
    await _settle();

    // Restart, still offline: the page is listed and opens with the edit.
    app.dispose();
    app = await start(online: false);
    expect(
      app.read(drawnCloudPagesProvider)!.pages.map((page) => page.publicId),
      ['p1', pageId],
    );
    await app.read(strategyPageSessionProvider.notifier).setActivePage(pageId);
    await _settle();
    expect(activePage(app), pageId);
    expect(app.read(agentProvider).single.id, agentId);
    expect(app.read(agentProvider).single.position, const Offset(300, 200));
    expect(app.read(placedImageProvider).images, hasLength(1));
    expect(app.read(lineUpProvider).graph.links, hasLength(1));

    await reconnect(app);

    // Landed once each: the page first, then what it holds.
    expect(server.refused, isEmpty);
    expect(server.landed.first, isA<PageAddOp>());
    expect(
      (server.landed.first as PageAddOp).copyContentFromPagePublicId,
      isNull,
    );
    expect(server.landed.whereType<PageAddOp>(), hasLength(1));
    expect(server.landed.whereType<ElementAddOp>(), hasLength(2));
    expect(server.landed.whereType<LineupAddOp>(), hasLength(1));
    expect(server.missingPageReads, 0);
    expect(server.pageIds, ['p1', pageId]);
    final onPage = server.elementsOn(pageId);
    expect(onPage, hasLength(2));
    expect(onPage.keys, contains(agentId));
    final agentRow = onPage[agentId]!;
    expect(agentRow['revision'], 1, reason: 'the edit went with the add');
    final agentData =
        (agentRow['payload'] as Map)['data'] as Map<String, Object?>;
    expect((agentData['position'] as Map)['dx'], 300);
    final imageRow =
        onPage.values.singleWhere((row) => row['elementType'] == 'image');
    expect(
        ((imageRow['payload'] as Map)['data'] as Map)['assetId'], 'picture-1');
    expect(server.lineupsOn(pageId), hasLength(1));
    // The page on screen now reads from the server, and still matches.
    final shown = app.read(remoteEditorSnapshotProvider).valueOrNull!;
    expect(shown.activePage!.madeHere, isFalse);
    expect(activePage(app), pageId);
    expect(app.read(agentProvider).single.position, const Offset(300, 200));
    expect(app.read(strategyOpQueueProvider).pending, isEmpty);
  });

  test('a lineup group is copied as one row, every id new and linked',
      () async {
    final app = await start(online: true);
    setOnline(app, false);
    await app.read(strategyProvider.notifier).addPage();
    await _settle();
    final pageId = activePage(app)!;
    await reconnect(app);

    final source = server.lineupsOn('p1').values.single;
    final copy = server.lineupsOn(pageId).values.single;
    Map<String, Object?> data(Map<String, Object?> row) =>
        ((row['payload'] as Map)['data'] as Map).cast<String, Object?>();
    final from = data(source);
    final to = data(copy);
    expect(copy['publicId'], to['id']);
    expect(pageCopyRoot(to['id'] as String), from['id']);
    final link = (to['links'] as List).single as Map;
    final origin = (to['origins'] as List).single as Map;
    final landing = (to['landings'] as List).single as Map;
    expect(link['originId'], origin['id']);
    expect(link['landingId'], landing['id']);
    expect(pageCopyRoot(origin['id'] as String), 'lineup-1-origin');
    expect((origin['agent'] as Map)['lineUpID'], origin['id']);
    expect((landing['ability'] as Map)['lineUpID'], landing['id']);
    // The lineup's picture is the source's.
    expect(
      ((link['images'] as List).single as Map)['id'],
      (((from['links'] as List).single as Map)['images'] as List)
          .cast<Map>()
          .single['id'],
    );
  });

  test('online "+" still has the server make the copy, and nothing else',
      () async {
    final app = await start(online: true);

    final gaps = await app.read(strategyProvider.notifier).addPage();
    await _settle();

    expect(
        gaps, (unsavedEdits: false, waitingForCloud: false, notSaved: false));
    final add = server.landed.whereType<PageAddOp>().single;
    expect(add.copyContentFromPagePublicId, 'p1');
    // No item or lineup is sent for it: the server copies them.
    expect(server.landed.first, add);
    expect(server.landed.whereType<ElementAddOp>(), isEmpty);
    expect(server.landed.whereType<LineupAddOp>(), isEmpty);
    expect(activePage(app), add.pagePublicId);
    expect(server.elementsOn(add.pagePublicId), hasLength(2));
    expect(
      app.read(remoteEditorSnapshotProvider).valueOrNull!.activePage!.madeHere,
      isFalse,
    );
  });

  test('an add that waits unsent past the wait becomes this computer\'s copy',
      () async {
    final app = await start(online: true);
    StrategyProvider.cloudPageAddWait = const Duration(milliseconds: 200);
    addTearDown(
        () => StrategyProvider.cloudPageAddWait = const Duration(seconds: 5));
    // A send still out holds the add behind it.
    server.hold = Completer<void>();
    final agentId = app.read(agentProvider).single.id;
    app.read(agentProvider.notifier).updatePosition(
          const Offset(40, 40),
          agentId,
        );
    // Its send waits on the server's answer.
    unawaited(app
        .read(strategyProvider.notifier)
        .notifyCloudMutation(flushImmediately: true));
    await _settle();
    expect(app.read(strategyOpQueueProvider).inFlightByEntityKey, isNotEmpty);

    final gaps = await app.read(strategyProvider.notifier).addPage();
    await _settle();

    expect(gaps.waitingForCloud, isFalse);
    final pageId = activePage(app)!;
    expect(pageId, isNot('p1'));
    expect(pageCopyRoot(app.read(agentProvider).single.id), agentId);

    server.hold!.complete();
    server.hold = null;
    await reconnect(app);

    expect(server.refused, isEmpty);
    final add = server.landed.whereType<PageAddOp>().single;
    expect(add.pagePublicId, pageId);
    expect(add.copyContentFromPagePublicId, isNull);
    expect(server.elementsOn(pageId), hasLength(2));
  });
  group('the copy is stored whole', () {
    test('a write that fails stores nothing, adds no page, and says so',
        () async {
      final app = await start(online: true);
      setOnline(app, false);
      outbox.failPutAll = true;

      final gaps = await app.read(strategyProvider.notifier).addPage();
      await _settle();

      expect(gaps.notSaved, isTrue);
      expect(activePage(app), 'p1');
      expect(app.read(drawnCloudPagesProvider)!.pages, hasLength(1));
      expect(onlyPage1(app), isTrue);
      expect(app.read(strategyOpQueueProvider).hasDurabilityFailure, isTrue);
      expect(
        outbox.values.values.whereType<Map>().where(
            (json) => json['outboxVersion'] == pageChangeOutboxRecordVersion),
        isEmpty,
      );
    });

    test('the add and everything it holds go in one write', () async {
      final app = await start(online: true);
      setOnline(app, false);

      await app.read(strategyProvider.notifier).addPage();
      await _settle();

      final write = outbox.putAllCalls.single;
      expect(write.map((r) => r.pending.op.runtimeType).toSet(),
          {PageAddOp, ElementAddOp, LineupAddOp});
      expect(write, hasLength(4));
    });

    test('a write cut off before it lands leaves no page and no stray items',
        () async {
      var app = await start(online: true);
      setOnline(app, false);
      // The app dies while the copy is being written.
      outbox.holdPutAll = Completer<void>();
      unawaited(app.read(strategyProvider.notifier).addPage());
      await _settle();
      expect(outbox.putAllCalls, isEmpty);
      app.dispose();
      outbox.holdPutAll = null;

      app = await start(online: false);
      expect(app.read(drawnCloudPagesProvider)!.pages, hasLength(1));
      expect(onlyPage1(app), isTrue);
    });

    test('a strategy switch while the copy is written keeps it in its strategy',
        () async {
      final app = await start(online: true);
      setOnline(app, false);
      final held = outbox.holdPutAll = Completer<void>();
      final adding = app.read(strategyProvider.notifier).addPage();
      await _settle();
      app
          .read(strategyOpQueueProvider.notifier)
          .setActiveStrategy('another', accountId: 'account-a');
      outbox.holdPutAll = null;
      held.complete();
      await adding;

      final written = outbox.putAllCalls.single;
      expect(written.map((r) => r.strategyPublicId).toSet(), {'strategy'});
    });

    test('its items are stored where a build before the list leaves them',
        () async {
      final app = await start(online: true);
      setOnline(app, false);
      await app.read(strategyProvider.notifier).addPage();
      await _settle();

      final content = outbox.values.values
          .whereType<Map>()
          .where((json) =>
              '${json['entityKey']}'.startsWith('element:') ||
              '${json['entityKey']}'.startsWith('lineup:'))
          .where((json) => '${json['entityKey']}'.contains(activePage(app)!))
          .toList();
      expect(content, hasLength(3));
      expect(content.map((json) => json['outboxVersion']).toSet(),
          {pageChangeOutboxRecordVersion});
      // A new item on the page is stored the same way while its add waits.
      app.read(agentProvider.notifier).addAgent(PlacedAgent(
            id: 'placed-on-new-page',
            type: AgentType.sova,
            position: const Offset(300, 300),
          ));
      await app
          .read(strategyProvider.notifier)
          .notifyCloudMutation(flushImmediately: true);
      await _settle();
      final placed = outbox.values.values.whereType<Map>().singleWhere(
          (json) => '${json['entityKey']}'.endsWith('placed-on-new-page'));
      expect(placed['outboxVersion'], pageChangeOutboxRecordVersion);
    });
  });

  test('a server copy still on its way does not open as an empty page',
      () async {
    final app = await start(online: true);
    StrategyProvider.cloudPageAddWait = const Duration(milliseconds: 200);
    addTearDown(
        () => StrategyProvider.cloudPageAddWait = const Duration(seconds: 5));
    // The add is sent, and its answer doesn't come.
    server.hold = Completer<void>();

    final gaps = await app.read(strategyProvider.notifier).addPage();
    await _settle();
    expect(gaps.waitingForCloud, isTrue);
    final pageId = app
        .read(drawnCloudPagesProvider)!
        .pages
        .map((page) => page.publicId)
        .singleWhere((id) => id != 'p1');

    await expectLater(
      app.read(remoteEditorSnapshotProvider.notifier).fetchPage(pageId),
      throwsA(anything),
    );
    server.hold!.complete();
    server.hold = null;
    await _settle();
  });
}

/// Lets the queue send until it is empty.
Future<void> _drain(ProviderContainer container) async {
  final queue = container.read(strategyOpQueueProvider.notifier);
  for (var i = 0; i < 20; i++) {
    await queue.flushNow();
    await _settle();
    if (container.read(strategyOpQueueProvider).pending.isEmpty) break;
  }
  await _settle();
}

final _connection =
    Provider<StateProvider<bool>>((ref) => throw UnimplementedError());

Future<void> _settle() async {
  for (var i = 0; i < 20; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

class _Page {
  _Page(this.id, {required this.sortIndex, this.name, this.isAutoNamed = true});

  final String id;
  int sortIndex;
  String? name;
  bool isAutoNamed;
  bool isAttack = true;
  int revision = 1;
  Object? settings;
  int contentRevision = 1;
}

/// A server holding one strategy, its first page with an agent, an image
/// and a lineup group. It answers shell and page reads, and applies page,
/// element and lineup ops as convex/ops.ts does (no field merge).
final class _Server implements ConvexTransport {
  _Server() {
    pages.add(_Page('p1', sortIndex: 0));
    elements['agent-1'] = agentRow('agent-1', 'p1');
    elements['image-1'] = imageRow('image-1', 'p1', 'picture-1');
    lineups['lineup-1'] = lineupRow('lineup-1', 'p1', 'lineup-picture');
  }

  final pages = <_Page>[];
  final elements = <String, Map<String, Object?>>{};
  final lineups = <String, Map<String, Object?>>{};
  int revision = 1;
  bool reachable = true;

  /// While set, a batch waits for it before the server takes it.
  Completer<void>? hold;

  /// Reads of a page the server does not have.
  int missingPageReads = 0;

  /// Every op applied, in order, and every one refused.
  final landed = <StrategyOp>[];
  final refused = <OpAck>[];
  final _answers = <String, Map<String, Object?>>{};

  final _shellWatchers = <StreamController<ConvexValue>>[];
  final _pageWatchers = <String, List<StreamController<ConvexValue>>>{};

  List<String> get pageIds =>
      ([...pages]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)))
          .map((page) => page.id)
          .toList();

  Map<String, Map<String, Object?>> elementsOn(String pageId) => {
        for (final MapEntry(:key, :value) in elements.entries)
          if (value['pagePublicId'] == pageId && value['deleted'] != true)
            key: value,
      };

  Map<String, Map<String, Object?>> lineupsOn(String pageId) => {
        for (final MapEntry(:key, :value) in lineups.entries)
          if (value['pagePublicId'] == pageId && value['deleted'] != true)
            key: value,
      };

  _Page? _page(String id) => pages.where((page) => page.id == id).firstOrNull;

  Map<String, Object?> _pageRow(_Page page) => {
        ...pageRow(page.id,
            revision: page.revision,
            sortIndex: page.sortIndex,
            name: page.name ?? 'Page ${page.sortIndex + 1}'),
        'isAutoNamed': page.isAutoNamed,
        'isAttack': page.isAttack,
      };

  ConvexValue _shell() => ConvexValue.fromDart({
        'header': headerRow(revision: revision),
        'pages': [
          for (final id in pageIds) _pageRow(_page(id)!),
        ],
      });

  ConvexValue _pageSnapshot(String pageId) {
    final page = _page(pageId);
    if (page == null) {
      missingPageReads += 1;
      throw const ConvexTransportError(rawCode: 'NOT_FOUND', message: 'page');
    }
    final pictures = {
      for (final row in elementsOn(pageId).values)
        if (row['elementType'] == 'image')
          ((row['payload'] as Map)['data'] as Map)['assetId'] as String,
    };
    return ConvexValue.fromDart({
      'page': _pageRow(page),
      'content': {
        ...contentRow(revision: page.contentRevision),
        'settings': page.settings,
      },
      'elements': elementsOn(pageId).values.toList(),
      'lineups': lineupsOn(pageId).values.toList(),
      'assets': [for (final id in pictures) assetRow(id)],
    });
  }

  void _publish() {
    for (final watcher in _shellWatchers) {
      watcher.add(_shell());
    }
    for (final MapEntry(:key, :value) in _pageWatchers.entries) {
      if (_page(key) == null) continue;
      for (final watcher in value) {
        watcher.add(_pageSnapshot(key));
      }
    }
  }

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async {
    if (!reachable) throw TimeoutException('no answer');
    return switch (name) {
      'strategy:getShell' => _shell(),
      'page:getSnapshot' =>
        _pageSnapshot(args.value['pagePublicId']!.toDart() as String),
      _ => throw UnimplementedError(name),
    };
  }

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    final controller = StreamController<ConvexValue>.broadcast();
    switch (name) {
      case 'strategy:getShell':
        _shellWatchers.add(controller);
      case 'page:getSnapshot':
        final pageId = args.value['pagePublicId']!.toDart() as String;
        (_pageWatchers[pageId] ??= []).add(controller);
    }
    return controller.stream;
  }

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) async {
    if (name != 'ops:applyBatch') throw UnimplementedError(name);
    await hold?.future;
    if (!reachable) throw TimeoutException('no answer');
    final ops = [
      for (final op in args.value['ops']!.toDart() as List)
        StrategyOp.fromJson(Map<String, dynamic>.from(op as Map)),
    ];
    final results = [for (final op in ops) _apply(op)];
    _publish();
    return ConvexValue.fromDart({
      'results': results,
      'strategyPublicId': 'strategy',
    });
  }

  Map<String, Object?> _apply(StrategyOp op) {
    final answered = _answers[op.opId];
    if (answered != null) {
      return {
        'status': 'noop',
        'opId': op.opId,
        'currentRevision': answered['appliedRevision'] ?? revision,
      };
    }
    final answer = switch (op) {
      PageAddOp() => _addPage(op),
      ElementAddOp() => _addRow(elements, op.elementPublicId, op, 'image'),
      LineupAddOp() => _addRow(lineups, op.lineupPublicId, op, null),
      ElementPatchOp() => _patchRow(elements, op.elementPublicId, op),
      LineupPatchOp() => _patchRow(lineups, op.lineupPublicId, op),
      PageContentPatchOp() => _patchContent(op),
      _ => throw UnimplementedError('${op.type}'),
    };
    _answers[op.opId] = answer;
    if (answer['status'] == 'applied') {
      landed.add(op);
    } else {
      refused.add(OpAck.fromJson(answer));
    }
    return answer;
  }

  Map<String, Object?> _patchContent(PageContentPatchOp op) {
    final page = _page(op.pagePublicId)!;
    if (op.expectedRevision != page.contentRevision) {
      return _refuse(op, 'revision_mismatch');
    }
    page
      ..settings = op.settings
      ..contentRevision += 1;
    return {
      'status': 'applied',
      'opId': op.opId,
      'appliedRevision': page.contentRevision,
    };
  }

  Map<String, Object?> _refuse(StrategyOp op, String reason) =>
      {'status': 'rejected', 'opId': op.opId, 'reason': reason};

  Map<String, Object?> _addPage(PageAddOp op) {
    if (op.expectedRevision != revision) {
      return _refuse(op, 'revision_mismatch');
    }
    final ordered = [for (final id in pageIds) _page(id)!];
    final at = op.sortIndex.clamp(0, ordered.length);
    final page = _Page(
      op.pagePublicId,
      sortIndex: at,
      name: op.payload['name'] as String?,
      isAutoNamed: op.payload['isAutoNamed'] == true,
    )
      ..isAttack = op.payload['isAttack'] as bool? ?? true
      ..settings = op.payload['settings'];
    ordered.insert(at, page);
    for (final (index, each) in ordered.indexed) {
      if (each.sortIndex != index) {
        each
          ..sortIndex = index
          ..revision += 1;
      }
      if (each.isAutoNamed) each.name = 'Page ${index + 1}';
    }
    pages.add(page);
    if (op.copyContentFromPagePublicId case final from?) {
      // The server's copy (convex/lib/contentCopy.ts), as far as these
      // tests need it: rows under copy ids, images keeping their picture.
      for (final row in elementsOn(from).values.toList()) {
        final id = newPageCopyId(row['publicId'] as String);
        final payload = Map<String, Object?>.from(row['payload'] as Map);
        final data = Map<String, Object?>.from(payload['data'] as Map);
        elements[id] = {
          ...row,
          'publicId': id,
          'pagePublicId': op.pagePublicId,
          'payload': {
            ...payload,
            'data': {
              ...data,
              'id': id,
              if (row['elementType'] == 'image')
                'assetId': data['assetId'] ?? row['publicId'],
            },
          },
          'revision': 1,
        };
      }
    }
    revision += 1;
    return {'status': 'applied', 'opId': op.opId, 'appliedRevision': revision};
  }

  Map<String, Object?> _addRow(
    Map<String, Map<String, Object?>> rows,
    String id,
    StrategyOp op,
    String? unused,
  ) {
    final page = _page(op.pagePublicId!);
    if (page == null) return _refuse(op, 'not_found');
    if (rows[id] case final existing? when existing['deleted'] != true) {
      return _refuse(op, 'already_exists');
    }
    final payload = op.payload as Map<String, dynamic>;
    rows[id] = {
      'publicId': id,
      'strategyPublicId': 'strategy',
      'pagePublicId': op.pagePublicId,
      if (op is ElementAddOp) 'elementType': payload['kind'],
      'payload': payload,
      'sortIndex': op.sortIndex,
      'revision': 1,
      'deleted': false,
      'createdAt': 1.0,
      'updatedAt': 1.0,
    };
    return {'status': 'applied', 'opId': op.opId, 'appliedRevision': 1};
  }

  Map<String, Object?> _patchRow(
    Map<String, Map<String, Object?>> rows,
    String id,
    StrategyOp op,
  ) {
    final row = rows[id];
    if (row == null || row['deleted'] == true) return _refuse(op, 'not_found');
    if (op.expectedRevision != row['revision']) {
      return _refuse(op, 'revision_mismatch');
    }
    final next = (row['revision'] as int) + 1;
    rows[id] = {
      ...row,
      if (op.payload != null) 'payload': op.payload,
      if (op.sortIndex != null) 'sortIndex': op.sortIndex,
      'revision': next,
    };
    return {'status': 'applied', 'opId': op.opId, 'appliedRevision': next};
  }

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError(name);
}

class _ReadyAuth extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: <String, dynamic>{},
          userMetadata: <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _IdleRefresher extends StrategyCopyRefresher {
  @override
  void build() {}

  @override
  void keepOpenedStrategy(String strategyId) {}
}

/// The outbox, with the copy's one write observable and breakable.
class _Outbox extends MemoryDurableStrategyOutboxStore {
  bool failPutAll = false;
  Completer<void>? holdPutAll;
  final putAllCalls = <List<DurableOutboxRecord>>[];

  @override
  Future<void> putAll(List<DurableOutboxRecord> records) async {
    await holdPutAll?.future;
    if (failPutAll) throw const FileSystemException('disk full');
    putAllCalls.add(records);
    await super.putAll(records);
  }
}

class _IdleMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);
}
