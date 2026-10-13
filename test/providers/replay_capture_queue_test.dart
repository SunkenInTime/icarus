import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/collab/replay_capture_record.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/replay_capture_queue_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/replay/replay_capture.dart';
import 'package:icarus/replay/replay_frame.dart';

final _online = StateProvider<bool>((ref) => true);

ReplayFrame _frame(double x) => ReplayFrame(
      timeMs: 1000,
      round: null,
      isAttack: false,
      agents: [
        PlacedViewConeAgent(
          id: 'replay-player-a',
          type: AgentType.jett,
          position: Offset(x, 500),
          presetType: UtilityType.viewCone180,
          rotation: 1,
          length: 100,
        ),
      ],
      abilities: const [],
      utilities: const [],
    );

void main() {
  late Directory dir;
  late _FakeCloud cloud;
  late ProviderContainer container;

  ProviderContainer open() {
    return container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(cloud),
      authProvider.overrideWith(_CloudReadyAuth.new),
      cloudMediaAccountIdProvider.overrideWithValue('account-1'),
      convexConnectionSnapshotProvider
          .overrideWith((ref) => ref.watch(_online)),
      convexConnectionProvider
          .overrideWith((ref) => Stream.value(ref.watch(_online))),
    ]);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('replay_capture_queue_test');
    Hive.init(dir.path);
    await Hive.openBox<String>(HiveBoxNames.replayCapturesBox);
    cloud = _FakeCloud();
    ReplayCaptureQueue.retryDelay = const Duration(hours: 1);
    open();
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  ReplayCaptureQueue queue() =>
      container.read(replayCaptureQueueProvider.notifier);
  ReplayCaptureQueueState queued() =>
      container.read(replayCaptureQueueProvider);
  void setOnline(bool online) =>
      container.read(_online.notifier).state = online;

  ReplayCapture session() => ReplayCapture(
        newStore: () => CloudReplayCaptureStore(
          queue: queue(),
          queueState: queued,
          accountId: 'account-1',
          folderId: null,
          settings: StrategySettings(),
          themeProfileId: null,
        ),
        map: MapValue.sunset,
        name: 'Sunset replay',
      );

  Future<ReplayCapture> captureThree() async {
    final replay = session();
    for (final (i, name) in ['0:10', '0:20', '0:30'].indexed) {
      await replay.capture(_frame(500 + 10.0 * i), pageName: name);
    }
    return replay;
  }

  test('offline, captures are kept here and sent in order once online',
      () async {
    setOnline(false);
    final replay = await captureThree();
    expect(cloud.calls, 0);
    expect(queued().captures, hasLength(3));

    setOnline(true);
    await queue().sendNow();

    expect(queued().captures, isEmpty);
    final strategy = cloud.strategies.values.single;
    expect(strategy.name, 'Sunset replay');
    expect(strategy.orderedPages.map((page) => page.name),
        ['0:10', '0:20', '0:30']);
    expect(strategy.orderedPages.last.id, replay.strategy!.lastPageId);
    // One player on every page under ids of one root, so the page
    // transition moves it.
    final ids = [
      for (final page in strategy.orderedPages)
        cloud.elementsOn(page.id).single,
    ];
    expect(ids.toSet(), hasLength(3));
    expect(ids, everyElement(isNot('replay-player-a')));
    expect(ids.map(pageCopyRoot).toSet(), {ids.first});
  });

  test('sent again after lost answers, nothing lands twice', () async {
    cloud.loseAnswers = true;
    await captureThree();
    for (var i = 0; i < 4; i++) {
      await queue().sendNow();
    }
    expect(queued().captures, isNotEmpty);
    expect(queued().captures.where((c) => c.isFailed), isEmpty);

    cloud.loseAnswers = false;
    for (var i = 0; i < 3; i++) {
      await queue().sendNow();
    }

    expect(queued().captures, isEmpty);
    final strategy = cloud.strategies.values.single;
    expect(strategy.orderedPages, hasLength(3));
    expect(cloud.elements, hasLength(3));
  });

  test('captures left when the app quit are sent when it starts', () async {
    setOnline(false);
    await captureThree();
    container.dispose();
    await Hive.close();
    Hive.init(dir.path);
    await Hive.openBox<String>(HiveBoxNames.replayCapturesBox);

    open();
    expect(queued().captures, hasLength(3));
    await queue().sendNow();

    expect(queued().captures, isEmpty);
    expect(cloud.strategies.values.single.orderedPages, hasLength(3));
  });

  test('a strategy changed meanwhile gets the page under a new op id',
      () async {
    final replay = session();
    await replay.capture(_frame(500), pageName: 'one');
    await queue().sendNow();
    cloud.editBeforeNextPageAdd = true;

    await replay.capture(_frame(510), pageName: 'two');
    await queue().sendNow();

    expect(queued().captures, isEmpty);
    expect(cloud.strategies.values.single.orderedPages.map((p) => p.name),
        ['one', 'two']);
  });

  test('a refused capture waits; Retry sends it under new op ids', () async {
    final replay = session();
    await replay.capture(_frame(500), pageName: 'one');
    await queue().sendNow();
    cloud.refuseItems = 1;

    await replay.capture(_frame(510), pageName: 'two');
    await replay.capture(_frame(520), pageName: 'three');
    await queue().sendNow();

    final [refused, behind] = queued().captures;
    expect(refused.failure, CaptureFailureKind.refused);
    expect(refused.pageLanded, isTrue);
    expect(behind.isFailed, isFalse, reason: 'held back, not refused');
    expect(cloud.strategies.values.single.orderedPages, hasLength(2));

    await queue().retry([refused.id]);
    await queue().sendNow();

    expect(queued().captures, isEmpty);
    final strategy = cloud.strategies.values.single;
    expect(strategy.orderedPages.map((p) => p.name), ['one', 'two', 'three']);
    expect(cloud.elements, hasLength(3));
  });

  test('a deleted strategy fails its captures; the next starts a new one',
      () async {
    final replay = session();
    final first = await replay.capture(_frame(500), pageName: 'one');
    await queue().sendNow();
    cloud.strategies.remove(first.id);

    setOnline(false);
    await replay.capture(_frame(510), pageName: 'two');
    await replay.capture(_frame(520), pageName: 'three');
    setOnline(true);
    await queue().sendNow();
    expect(
      queued().captures.map((c) => c.failure),
      [CaptureFailureKind.deleted, CaptureFailureKind.deleted],
    );

    // Discarded, they still leave the strategy known to be gone.
    await queue().discard([for (final c in queued().captures) c.id]);
    final next = await replay.capture(_frame(530), pageName: 'four');
    await queue().sendNow();
    expect(next.id, isNot(first.id));
    expect(cloud.strategies[next.id]!.orderedPages.single.name, 'four');
  });

  test('a strategy moved to another map is not written to', () async {
    final replay = session();
    final first = await replay.capture(_frame(500), pageName: 'one');
    await queue().sendNow();
    cloud.strategies[first.id]!.mapData = Maps.mapNames[MapValue.ascent]!;

    await replay.capture(_frame(510), pageName: 'two');
    await queue().sendNow();

    expect(queued().captures.single.failure, CaptureFailureKind.mapChanged);
    expect(cloud.strategies[first.id]!.orderedPages, hasLength(1));
  });

  test('discarding the first capture lets the next make the strategy',
      () async {
    setOnline(false);
    await captureThree();
    final mayHaveLanded = await queue().discard([queued().captures.first.id]);
    expect(mayHaveLanded, isFalse);

    setOnline(true);
    await queue().sendNow();

    expect(queued().captures, isEmpty);
    expect(cloud.strategies.values.single.orderedPages.map((p) => p.name),
        ['0:20', '0:30']);
  });

  test('a capture whose answer was lost may still land when discarded',
      () async {
    cloud.loseAnswers = true;
    await session().capture(_frame(500), pageName: 'one');
    await queue().sendNow();

    expect(await queue().discard([queued().captures.single.id]), isTrue);
  });

  test('a record this build cannot read is kept and counted', () async {
    final box = Hive.box<String>(HiveBoxNames.replayCapturesBox);
    await box.put('future', jsonEncode({'version': 99}));
    container.dispose();
    open();

    expect(queued().unreadable, 1);
    expect(queued().isReliable, isFalse);
    await queue().sendNow();
    expect(box.get('future'), isNotNull);
  });
}

