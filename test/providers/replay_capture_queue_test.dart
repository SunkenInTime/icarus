import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
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
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/replay_capture_queue_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/replay/replay_capture.dart';
import 'package:icarus/replay/replay_frame.dart';

final _online = StateProvider<bool>((ref) => true);
final _account = StateProvider<String?>((ref) => 'account-1');

ReplayFrame _frame(double x, {int players = 1}) => ReplayFrame(
      timeMs: 1000,
      round: null,
      isAttack: false,
      agents: [
        for (var i = 0; i < players; i++)
          PlacedViewConeAgent(
            id: i == 0 ? 'replay-player-a' : 'replay-player-$i',
            type: AgentType.jett,
            position: Offset(x, 500.0 + 20 * i),
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
  late _FlakyBox box;
  late List<String> messages;

  ProviderContainer open() {
    box = _FlakyBox(Hive.box<String>(HiveBoxNames.replayCapturesBox));
    return container = ProviderContainer(overrides: [
      replayCapturesBoxProvider.overrideWithValue(box),
      replayCaptureMessageProvider.overrideWithValue(messages.add),
      convexStrategyRepositoryProvider.overrideWithValue(cloud),
      authProvider.overrideWith(_CloudReadyAuth.new),
      cloudMediaAccountIdProvider.overrideWith((ref) => ref.watch(_account)),
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
    messages = [];
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

  ReplayCapture session({String? folderId}) => ReplayCapture(
        newStore: () => CloudReplayCaptureStore(
          queue: queue(),
          queueState: queued,
          accountId: 'account-1',
          folderId: folderId,
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

  test('a lost answer to a page add is resent without a second page', () async {
    final replay = session();
    await replay.capture(_frame(500), pageName: 'one');
    await queue().sendNow();
    cloud.losePageAdds = true;
    await replay.capture(_frame(510), pageName: 'two');
    await queue().sendNow();
    cloud.losePageAdds = false;
    await queue().sendNow();
    expect(cloud.lost, greaterThan(0), reason: 'the page add was answered');

    expect(queued().captures, isEmpty);
    expect(cloud.strategies.values.single.orderedPages.map((p) => p.name),
        ['one', 'two']);
    expect(cloud.elements, hasLength(2));
  });

  test('a lost answer to a batch of items is resent without duplicates',
      () async {
    final replay = session();
    cloud.loseItemBatches = true;
    await replay.capture(_frame(500, players: 3), pageName: 'one');
    await queue().sendNow();
    await queue().sendNow();
    final waiting = queued().captures.single;
    expect(waiting.pageLanded, isTrue);
    expect(waiting.uncertain, isTrue);
    expect(cloud.elements, hasLength(3), reason: 'written, answer lost');

    cloud.loseItemBatches = false;
    await queue().sendNow();

    expect(queued().captures, isEmpty);
    expect(cloud.elements, hasLength(3));
  });

  test('items accepted beside a refused one stay; Retry sends only the rest',
      () async {
    final replay = session();
    cloud.refuseItems = 1;
    await replay.capture(_frame(500, players: 3), pageName: 'one');
    await queue().sendNow();

    final refused = queued().captures.single;
    expect(refused.failure, CaptureFailureKind.refused);
    expect(refused.landedItemOpIds, hasLength(2));
    expect(cloud.elements, hasLength(2));
    final unlanded = refused.unlandedItems.single;
    cloud.itemBatches.clear();

    await queue().retry([refused.id]);
    await queue().sendNow();

    // Only the refused item went again, not the two that landed.
    expect(cloud.itemBatches, [
      [(unlanded as ElementAddOp).elementPublicId],
    ]);
    expect(queued().captures, isEmpty);
    expect(cloud.elements, hasLength(3));
    expect(cloud.elements.keys, contains(unlanded.elementPublicId));
  });

  test('a retry checks the strategy again before sending the rest', () async {
    final replay = session();
    cloud.refuseItems = 1;
    final first =
        await replay.capture(_frame(500, players: 2), pageName: 'one');
    await queue().sendNow();
    final refused = queued().captures.single;
    expect(refused.pageLanded, isTrue);

    cloud.strategies[first.id]!.mapData = Maps.mapNames[MapValue.ascent]!;
    await queue().retry([refused.id]);
    await queue().sendNow();

    expect(queued().captures.single.failure, CaptureFailureKind.mapChanged);
    expect(cloud.elements, hasLength(1), reason: 'nothing more was sent');

    cloud.strategies.remove(first.id);
    await queue().discard([queued().captures.single.id]);
    final next = await replay.capture(_frame(510), pageName: 'two');
    expect(next.id, isNot(first.id));
  });

  test('a map change between the page and its items stops the items', () async {
    final replay = session();
    final first = await replay.capture(_frame(500), pageName: 'one');
    await queue().sendNow();
    cloud.afterPageAdd =
        (strategy) => strategy.mapData = Maps.mapNames[MapValue.ascent]!;

    await replay.capture(_frame(510, players: 2), pageName: 'two');
    await queue().sendNow();

    expect(queued().captures.single.failure, CaptureFailureKind.mapChanged);
    expect(cloud.elementsOn(queued().captures.single.pageId), isEmpty);
    expect(queued().lostStrategyIds, {first.id});
  });

  test('a strategy deleted while its items were refused is known lost',
      () async {
    final replay = session();
    cloud.refuseItems = 1;
    final first =
        await replay.capture(_frame(500, players: 2), pageName: 'one');
    await queue().sendNow();
    cloud.strategies.remove(first.id);

    await queue().retry([queued().captures.single.id]);
    await queue().sendNow();

    expect(queued().captures.single.failure, CaptureFailureKind.deleted);
    expect(queued().lostStrategyIds, {first.id});
  });

  test('when storage fails, the capture waits for Retry and others go on',
      () async {
    setOnline(false);
    final stopped = session();
    await stopped.capture(_frame(500), pageName: 'stopped');
    box.failWrites = true;
    setOnline(true);
    await queue().sendNow();

    final waiting = queued().captures.single;
    expect(queued().needsUser(waiting), isTrue);
    expect(queued().stuck[waiting.id], contains('this device'));
    expect(queued().isReliable, isFalse);

    // Another strategy's capture still goes.
    box.failWrites = false;
    await session().capture(_frame(510), pageName: 'other');
    await queue().sendNow();
    expect(queued().captures.single.id, waiting.id);

    await queue().retry([waiting.id]);
    await queue().sendNow();
    expect(queued().captures, isEmpty);
    expect(queued().isReliable, isTrue);
    expect(cloud.strategies, hasLength(2));
  });

  test("a folder this account can't use leaves the strategy at the top",
      () async {
    cloud.foreignFolders.add('shared-folder');
    final captured = await session(folderId: 'shared-folder')
        .capture(_frame(500), pageName: 'one');
    await queue().sendNow();

    expect(queued().captures, isEmpty);
    expect(cloud.folderOf[captured.id], isNull);
    expect(messages.single, contains('top level of My Library'));
  });

  test('a server that needs a newer Icarus holds captures and says so',
      () async {
    cloud.upgradeRequired = true;
    await session().capture(_frame(500), pageName: 'one');
    await queue().sendNow();

    final held = queued().captures.single;
    expect(held.isFailed, isFalse);
    expect(queued().needsUser(held), isFalse);
    expect(container.read(clientUpgradeRequiredProvider), isTrue);

    // Nothing more is sent until the server takes this build again.
    final calls = cloud.calls;
    await session().capture(_frame(510), pageName: 'two');
    await queue().sendNow();
    expect(cloud.calls, calls);
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

  test(
      "another account signed in mid-send gets none of the first one's captures",
      () async {
    void signIn(String accountId) {
      cloud.signedInAs = accountId;
      container.read(_account.notifier).state = accountId;
    }

    setOnline(false);
    final first = session();
    await first.capture(_frame(500), pageName: '0:10');
    await first.capture(_frame(510), pageName: '0:20');
    await session().capture(_frame(520), pageName: '1:10');
    // Signed out and in as someone else while a page add is out.
    cloud.afterPageAdd = (_) {
      cloud.afterPageAdd = null;
      signIn('account-2');
    };
    setOnline(true);
    await queue().sendNow();

    expect(cloud.ownerOf.values, everyElement('account-1'));
    expect(queued().captures.where((c) => c.isFailed), isEmpty);
    expect(queued().captures, hasLength(2));

    signIn('account-1');
    await queue().sendNow();
    expect(queued().captures, isEmpty);
    expect(cloud.ownerOf, hasLength(2));
    expect(cloud.ownerOf.values, everyElement('account-1'));
  });

  test(
      'a refusal that went out under another account fails nothing, even with the first account back',
      () async {
    void signIn(String accountId) {
      cloud.signedInAs = accountId;
      container.read(_account.notifier).state = accountId;
    }

    setOnline(false);
    final replay = session();
    await replay.capture(_frame(500), pageName: '0:10');
    await replay.capture(_frame(510), pageName: '0:20');
    // Someone else signs in while the page add is out, and the first
    // account is back before the next read's refusal arrives.
    cloud.afterPageAdd = (_) {
      cloud.afterPageAdd = null;
      signIn('account-2');
      cloud.afterShellRead = () {
        cloud.afterShellRead = null;
        signIn('account-1');
      };
    };
    setOnline(true);
    await queue().sendNow();
    expect(queued().captures.where((c) => c.isFailed), isEmpty);

    await queue().sendNow();
    expect(queued().captures, isEmpty);
    expect(cloud.strategies.values.single.orderedPages, hasLength(2));
  });

  test('a strategy made just before another account signed in may have landed',
      () async {
    setOnline(false);
    await session().capture(_frame(500), pageName: '0:10');
    // Made, then the answer is lost while someone else signs in.
    cloud.afterCreate = () {
      cloud.afterCreate = null;
      cloud.signedInAs = 'account-2';
      container.read(_account.notifier).state = 'account-2';
      cloud.loseAnswers = true;
    };
    setOnline(true);
    await queue().sendNow();
    cloud.loseAnswers = false;

    final capture = queued().captures.single;
    expect(capture.isFailed, isFalse);
    expect(capture.mayHaveLanded, isTrue);
    expect(await queue().discard([capture.id]), isTrue);
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

/// The capture box, whose writes can be made to fail.
class _FlakyBox extends Fake implements Box<String> {
  _FlakyBox(this.inner);

  final Box<String> inner;
  bool failWrites = false;

  @override
  Iterable<String> get values => inner.values;

  @override
  bool containsKey(dynamic key) => inner.containsKey(key);

  @override
  String? get(dynamic key, {String? defaultValue}) =>
      inner.get(key, defaultValue: defaultValue);

  @override
  Future<void> put(dynamic key, String value) {
    if (failWrites) throw const FileSystemException('disk full');
    return inner.put(key, value);
  }

  @override
  Future<void> delete(dynamic key) {
    if (failWrites) throw const FileSystemException('disk full');
    return inner.delete(key);
  }
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

  /// Writes, then loses the answer, as a timeout does: every answer, or
  /// only those to a page add or to a batch of items.
  bool loseAnswers = false;
  bool losePageAdds = false;
  bool loseItemBatches = false;

  /// Refuses every call as from a build the server no longer accepts.
  bool upgradeRequired = false;

  /// Folders this account may not put strategies in.
  final Set<String> foreignFolders = {};

  /// Folders new strategies were made in, by strategy id.
  final Map<String, String?> folderOf = {};

  /// The account the server sees signed in. A strategy belongs to the one
  /// that made it; any other is refused it, as the server refuses one with
  /// no role on it.
  String signedInAs = 'account-1';
  final Map<String, String> ownerOf = {};

  /// Runs right after a strategy is made, before it is answered.
  void Function()? afterCreate;

  /// Runs right after a strategy is read, before it is answered.
  void Function()? afterShellRead;

  static const _forbidden = ConvexFunctionException(
    code: ConvexErrorCode.forbidden,
    rawCode: 'FORBIDDEN',
    message: 'Forbidden',
  );

  /// Runs right after a page add is written, before it is answered.
  void Function(_Strategy strategy)? afterPageAdd;

  /// The element ids of each batch of items sent, in order.
  final List<List<String>> itemBatches = [];

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

  /// Answers lost so far.
  var lost = 0;

  void _answer({bool lost = false}) {
    calls++;
    if (loseAnswers || lost) {
      this.lost++;
      throw TimeoutException('lost');
    }
  }

  void _checkBuild() {
    if (upgradeRequired) {
      calls++;
      throw const ConvexFunctionException(
        code: ConvexErrorCode.clientUpgradeRequired,
        rawCode: clientUpgradeRequiredCode,
        message: 'Client upgrade required',
      );
    }
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
    _checkBuild();
    if (foreignFolders.contains(folderPublicId)) {
      throw const ConvexFunctionException(
        code: ConvexErrorCode.forbidden,
        rawCode: 'FORBIDDEN',
        message: 'Forbidden',
      );
    }
    if ((ownerOf[publicId] ?? signedInAs) != signedInAs) {
      calls++;
      throw const ConvexFunctionException(
        code: ConvexErrorCode.conflict,
        rawCode: 'CONFLICT',
        message: 'Strategy publicId already exists',
      );
    }
    folderOf.putIfAbsent(publicId, () => folderPublicId);
    ownerOf.putIfAbsent(publicId, () => signedInAs);
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
    afterCreate?.call();
    _answer();
  }

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    calls++;
    final strategy = strategies[strategyPublicId];
    final owner = ownerOf[strategyPublicId];
    final refused = owner != null && owner != signedInAs;
    afterShellRead?.call();
    if (strategy == null) throw _notFound;
    if (refused) throw _forbidden;
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
    _checkBuild();
    if (accountSubject != null && accountSubject != signedInAs) {
      calls++;
      throw _forbidden;
    }
    final strategy = strategies[strategyPublicId];
    if (strategy == null) throw _notFound;
    final acks = <OpAck>[];
    if (ops.every((op) => op is ElementAddOp)) {
      itemBatches
          .add([for (final op in ops.cast<ElementAddOp>()) op.elementPublicId]);
    }
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
    _answer(
      lost: ops.any((op) => op is PageAddOp) ? losePageAdds : loseItemBatches,
    );
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
        final ack = applied();
        afterPageAdd?.call(strategy);
        return ack;
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
