import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/replay/replay_capture.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:uuid/uuid.dart';

/// What the library's New Strategy makes: one blank page.
Future<StrategyData> createBlankStrategy(MapValue map, String name) async {
  final strategy = StrategyData(
    id: const Uuid().v4(),
    name: name,
    mapData: map,
    versionNumber: Settings.versionNumber,
    lastEdited: DateTime.now(),
    folderID: null,
    pages: [
      StrategyPage(
        id: const Uuid().v4(),
        name: 'Page 1',
        isAutoNamed: true,
        drawingData: const [],
        agentData: const [],
        abilityData: const [],
        textData: const [],
        imageData: const [],
        utilityData: const [],
        sortIndex: 0,
        isAttack: true,
        settings: StrategySettings(),
      ),
    ],
  );
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(strategy.id, strategy);
  return strategy;
}

ReplayFrame frame({Offset position = const Offset(500, 500)}) => ReplayFrame(
      timeMs: 1000,
      round: null,
      isAttack: false,
      agents: [
        PlacedViewConeAgent(
          id: 'replay-player-a',
          type: AgentType.jett,
          position: position,
          presetType: UtilityType.viewCone180,
          rotation: 1,
          length: 100,
        ),
      ],
      abilities: const [],
      utilities: const [],
    );

void main() {
  late Directory temp;
  late Box<StrategyData> box;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('icarus-replay-capture');
    Hive.init(temp.path);
    registerIcarusAdapters(Hive);
  });

  setUp(() async {
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await box.clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  group('signed out', () {
    ReplayCapture capture() => ReplayCapture(
          newStore: () => LocalReplayCaptureStore(createBlankStrategy),
          map: MapValue.sunset,
          name: 'Sunset replay',
        );

    test('captures fill one strategy, the first replacing its blank page',
        () async {
      final session = capture();
      await session.capture(frame(), pageName: 'Round 1 · 0:10');
      await session.capture(frame(), pageName: 'Round 1 · 0:20');

      final strategy = box.values.single;
      expect(strategy.name, 'Sunset replay');
      expect(strategy.mapData, MapValue.sunset);
      expect(strategy.pages.map((page) => page.name),
          ['Round 1 · 0:10', 'Round 1 · 0:20']);
      expect(strategy.pages.map((page) => page.sortIndex), [0, 1]);
      expect(strategy.pages.last.id, session.strategy!.lastPageId);
      expect(session.strategy!.pageCount, 2);
      final page = strategy.pages.first;
      expect(page.isAttack, isFalse);
      final agent = page.agentData.single as PlacedViewConeAgent;
      expect(agent.id, 'replay-player-a');
      expect(agent.position, const Offset(500, 500));
    });

    test('a deleted or re-mapped strategy is never written to again', () async {
      final session = capture();
      final first = await session.capture(frame(), pageName: 'one');
      await box.delete(first.id);

      final second = await session.capture(frame(), pageName: 'two');
      expect(second.id, isNot(first.id));
      expect(box.get(second.id)!.pages.single.name, 'two');

      await box.put(
        second.id,
        box.get(second.id)!.copyWith(mapData: MapValue.ascent),
      );
      final third = await session.capture(frame(), pageName: 'three');
      expect(third.id, isNot(second.id));
      expect(box.get(second.id)!.pages.single.name, 'two');
    });

    test('a frame off the map is refused before anything is written', () async {
      final session = capture();
      await expectLater(
        session.capture(
          frame(position: const Offset(double.nan, 0)),
          pageName: 'bad',
        ),
        throwsStateError,
      );
      expect(box.isEmpty, isTrue);
    });

    test('a utility turned by a non-finite angle is refused too', () async {
      final spike = PlacedUtility(
        id: 'replay-spike-0',
        type: UtilityType.spike,
        position: const Offset(500, 500),
      )..rotation = double.infinity;
      await expectLater(
        capture().capture(
          ReplayFrame(
            timeMs: 0,
            round: null,
            isAttack: true,
            agents: const [],
            abilities: const [],
            utilities: [spike],
          ),
          pageName: 'bad',
        ),
        throwsStateError,
      );
      expect(box.isEmpty, isTrue);
    });
  });

  group('signed in', () {
    late _FakeCloud cloud;
    var online = true;
    String? account = 'account-1';

    setUp(() {
      cloud = _FakeCloud();
      online = true;
      account = 'account-1';
    });

    ReplayCapture capture() => ReplayCapture(
          newStore: () => CloudReplayCaptureStore(
            repository: cloud,
            accountId: 'account-1',
            currentAccountId: () => account,
            isOnline: () => online,
            folderId: null,
            settings: StrategySettings(),
            themeProfileId: null,
          ),
          map: MapValue.sunset,
          name: 'Sunset replay',
        );

    test('captures fill one cloud strategy whose players pair across pages',
        () async {
      final session = capture();
      for (final (i, name) in ['0:10', '0:20', '0:30'].indexed) {
        await session.capture(
          frame(position: Offset(500, 500 + 10.0 * i)),
          pageName: name,
        );
      }

      expect(box.isEmpty, isTrue);
      final strategy = cloud.strategies.values.single;
      expect(strategy.name, 'Sunset replay');
      expect(strategy.mapData, Maps.mapNames[MapValue.sunset]);
      final pages = strategy.orderedPages;
      expect(pages.map((page) => page.name), ['0:10', '0:20', '0:30']);
      expect(pages.map((page) => page.isAttack), everyElement(isFalse));
      expect(session.strategy!.pageCount, 3);
      expect(session.strategy!.lastPageId, pages.last.id);
      expect(session.strategy!.source, StrategySource.cloud);

      // One player on every page: the server keeps one row per id, so each
      // page has its own, all of one root the transition pairs them by.
      final ids = [
        for (final page in pages) strategy.elements[page.id]!.single,
      ];
      expect(ids.toSet(), hasLength(3));
      expect(ids, everyElement(isNot('replay-player-a')));
      expect(ids.map(pageCopyRoot).toSet(), {ids.first});
    });

    test('a second strategy from the same replay lands too', () async {
      await capture().capture(frame(), pageName: 'one');
      await capture().capture(frame(), pageName: 'one');
      expect(cloud.strategies, hasLength(2));
      for (final strategy in cloud.strategies.values) {
        expect(strategy.elements.values.single, hasLength(1));
      }
    });

    test('offline, a capture is refused and nothing is written', () async {
      online = false;
      await expectLater(
        capture().capture(frame(), pageName: 'one'),
        throwsA(isA<CaptureRefused>()),
      );
      expect(cloud.strategies, isEmpty);
      expect(box.isEmpty, isTrue);
    });

    test('a strategy deleted on the server is never written to again',
        () async {
      final session = capture();
      final first = await session.capture(frame(), pageName: 'one');
      cloud.strategies.remove(first.id);

      final second = await session.capture(frame(), pageName: 'two');
      expect(second.id, isNot(first.id));
      expect(cloud.strategies[second.id]!.orderedPages.single.name, 'two');
    });

    test('a page the server took without its items is taken back', () async {
      final session = capture();
      final first = await session.capture(frame(), pageName: 'one');
      cloud.refuseItems = true;

      await expectLater(
        session.capture(frame(), pageName: 'two'),
        throwsStateError,
      );
      expect(
        cloud.strategies[first.id]!.orderedPages.map((page) => page.name),
        ['one'],
      );
      expect(session.strategy!.pageCount, 1);
    });
  });

  group('destination', () {
    late _FakeCloud cloud;

    ProviderContainer container({required bool signedIn}) {
      final container = ProviderContainer(overrides: [
        isCloudWorkspaceAvailableProvider.overrideWithValue(signedIn),
        cloudMediaAccountIdProvider
            .overrideWithValue(signedIn ? 'account-1' : null),
        convexStrategyRepositoryProvider.overrideWithValue(cloud),
        convexConnectionSnapshotProvider.overrideWithValue(true),
        strategyProvider.overrideWith(_ClosedStrategy.new),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    setUp(() async {
      cloud = _FakeCloud();
      // New strategies take the user's default theme and page settings.
      await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    });

    test('signed in, a capture goes to the cloud library', () async {
      final store = container(signedIn: true).read(replayCaptureStoreProvider);
      await ReplayCapture(newStore: store, map: MapValue.sunset, name: 'r')
          .capture(frame(), pageName: 'one');
      expect(cloud.strategies, hasLength(1));
      expect(box.isEmpty, isTrue);
    });

    test('signed out, it stays on this device', () {
      final store = container(signedIn: false).read(replayCaptureStoreProvider);
      expect(store(), isA<LocalReplayCaptureStore>());
    });
  });
}

class _ClosedStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: null,
        strategyName: null,
        source: StrategySource.local,
        isOpen: false,
      );
}

class _CloudPage {
  _CloudPage(this.id, this.name, this.sortIndex, this.isAttack);

  final String id;
  final String name;
  int sortIndex;
  final bool isAttack;
}

class _CloudStrategy {
  _CloudStrategy(this.name, this.mapData);

  final String name;
  final String mapData;
  int revision = 1;
  final List<_CloudPage> pages = [];

  /// Element ids by page id.
  final Map<String, List<String>> elements = {};

  List<_CloudPage> get orderedPages =>
      [...pages]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
}

/// The server as far as captures use it: one row per element id across
/// every strategy, and page adds checked against the strategy's revision.
class _FakeCloud extends Fake implements ConvexStrategyRepository {
  final Map<String, _CloudStrategy> strategies = {};
  final Set<String> elementIds = {};
  bool refuseItems = false;

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
    strategies[publicId] = _CloudStrategy(name, mapData)
      ..pages.add(
        _CloudPage(
            initialPagePublicId, initialPageName, 0, initialPageIsAttack),
      );
  }

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    final strategy = strategies[strategyPublicId];
    if (strategy == null) {
      throw const ConvexFunctionException(
        code: ConvexErrorCode.notFound,
        rawCode: 'NOT_FOUND',
        message: 'Strategy not found.',
      );
    }
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
  Future<void> deleteStrategy({
    required String strategyPublicId,
    required int expectedRevision,
  }) async {
    strategies.remove(strategyPublicId);
  }

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    final strategy = strategies[strategyPublicId]!;
    OpAck reject(StrategyOp op, OpRejectionReason reason) =>
        RejectedOpAck(opId: op.opId, rejectionReason: reason);
    OpAck apply(StrategyOp op) {
      strategy.revision++;
      return AppliedOpAck(opId: op.opId, revision: strategy.revision);
    }

    return [
      for (final op in ops)
        switch (op) {
          PageAddOp() when op.expectedStrategyRevision != strategy.revision =>
            reject(op, OpRejectionReason.revisionMismatch),
          PageAddOp() => () {
              strategy.pages.add(_CloudPage(
                op.pagePublicId,
                op.payload['name'] as String,
                op.sortIndex,
                op.payload['isAttack'] as bool,
              ));
              return apply(op);
            }(),
          PageDeleteOp() => () {
              strategy.pages.removeWhere((p) => p.id == op.pagePublicId);
              strategy.elements.remove(op.pagePublicId);
              return apply(op);
            }(),
          ElementAddOp()
              when refuseItems || elementIds.contains(op.elementPublicId) =>
            reject(op, OpRejectionReason.alreadyExists),
          ElementAddOp() => () {
              elementIds.add(op.elementPublicId);
              (strategy.elements[op.pagePublicId] ??= [])
                  .add(op.elementPublicId);
              return apply(op);
            }(),
          _ => throw UnimplementedError('${op.type}'),
        },
    ];
  }
}