class _CloudReadyAuth extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

class _Page {
  _Page(this.id, this.name, this.sortIndex, this.isAttack);

  final String id;
  final String name;
  final int sortIndex;
  final bool isAttack;
}

class _Strategy {
  _Strategy(this.name, this.mapData);

  final String name;
  String mapData;
  int revision = 1;
  final List<_Page> pages = [];

  List<_Page> get orderedPages =>
      [...pages]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
}

class _Element {
  _Element(this.strategyId, this.pageId, this.payload);

  final String strategyId;
  final String pageId;
  final String payload;
}

/// The server as captures meet it: client-chosen ids, a repeated op id
/// answered with its first answer, an identical page or item answered
/// without writing, one row per item id across strategies, page adds
/// checked against the strategy's revision.
class _FakeCloud extends Fake implements ConvexStrategyRepository {
  final Map<String, _Strategy> strategies = {};
  final Map<String, _Element> elements = {};
  final Map<String, OpAck> _answered = {};
  var calls = 0;

  /// Writes, then loses the answer, as a timeout does.
  bool loseAnswers = false;

  /// Item adds to refuse before accepting again.
  int refuseItems = 0;

  /// Someone edits the strategy just before the next page add arrives.
  bool editBeforeNextPageAdd = false;

  List<String> elementsOn(String pageId) => [
        for (final MapEntry(:key, :value) in elements.entries)
          if (value.pageId == pageId) key,
      ];

