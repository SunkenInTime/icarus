import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart'
    show at, pageList, pageSnapshot, serverRows, servedAccount, strategyId;

final start = DateTime.utc(2026, 11, 23, 12);
const otherStrategy = 'hand-2';
final otherAccount = Account('account-b');
const timing = SenderTiming();

final class ServerCall {
  ServerCall(this.strategyId, this.clientId, this.account, this.ops);

  final String strategyId;
  final String clientId;
  final Account account;
  final List<StrategyOp> ops;

  List<String> get opIds => [for (final op in ops) op.opId];
}

typedef Answering = Future<StoreBatchOutcome> Function(ServerCall call);

final class FakeServer {
  final calls = <ServerCall>[];
  final receipts = <(String, String, String), int>{};
  final appliedTimes = <(String, String), int>{};
  final owners = <String, Account>{};
  final wrongAccount = <ServerCall>[];
  final revisions = <String, int>{};
  final _answers = <String, List<Answering>>{};
  void Function(ServerCall call)? onCall;

  int get applied => appliedTimes.length;

  int appliedOf(String strategyId) =>
      appliedTimes.keys.where((key) => key.$1 == strategyId).length;

  bool get anyAppliedTwice => appliedTimes.values.any((times) => times > 1);

  void answerNormally() => _answers.clear();

  void answerNext(String strategyId, Answering answering) =>
      (_answers[strategyId] ??= []).add(answering);

  void answerWith(String strategyId, StoreBatchOutcome outcome) => answerNext(
        strategyId,
        (_) => Future<StoreBatchOutcome>.value(outcome),
      );

  StoreBatchOutcome applyAll(ServerCall call) {
    final answers = <OpAnswer>[];
    for (final op in call.ops) {
      final key = (call.strategyId, call.clientId, op.opId);
      if (receipts[key] case final revision?) {
        answers.add(
          NoopAnswer(
            op.opId,
            revision: revision,
            replay: NoopReplay.appliedWhenFirstReceived,
          ),
        );
        continue;
      }
      final revision =
          revisions[call.strategyId] = (revisions[call.strategyId] ?? 2) + 1;
      receipts[key] = revision;
      appliedTimes.update(
        (call.strategyId, op.opId),
        (times) => times + 1,
        ifAbsent: () => 1,
      );
      answers.add(AppliedAnswer(op.opId, revision: revision));
    }
    return StoreBatchAnswered(answers, complete: true);
  }

  Future<StoreBatchOutcome> send({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    required Account account,
  }) {
    final call = ServerCall(strategyPublicId, clientId, account, ops);
    calls.add(call);
    onCall?.call(call);
    if (owners[strategyPublicId] case final owner? when owner != account) {
      wrongAccount.add(call);
    }
    final queued = _answers[strategyPublicId];
    if (queued != null && queued.isNotEmpty) {
      return queued.removeAt(0)(call);
    }
    return Future.value(applyAll(call));
  }
}

final class RefusingLease implements StorageLease {
  RefusingLease(this.inner);

  final StorageLease inner;
  var refuseNext = 0;
  final refusedAreas = <String>{};
  var commits = 0;

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  LeaseStatus get status => inner.status;

  @override
  Future<KeyRead> read(String area, String key) => inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      inner.keys(area, prefix);

  @override
  Future<Stored<List<String>>> areas(String prefix) => inner.areas(prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      inner.entries(area, prefix);

  @override
  Future<Committing> commit(List<Change> changes) async {
    commits++;
    final refusedHere = changes.any(
      (change) => refusedAreas.any(
        (id) => change.area.contains(digestOf(id)),
      ),
    );
    if (refuseNext > 0 || refusedHere) {
      if (!refusedHere) refuseNext--;
      return const CommitRefused(DeviceFailure('the disk refused it'));
    }
    return inner.commit(changes);
  }

  @override
  Future<Releasing> release() => inner.release();
}

final class RefusingEngine implements StorageEngine {
  RefusingEngine(this.inner);

  final StorageEngine inner;
  RefusingLease? leased;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
        Leased(lease: final granted) => Leased(leased = RefusingLease(granted)),
        final other => other,
      };
}

Future<void> none() async {}

final class World {
  World._(this.async, this.engine, this.store, this.server, this.sender);

