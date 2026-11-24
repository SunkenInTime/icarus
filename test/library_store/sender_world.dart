import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart'
    show at, pageList, secondPage, serverRows, servedAccount, strategyId;

final start = DateTime.utc(2026, 11, 23, 12);
const otherStrategy = 'hand-2';
final otherAccount = Account('account-b');
const timing = SenderTiming();

final class ServerCall {
  ServerCall(
    this.strategyId,
    this.clientId,
    this.account,
    this.ops, [
    this.serverTime = const ServerTimeNotAsked(),
  ]);

  final String strategyId;
  final String clientId;
  final Account account;
  final List<StrategyOp> ops;
  final ServerTimeAsk serverTime;

  int? get basis => switch (serverTime) {
        ServerTimeAsked(:final basis) => basis,
        ServerTimeNotAsked() => null,
      };

  List<String> get unchecked => [
        for (final op in ops)
          if (uncheckedOnTheWire(op)) op.opId,
      ];

  List<String> get opIds => [for (final op in ops) op.opId];
}

bool uncheckedOnTheWire(StrategyOp op) => switch (op.toJson()) {
      {
        'type': 'element.patch' || 'lineup.patch',
        'merge': final Map<String, Object?> merge,
      } =>
        !merge.containsKey('base'),
      {'type': 'element.delete' || 'lineup.delete', 'lastWriterWins': true} =>
        true,
      _ => false,
    };

final class ReadCall {
  ReadCall(this.strategyId, this.page, this.account);

  final String strategyId;
  final String? page;
  final Account account;
  DateTime? at;
  String? why;
  StoreReadRole? role;
  bool answered = false;

  @override
  String toString() => page == null ? 'list' : 'page $page';
}

typedef Answering = Future<StoreBatchOutcome> Function(ServerCall call);

typedef ReadAnswering = Future<StoreReadOutcome> Function(ReadCall call);

int? revisionOf(Row? row) => switch (row?.toJson()) {
      {'revision': final int revision} => revision,
      _ => null,
    };

int? visibleRevision(StrategyRowSet rows, StrategyOp op) =>
    switch (targetOf(op)) {
      StrategyTarget() => revisionOf(rows.strategy),
      PageTarget(:final pagePublicId) => revisionOf(rows.page(pagePublicId)),
      SettingsTarget(:final pagePublicId) =>
        revisionOf(rows.settingsOf(pagePublicId)),
      ElementTarget(:final elementPublicId) =>
        revisionOf(rows.element(elementPublicId)),
      LineupTarget(:final lineupPublicId) =>
        revisionOf(rows.lineupGroup(lineupPublicId)),
    };

final class FakeServer {
  final calls = <ServerCall>[];
  final receipts = <(String, String, String), OpAnswer>{};
  final appliedTimes = <(String, String), int>{};
  final owners = <String, Account>{};
  final roles = <String, StoreReadRole>{};
  final wrongAccount = <ServerCall>[];
  final wrongAccountReads = <ReadCall>[];
  final rows = <String, StrategyRowSet>{};
  final readCalls = <ReadCall>[];
  final _answers = <String, List<Answering>>{};
  final _readAnswers = <String, List<ReadAnswering>>{};
  void Function(ServerCall call)? onCall;
  void Function(ReadCall call)? onRead;
  DateTime Function()? clock;
  String? Function()? whyNow;
  StoreReadOutcome? Function(ReadCall call)? overrideRead;

  int get applied => appliedTimes.length;

  int appliedOf(String strategyId) =>
      appliedTimes.keys.where((key) => key.$1 == strategyId).length;

  bool get anyAppliedTwice => appliedTimes.values.any((times) => times > 1);

  void answerNormally() {
    _answers.clear();
    _readAnswers.clear();
  }

  bool get answersNormally =>
      _answers.values.every((queued) => queued.isEmpty) &&
      _readAnswers.values.every((queued) => queued.isEmpty);

  void answerNext(String strategyId, Answering answering) =>
      (_answers[strategyId] ??= []).add(answering);

  void answerWith(String strategyId, StoreBatchOutcome outcome) => answerNext(
        strategyId,
        (_) => Future<StoreBatchOutcome>.value(outcome),
      );

  void answerReadNext(String strategyId, ReadAnswering answering) =>
      (_readAnswers[strategyId] ??= []).add(answering);