  static const _notFound = ConvexFunctionException(
    code: ConvexErrorCode.notFound,
    rawCode: 'NOT_FOUND',
    message: 'Not found.',
  );

  void _answer() {
    calls++;
    if (loseAnswers) throw TimeoutException('lost');
  }

  @override
  Future<void> createStrategyWithInitialPage({
    required String publicId,
    required String name,
    required String mapData,
    required String initialPagePublicId,
    required String initialPageName,
    bool? initialPageIsAutoNamed,
    required bool initialPageIsAttack,
    String? folderPublicId,
    String? themeProfileId,
    Map<String, dynamic>? themeOverridePalette,
    Map<String, dynamic>? initialPageSettings,
    bool unfinishedMove = false,
  }) async {
    final strategy =
        strategies.putIfAbsent(publicId, () => _Strategy(name, mapData));
    if (strategy.pages.isEmpty) {
      strategy.pages.add(_Page(
        initialPagePublicId,
        initialPageName,
        0,
        initialPageIsAttack,
      ));
    }
    _answer();
  }

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    calls++;
    final strategy = strategies[strategyPublicId];
    if (strategy == null) throw _notFound;
    final now = DateTime.now();
    return RemoteStrategyShell(
      header: RemoteStrategyHeader(
        publicId: strategyPublicId,
        name: strategy.name,
        mapData: strategy.mapData,
        revision: strategy.revision,
        createdAt: now,
        updatedAt: now,
      ),
      pages: [
        for (final page in strategy.pages)
          RemotePage(
            publicId: page.id,
            strategyPublicId: strategyPublicId,
            name: page.name,
            sortIndex: page.sortIndex,
            isAttack: page.isAttack,
            revision: 1,
            createdAt: now,
            updatedAt: now,
          ),
      ],
    );
  }

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    final strategy = strategies[strategyPublicId];
    if (strategy == null) throw _notFound;
    final acks = <OpAck>[];
    for (final op in ops) {
      final key = '$strategyPublicId|$clientId|${op.opId}';
      final answered = _answered[key];
      if (answered != null) {
        acks.add(answered is AppliedOpAck
            ? NoopOpAck(opId: op.opId, currentRevision: answered.revision)
            : answered);
        continue;
      }
      final ack = _apply(strategyPublicId, strategy, op);
      _answered[key] = ack;
      acks.add(ack);
    }
    _answer();
    return acks;
  }

  OpAck _apply(String strategyId, _Strategy strategy, StrategyOp op) {
    OpAck reject(OpRejectionReason reason) =>
        RejectedOpAck(opId: op.opId, rejectionReason: reason);
    OpAck applied() =>
        AppliedOpAck(opId: op.opId, revision: ++strategy.revision);
    switch (op) {
      case PageAddOp():
        if (editBeforeNextPageAdd) {
          editBeforeNextPageAdd = false;
          strategy.revision++;
        }
        final existing =
            strategy.pages.where((p) => p.id == op.pagePublicId).firstOrNull;
        if (existing != null) {
          return existing.name == op.payload['name']
              ? NoopOpAck(opId: op.opId)
              : reject(OpRejectionReason.alreadyExists);
        }
        if (op.expectedStrategyRevision != strategy.revision) {
          return reject(OpRejectionReason.revisionMismatch);
        }
        strategy.pages.add(_Page(
          op.pagePublicId,
          op.payload['name'] as String,
          op.sortIndex,
          op.payload['isAttack'] as bool,
        ));
        return applied();
      case ElementAddOp():
        if (refuseItems > 0) {
          refuseItems--;
          return reject(OpRejectionReason.alreadyExists);
        }
        final payload = jsonEncode(op.payload);
        final existing = elements[op.elementPublicId];
        if (existing != null) {
          return existing.strategyId == strategyId &&
                  existing.pageId == op.pagePublicId &&
                  existing.payload == payload
              ? NoopOpAck(opId: op.opId)
              : reject(OpRejectionReason.alreadyExists);
        }
        if (!strategy.pages.any((p) => p.id == op.pagePublicId)) {
          return reject(OpRejectionReason.notFound);
        }
        elements[op.elementPublicId] =
            _Element(strategyId, op.pagePublicId, payload);
        return applied();
      default:
        throw UnimplementedError('${op.type}');
    }
  }
}