  final FakeAsync async;
  final RefusingEngine engine;
  final LibraryStore store;
  final FakeServer server;
  final CloudSender sender;
  CloudShadow? shadow;
  StreamSubscription<StoreChange>? _changes;
  Account? _account = servedAccount;
  int? _connection = 1;
  int _authChanges = 1;
  var _moved = 0;

  RefusingLease get lease => engine.leased!;

  Account? get account => _account;

  int? get connection => _connection;

  int get authChanges => _authChanges;

  set account(Account? next) {
    _account = next;
    _push();
  }

  set connection(int? next) {
    _connection = next;
    _push();
  }

  set authChanges(int next) {
    _authChanges = next;
    _push();
  }

  void signIn(Account? next) {
    _account = next;
    _authChanges++;
    _push();
  }

  void _push() => sender.inputs = (
        account: _account,
        connection: _connection,
        authChanges: _authChanges,
      );

  static World open(
    FakeAsync async, {
    MemoryStorage? storage,
    FakeServer? server,
    bool shadow = true,
    String clientId = 'client-1',
  }) {
    final engine = RefusingEngine(MemoryEngine(storage ?? MemoryStorage()));
    LibraryStore? store;
    LibraryStore.open(
      engine,
      canRead: appCanRead,
      build: 'test-build',
      clock: () => start.add(async.elapsed),
    ).then(
      (opened) => store = switch (opened) {
        StoreOpened(:final store) => store,
        StoreNotOpened(:final problem) => throw StateError('$problem'),
      },
    );
    async.flushMicrotasks();
    final fake = server ?? FakeServer();
    fake.owners[strategyId] = servedAccount;
    final sender = CloudSender(
      store: SenderStore(store!, clientId: clientId),
      send: fake.send,
      build: 'test-build',
      inputs: (account: servedAccount, connection: 1, authChanges: 1),
      timing: timing,
      clock: () => start.add(async.elapsed),
    );
    final world = World._(async, engine, store!, fake, sender);
    world._changes = store!.changes.listen((_) => sender.nudge());
    if (shadow) {
      world.shadow = CloudShadow(
        store!,
        build: 'test-build',
        canRead: appCanRead,
        breathe: none,
        sessions: sender,
      )..serve(servedAccount);
    }
    return world;
  }

  void addServedStrategy() {
    shadow!
      ..pageList(strategyId, pageList(serverRows()), _connection)
      ..page(strategyId, pageSnapshot(serverRows()), _connection);
    settle(Duration.zero);
    expect(shadow!.stopped, isNull);
  }

  void addOtherStrategy({Account? owner}) {
    final whose = owner ?? servedAccount;
    server.owners[otherStrategy] = whose;
    final list = RemotePageList(
      header: app.RemoteStrategyHeader(
        publicId: otherStrategy,
        name: 'Second',
        mapData: 'bind',
        revision: 1,
        createdAt: at,
        updatedAt: at,
        role: 'owner',
      ),
      pages: const [],
    );
    final header = switch (pageListRead(list)) {
      RowsRead(:final value) => value,
      RowsUnreadable(:final problem) => throw StateError('$problem'),
    };
    Saving<StrategySummary, LibraryRefusal>? added;
    store.addCloudStrategy(
        whose, header, const []).then((value) => added = value);
    async.flushMicrotasks();
    expect(added, isA<Saved<StrategySummary, LibraryRefusal>>());
  }

  void settle([Duration time = const Duration(seconds: 2)]) {
    async.elapse(time);
    async.flushMicrotasks();
  }

  void commitMove(int n) {
    _moved = n;
    final first = serverRows().elements.whereType<LiveElement>().first;
    Reading<PageContent>? read;
    store
        .readPage(strategyId, first.pagePublicId)
        .then((value) => read = value);
    async.flushMicrotasks();
    final element = (read! as Found<PageContent>)
        .value
        .elements
        .whereType<LiveElement>()
        .firstWhere((element) => element.publicId == first.publicId);
    _commit(strategyId, servedAccount, [
      ElementPatchOp(
        opId: 'move-$n',
        elementPublicId: element.publicId,
        expectedElementRevision: element.revision,
        payload: ElementPayload(
          kind: element.payload.kind,
          payloadVersion: element.payload.payloadVersion,
          data: {
            ...element.payload.data.toJson(),
            'position': {'dx': 100.0 + n, 'dy': 50.0 + n},
          },
        ),
      ),
    ]);
  }