  void answerReadWith(String strategyId, StoreReadOutcome outcome) =>
      answerReadNext(strategyId, (_) => Future.value(outcome));

  OpAnswer _applyOne(String strategy, String client, StrategyOp op) {
    final key = (strategy, client, op.opId);
    switch (receipts[key]) {
      case AppliedAnswer(:final revision):
        return NoopAnswer(
          op.opId,
          revision: revision,
          replay: NoopReplay.appliedWhenFirstReceived,
        );
      case final answer?:
        return answer;
      case null:
        break;
    }
    final now = rows[strategy]!;
    final OpAnswer answer;
    switch (applyOp(now, op)) {
      case final OpApplied done:
        final next = rows[strategy] = now.withRows(done.rows);
        appliedTimes.update(
          (strategy, op.opId),
          (times) => times + 1,
          ifAbsent: () => 1,
        );
        answer = AppliedAnswer(op.opId, revision: visibleRevision(next, op)!);
      case OpUnchanged():
        final revision = visibleRevision(now, op);
        answer = revision == null
            ? NoopWithoutRevision(op.opId)
            : NoopAnswer(
                op.opId,
                revision: revision,
                replay: NoopReplay.notApplied,
              );
      case OpRefused(refusal: Rejected(:final reason)):
        answer = RejectedAnswer(op.opId, reason, const NoServerCopy());
      case OpRefused(refusal: Failed(:final code)):
        answer = FailedAnswer(op.opId, KnownFailure(code), code.wireName);
      case OpRefused(:final refusal):
        throw StateError('the fake server cannot refuse with $refusal');
    }
    receipts[key] = answer;
    return answer;
  }

  int get serverNow =>
      (clock?.call() ?? DateTime.now()).millisecondsSinceEpoch + skew;

  var skew = 0;

  StoreBatchOutcome applyAll(ServerCall call) {
    final now = serverNow;
    final asked = call.serverTime is ServerTimeAsked;
    switch (call.basis) {
      case null when asked && call.unchecked.isNotEmpty:
        return const StoreBatchOutsideWindow(
          'An unchecked change needs a live basis',
        );
      case final basis? when basis > now || now - basis > 30000:
        return const StoreBatchOutsideWindow(
          'The batch arrived too long after its live basis',
        );
      case _:
        break;
    }
    return StoreBatchAnswered(
      [
        for (final op in call.ops)
          _applyOne(call.strategyId, call.clientId, op),
      ],
      complete: true,
      serverTime: asked ? now : null,
    );
  }

  OpAnswer teammate(String strategyId, StrategyOp op) =>
      _applyOne(strategyId, 'teammate', op);

  Future<StoreBatchOutcome> send({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    required Account account,
    required ServerTimeAsk serverTime,
  }) {
    final call = ServerCall(
      strategyPublicId,
      clientId,
      account,
      ops,
      serverTime,
    );
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

  HeaderRead headerOf(String strategyId) {
    final held = rows[strategyId]!;
    final pages = [...held.pages]..sort(
        (a, b) => ((a.toJson()! as Map)['sortIndex'] as int)
            .compareTo((b.toJson()! as Map)['sortIndex'] as int),
      );
    return HeaderRead(
      strategy: held.strategy as StrategyRow,
      pages: pages,
      settings: [...held.settings],
    );
  }

  StoreReadOutcome _answerRead(ReadCall call) {
    final held = rows[call.strategyId];
    if (held == null) {
      return StoreReadAnswered(
        call.page == null ? const StrategyGone() : PageGone(call.page!),
      );
    }
    final page = call.page;
    if (page == null) {
      return StoreReadAnswered(
        headerOf(call.strategyId),
        role: roles[call.strategyId] ?? StoreReadRole.owner,
      );
    }
    final pageRow = held.page(page);
    if (pageRow == null) return StoreReadAnswered(PageGone(page));
    return StoreReadAnswered(
      PageRead(
        page: pageRow,
        elements: [...held.elementsOn(page)],
        lineupGroups: [...held.lineupGroupsOn(page)],
      ),
    );
  }

  Future<StoreReadOutcome> _read(ReadCall call) {
    call
      ..at = clock?.call()
      ..why = whyNow?.call()
      ..role = roles[call.strategyId] ?? StoreReadRole.owner;
    readCalls.add(call);
    onRead?.call(call);
    if (owners[call.strategyId] case final owner? when owner != call.account) {
      wrongAccountReads.add(call);
    }
    final queued = _readAnswers[call.strategyId];
    if (queued != null && queued.isNotEmpty) {
      return queued.removeAt(0)(call);
    }
    if (overrideRead?.call(call) case final outcome?) {
      return Future.value(outcome);
    }
    return Future.value(_answerRead(call));
  }

  StoreReadOutcome answerNow(ReadCall call) => _answerRead(call);

  StoreReads get reads => StoreReads(
        pageList: ({required strategyPublicId, required account}) =>
            _read(ReadCall(strategyPublicId, null, account)),
        page: ({
          required strategyPublicId,
          required pagePublicId,
          required account,
        }) =>
            _read(ReadCall(strategyPublicId, pagePublicId, account)),
      );

  List<String> readsOf(String strategyId) => [
        for (final call in readCalls)
          if (call.strategyId == strategyId) '$call',
      ];
}

final class RefusingLease implements StorageLease {
  RefusingLease(this.inner);