  void commitRename(String strategy, String opId, {Account? owner}) {
    Reading<StrategyContent>? read;
    store.readStrategy(strategy).then((value) => read = value);
    async.flushMicrotasks();
    final row = (read! as Found<StrategyContent>).value.strategy;
    final revision = (row.toJson()! as Map)['revision']! as int;
    _commit(strategy, owner ?? servedAccount, [
      StrategyPatchOp(
        opId: opId,
        expectedStrategyRevision: revision,
        name: 'Renamed $opId',
      ),
    ]);
  }

  void _commit(String strategy, Account owner, List<StrategyOp> ops) {
    Saving<List<Committed>, CommitRefusal>? saved;
    store.commitAllAs(owner, strategy, ops).then((value) => saved = value);
    async.flushMicrotasks();
    expect(saved, isA<Saved<List<Committed>, CommitRefusal>>());
  }

  void showResult() {
    final snapshot = pageSnapshot(serverRows());
    final first = serverRows().elements.whereType<LiveElement>().first;
    final shown = app.RemotePageSnapshot(
      page: snapshot.page,
      content: snapshot.content,
      elements: [
        for (final element in snapshot.elements)
          if (element.publicId != first.publicId)
            element
          else
            app.RemoteElement(
              publicId: element.publicId,
              strategyPublicId: element.strategyPublicId,
              pagePublicId: element.pagePublicId,
              elementType: element.elementType,
              payload: {
                ...element.payload,
                'data': {
                  ...(element.payload['data']! as Map),
                  'position': {'dx': 100.0 + _moved, 'dy': 50.0 + _moved},
                },
              },
              sortIndex: element.sortIndex,
              revision: server.revisions[strategyId] ?? element.revision,
              deleted: element.deleted,
            ),
      ],
      lineups: snapshot.lineups,
      assetsById: snapshot.assetsById,
    );
    shadow!.page(strategyId, shown, _connection);
    settle();
  }

  CloudStrategy cloud([String strategy = strategyId]) {
    Reading<StrategyContent>? read;
    store.readStrategy(strategy).then((value) => read = value);
    async.flushMicrotasks();
    return ((read! as Found<StrategyContent>).value.sync) as CloudStrategy;
  }

  int queueLength([String strategy = strategyId]) =>
      cloud(strategy).queue.entries.length;

  List<EntryView> views([String strategy = strategyId]) =>
      cloud(strategy).views.values.toList();

  Face? face([String strategy = strategyId]) {
    final summary = (store.library as LibraryOpen)
        .list
        .strategies
        .firstWhere((summary) => summary.publicId == strategy);
    final (owner, tally) = switch (summary.sync) {
      KeptInCloud(:final owner, :final tally) => (owner, tally),
      _ => throw StateError('not a cloud strategy'),
    };
    return switch (syncStateOf(
      owner,
      tally,
      network: Network.online,
      signedIn: SignedInAs(servedAccount),
    )) {
      Outstanding(:final face) => face,
      AllSaved() => null,
    };
  }

  List<QueueEvent> written([String strategy = strategyId]) => [
        for (final report in sender.store.reports)
          if (report case EventsWritten(:final strategyId, :final events)
              when strategyId == strategy)
            ...events,
      ];

  String status([String strategy = strategyId]) =>
      '${sender.view.strategies[strategy]}';

  void close() {
    unawaited(_changes?.cancel());
  }
}

void inWorld(
  void Function(World world) body, {
  MemoryStorage? storage,
  FakeServer? server,
  bool shadow = true,
  bool addStrategy = true,
  String clientId = 'client-1',
  bool keepOpen = false,
}) {
  fakeAsync((async) {
    final world = World.open(
      async,
      storage: storage,
      server: server,
      shadow: shadow,
      clientId: clientId,
    );
    if (addStrategy) world.addServedStrategy();
    body(world);
    if (!keepOpen) {
      world.sender.dispose();
      world.close();
      world.store.close();
      async.flushMicrotasks();
    }
  });
}