  final StorageLease inner;
  var refuseNext = 0;
  final refusedAreas = <String>{};
  final refusedFor = <String, int>{};
  var commits = 0;
  var readDelay = Duration.zero;
  var failReads = 0;

  Future<T> _reading<T>(Future<T> Function() read, T failed) async {
    if (failReads > 0) {
      failReads--;
      return failed;
    }
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    return read();
  }

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  LeaseStatus get status => inner.status;

  @override
  Future<KeyRead> read(String area, String key) => _reading(
        () => inner.read(area, key),
        const KeyNotRead(DeviceFailure('the disk did not read it')),
      );

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      inner.keys(area, prefix);

  @override
  Future<Stored<List<String>>> areas(String prefix) => inner.areas(prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _reading(
        () => inner.entries(area, prefix),
        const StorageFailed(DeviceFailure('the disk did not read it')),
      );

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
      for (final id in refusedAreas) {
        if (changes.any((change) => change.area.contains(digestOf(id)))) {
          refusedFor.update(id, (count) => count + 1, ifAbsent: () => 1);
        }
      }
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

final class _Flag {
  var value = false;
}

final class _Slept {
  var value = Duration.zero;
}

final class SlowSenderStore extends SenderStore {
  SlowSenderStore(super.store) : super(keepsAllReports: true);

  var afterRead = Duration.zero;
  var dropSessionReadBack = 0;
  var throwsOnBase = false;
  void Function()? duringSessionWrite;
  var readsThrow = false;
  var claimWaits = Duration.zero;

  @override
  Future<ClaimResult> claim(
    Account owner,
    String strategyId,
    Picked picked,
    DateTime at, {
    required Duration Function() elapsed,
    required int session,
  }) async {
    final wait = claimWaits;
    claimWaits = Duration.zero;
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    return super.claim(
      owner,
      strategyId,
      picked,
      at,
      elapsed: elapsed,
      session: session,
    );
  }

  @override
  Future<Reading<StrategyContent>> readStrategy(String strategyId) {
    if (readsThrow) throw StateError('the store broke on a read');
    return super.readStrategy(strategyId);
  }

  @override
  Future<Written> write(
    Account owner,
    String strategyId,
    List<QueueEvent> events, {
    ClaimedBatch? batch,
    bool readSession = false,
  }) async {
    if (throwsOnBase && events.any((event) => event is BaseArrived)) {
      throwsOnBase = false;
      throw StateError('the store broke');
    }
    if (readSession) {
      final during = duringSessionWrite;
      duringSessionWrite = null;
      during?.call();
    }
    final written = await super.write(
      owner,
      strategyId,
      events,
      batch: batch,
      readSession: readSession,
    );
    if (readSession && dropSessionReadBack > 0 && written is WrittenWith) {
      dropSessionReadBack--;
      return WrittenWith(
        written.effects,
        session: null,
        notApplied: written.notApplied,
      );
    }
    return written;
  }

  @override
  Future<QueueRead> read(String strategyId) async {
    final read = await super.read(strategyId);
    if (afterRead > Duration.zero) await Future<void>.delayed(afterRead);
    return read;
  }
}

final class World {
  World._(this.async, this.engine, this.store, this.server, this.sender);

  final FakeAsync async;
  final RefusingEngine engine;
  final LibraryStore store;
  final FakeServer server;
  final CloudSender sender;
  late _Flag dropsConnectionLost;
  late _Slept _slept;

  void sleep(Duration time) {
    _slept.value += time;
    async.elapse(time);
  }

  late Account? _account;
  late int? _connection;
  late int _authChanges;
  late int _signOuts;

  RefusingLease get lease => engine.leased!;

  SlowSenderStore get slowStore => sender.store as SlowSenderStore;

  Account? get account => _account;

  int? get connection => _connection;

  int get authChanges => _authChanges;

  set account(Account? next) {
    if (_account != null && next == null) _signOuts++;
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
    if (_account != null && next == null) _signOuts++;
    _account = next;
    _authChanges++;
    _push();
  }

  Snapshot get stamp => (
        account: _account,
        connection: _connection,
        signIns: _authChanges,
        signOuts: _signOuts,
      );

  var readEras = 0;

  void _push() {
    if (readsUnder(stamp) != readsUnder(sender.inputs)) readEras++;
    sender.inputs = stamp;
  }

  static World open(
    FakeAsync async, {
    MemoryStorage? storage,
    FakeServer? server,
    String clientId = 'client-1',
    Snapshot? startingWith,
  }) {
    final inputs = startingWith ??
        (account: servedAccount, connection: 1, signIns: 1, signOuts: 0);
    final dropsConnectionLost = _Flag();
    final slept = _Slept();
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
    fake
      ..owners[strategyId] ??= servedAccount
      ..clock = () => start.add(async.elapsed);
    fake.rows[strategyId] ??= serverRows();
    final sender = CloudSender(
      store: SlowSenderStore(store!),
      send: fake.send,
      reads: fake.reads,
      build: 'test-build',
      clientId: clientId,
      inputs: inputs,
      timing: timing,
      clock: () => start.add(async.elapsed),
      elapsed: () => async.elapsed - slept.value,
      recordsConnectionLost: () => !dropsConnectionLost.value,
    );
    fake.whyNow = () => sender.reading;
    final world = World._(async, engine, store!, fake, sender)
      ..dropsConnectionLost = dropsConnectionLost
      .._slept = slept
      .._account = inputs.account
      .._connection = inputs.connection
      .._authChanges = inputs.signIns
      .._signOuts = inputs.signOuts;
    sender.start();
    return world;
  }

  void addServedStrategy() {
    sender.adopt(strategyId);
    settle(const Duration(seconds: 2));
    expect(sender.adopting(strategyId), isFalse);
    expect(cloud().queue.session.number, greaterThan(0));
  }

  void addOtherStrategy({Account? owner, String id = otherStrategy}) {
    final whose = owner ?? servedAccount;
    server.owners[id] = whose;
    final list = RemotePageList(
      header: app.RemoteStrategyHeader(
        publicId: id,
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
    server.rows[id] = StrategyRowSet(
      strategy: header.strategy as ReadableStrategy,
    );
    Saving<StrategySummary, LibraryRefusal>? added;
    store.addCloudStrategy(whose, header, const []).then(
      (value) => added = value,
    );
    async.flushMicrotasks();
    expect(added, isA<Saved<StrategySummary, LibraryRefusal>>());
  }

  void settle([Duration time = const Duration(seconds: 2)]) {
    async.elapse(time);
    async.flushMicrotasks();
  }

  LiveElement firstElement() {
    final first = serverRows().elements.whereType<LiveElement>().first;
    Reading<PageContent>? read;
    store
        .readPage(strategyId, first.pagePublicId)
        .then((value) => read = value);
    async.flushMicrotasks();
    return (read! as Found<PageContent>)
        .value
        .elements
        .whereType<LiveElement>()
        .firstWhere((element) => element.publicId == first.publicId);
  }

  void commitMove(int n) {
    final element = firstElement();
    _commit(strategyId, servedAccount, [moveOf(element, n, 'move-$n')]);
  }

  static ElementPatchOp moveOf(LiveElement element, int n, String opId) =>
      ElementPatchOp(
        opId: opId,
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
      );

  OpAnswer teammateRotates(int n) {
    final first = serverRows().elements.whereType<LiveElement>().first;
    final onServer =
        server.rows[strategyId]!.element(first.publicId)! as LiveElement;
    return server.teammate(
      strategyId,
      ElementPatchOp(
        opId: 'teammate-rotates-$n',
        elementPublicId: onServer.publicId,
        expectedElementRevision: onServer.revision,
        payload: ElementPayload(
          kind: onServer.payload.kind,
          payloadVersion: onServer.payload.payloadVersion,
          data: {...onServer.payload.data.toJson(), 'rotation': n.toDouble()},
        ),
      ),
    );
  }

  OpAnswer teammateMoves(int n) {
    final first = serverRows().elements.whereType<LiveElement>().first;
    final onServer =
        server.rows[strategyId]!.element(first.publicId)! as LiveElement;
    return server.teammate(
      strategyId,
      moveOf(onServer, 500 + n, 'teammate-$n'),
    );
  }

  void secondPageOnServer() {
    final header = switch (pageListRead(
      pageList(serverRows(), more: [secondPage()]),
    )) {
      RowsRead(:final value) => value,
      RowsUnreadable(:final problem) => throw StateError('$problem'),
    };
    server.rows[strategyId] = server.rows[strategyId]!
        .withRows([...header.pages, ...header.settings]);
  }

  void teammateDeletesPage(String page) {
    final rows = server.rows[strategyId]!;
    server.rows[strategyId] = StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages.where((row) => row.publicId != page),
      settings: rows.settings.where((row) => row.pagePublicId != page),
      elements: rows.elements.where((row) => row.pagePublicId != page),
      lineupGroups: rows.lineupGroups.where((row) => row.pagePublicId != page),
    );
  }

  void commit(List<StrategyOp> ops) => _commit(strategyId, servedAccount, ops);

  T rowOf<T extends Row>(T? Function(StrategyContent content) find) {
    Reading<StrategyContent>? read;
    store.readStrategy(strategyId).then((value) => read = value);
    async.flushMicrotasks();
    return find((read! as Found<StrategyContent>).value)!;
  }

  void commitMerge(int n) {
    final element = firstElement();
    final move = moveOf(element, n, 'merge-$n');
    _commit(strategyId, servedAccount, [
      ElementPatchOp(
        opId: move.opId,
        elementPublicId: move.elementPublicId,
        expectedElementRevision: move.expectedElementRevision,
        payload: move.payload,
        merge: FieldMerge(fields: const ['position']),
      ),
    ]);
  }

  void commitElementDelete(String opId) {
    final element = firstElement();
    _commit(strategyId, servedAccount, [
      ElementDeleteOp(
        opId: opId,
        elementPublicId: element.publicId,
        pagePublicId: element.pagePublicId,
        expectedElementRevision: element.revision,
      ),
    ]);
  }

  void commitPageDelete(String opId, String pageId) {
    Reading<StrategyContent>? read;
    store.readStrategy(strategyId).then((value) => read = value);
    async.flushMicrotasks();
    final row = (read! as Found<StrategyContent>).value.strategy;
    _commit(strategyId, servedAccount, [
      PageDeleteOp(
        opId: opId,
        pagePublicId: pageId,
        expectedStrategyRevision: (row.toJson()! as Map)['revision']! as int,
      ),
    ]);
  }

  void commitAdds(int count, {int from = 0}) {
    final first = serverRows().elements.whereType<LiveElement>().first;
    _commit(strategyId, servedAccount, [
      for (var n = from; n < from + count; n++)
        ElementAddOp(
          opId: 'add-$n',
          elementPublicId: 'added-$n',
          pagePublicId: first.pagePublicId,
          payload: first.payload,
          sortIndex: 100 + n,
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

  List<String> readsRecorded([String strategy = strategyId]) => [
        for (final report in sender.store.reports)
          if (report case ReadRecorded(:final strategyId, :final read)
              when strategyId == strategy)
            read,
      ];

  String status([String strategy = strategyId]) =>
      '${sender.view.strategies[strategy]}';
}

void inWorld(
  void Function(World world) body, {
  MemoryStorage? storage,
  FakeServer? server,
  bool addStrategy = true,
  String clientId = 'client-1',
  bool keepOpen = false,
}) {
  fakeAsync((async) {
    final world = World.open(
      async,
      storage: storage,
      server: server,
      clientId: clientId,
    );
    if (addStrategy) world.addServedStrategy();
    body(world);
    if (!keepOpen) {
      world.sender.dispose();
      world.store.close();
      async.flushMicrotasks();
    }
  });
}
