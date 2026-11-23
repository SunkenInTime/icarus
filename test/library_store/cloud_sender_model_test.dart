import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart'
    show at, pageList, pageSnapshot, serverRows, servedAccount, strategyId;
import 'sender_world.dart';

const seeds = int.fromEnvironment('SENDER_MODEL_SEEDS', defaultValue: 480);
const steps = 70;
const strategies = [strategyId, otherStrategy];

final class Model {
  Model(
    this.async,
    this.random,
    this.storage,
    this.server, {
    this.dropLost,
    Random? drops,
  }) : drops = drops ?? Random(random.nextInt(1 << 30));

  final bool? dropLost;
  final Random drops;

  final FakeAsync async;
  final Random random;
  final MemoryStorage storage;
  final FakeServer server;
  late World world;
  var edits = 0;
  var restarts = 0;
  final log = <String>[];
  Account? account = servedAccount;
  int? connection = 1;
  int signIns = 1;
  var nextConnection = 2;
  int? refusedAt;
  final broken = <String>[];
  final committed = <String, String>{};
  final folded = <String>{};
  final oldStamps = <Snapshot>[];

  Snapshot get stamp =>
      (account: account, connection: connection, signIns: signIns);

  void open({required bool first}) {
    world = World.open(
      async,
      storage: storage,
      server: server,
      clientId: 'client-${restarts + 1}',
      startingWith: stamp,
    );
    _resultsSignIns = signIns;
    _lastArrival = -1;
    server.onCall = (call) {
      final under = world.sender.sendingUnder;
      if (under != stamp) {
        broken.add('a batch went out under $under while the inputs were '
            '$stamp');
      }
      if (world.sender.held case final reason?) {
        broken.add('a call while sending was held ($reason)');
      }
      if (refusedAt == signIns) {
        broken.add('a call after a sign-in refusal, with the sign-in '
            'unchanged');
      }
    };
    if (first) {
      world.addServedStrategy();
      world.addOtherStrategy();
    }
    results();
  }

  void restart() {
    _readReports();
    world.sender.dispose();
    world.close();
    world.store.close();
    async.flushMicrotasks();
    restarts++;
    refusedAt = null;
    _read = 0;
    _opened.clear();
    _restartsWritten.clear();
    open(first: false);
  }

  void remember() {
    oldStamps.add(stamp);
    if (oldStamps.length > 4) oldStamps.removeAt(0);
  }

  void results([Snapshot? under]) {
    final given = under ?? stamp;
    final shadow = world.shadow!;
    for (final strategy in strategies) {
      final revision = server.revisions[strategy] ?? 1;
      if (strategy == strategyId) {
        shadow.pageList(
          strategy,
          pageList(serverRows(), revision: revision),
          given.connection,
          stamp: given,
        );
        shadow.page(
          strategy,
          pageSnapshot(serverRows()),
          given.connection,
          stamp: given,
        );
      } else {
        shadow.pageList(
          strategy,
          RemotePageList(
            header: app.RemoteStrategyHeader(
              publicId: otherStrategy,
              name: 'Second',
              mapData: 'bind',
              revision: revision,
              createdAt: at,
              updatedAt: at,
              role: 'owner',
            ),
            pages: const [],
          ),
          given.connection,
          stamp: given,
        );
      }
    }
    async.flushMicrotasks();
  }

  void staleResult() {
    if (oldStamps.isEmpty) return;
    final old = oldStamps[random.nextInt(oldStamps.length)];
    if (old.connection == connection && old.account == account) return;
    final before = world.sender.store.reports.length;
    results(old);
    world.settle(const Duration(milliseconds: 500));
    for (final report in world.sender.store.reports.skip(before)) {
      if (report case ResultWritten(stamp: final written) when written == old) {
        broken.add('a result that arrived under $old was recorded while the '
            'inputs were $stamp');
      }
    }
    log.add('stale result under ${old.connection}');
  }

  Set<String> _present() {
    final present = <String>{};
    for (final strategy in strategies) {
      final cloud = world.cloud(strategy);
      present
        ..addAll([for (final entry in cloud.queue.entries) entry.id])
        ..addAll([for (final work in cloud.queue.landed) work.op.opId]);
    }
    return present;
  }

  void edit() {
    final strategy = strategies[random.nextInt(2)];
    Reading<StrategyContent>? read;
    world.store.readStrategy(strategy).then((value) => read = value);
    async.flushMicrotasks();
    if (read case Found(value: StrategyContent(strategy: final row))) {
      final revision = (row.toJson()! as Map)['revision']! as int;
      final before = _present();
      final entries = world.cloud(strategy).queue.entries;
      final lastEntry = entries.isEmpty ? null : entries.last.id;
      edits++;
      final id = 'edit-$edits';
      Saving<List<Committed>, CommitRefusal>? saved;
      world.store.commitAllAs(servedAccount, strategy, [
        StrategyPatchOp(
          opId: id,
          expectedStrategyRevision: revision,
          name: 'Edit $edits',
        ),
      ]).then((value) => saved = value);
      async.flushMicrotasks();
      if (saved is Saved) {
        committed[id] = strategy;
        final after = _present();
        final gone = before.difference(after);
        if (gone.isNotEmpty) {
          if (gone.length == 1 &&
              gone.single == lastEntry &&
              after.contains(id)) {
            folded.add(gone.single);
          } else {
            broken.add('committing $id took $gone out of the queue');
          }
        }
      }
    }
  }

  final _removed = <String>{};
  final _opened = <(String, int), Snapshot>{};
  final _restartsWritten = <String, int>{};
  int? _resultsSignIns;
  var _read = 0;
  var _lastArrival = -1;

  void _inArrivalOrder(Object arrival, String what) {
    final index = world.arrivals.indexWhere((seen) => identical(seen, arrival));
    if (index < 0) return;
    if (index < _lastArrival) {
      broken.add('$what, arrival $index, was recorded after arrival '
          '$_lastArrival');
    }
    _lastArrival = max(_lastArrival, index);
  }

  static bool _isAnswer(QueueEvent event) => switch (event) {
        OpAnswered() || BatchRefused() || ClaimReleased() => true,
        TransportFailed(:final failure) => failure != TransportFailure.timeout,
        _ => false,
      };

  void _readReports() {
    final reports = world.sender.store.reports;
    for (final report in reports.skip(_read)) {
      switch (report) {
        case EventsWritten(
            :final strategyId,
            :final events,
            :final effects,
            :final batch,
          ):
          if (batch != null && events.every(_isAnswer)) {
            _inArrivalOrder(batch.ops, 'the answer to $batch');
          }
          for (final effect in effects) {
            if (effect case OpRemoved(:final opId)) _removed.add(opId);
          }
          if (events.any((event) => event is AppRestarted)) {
            final times = _restartsWritten.update(
              strategyId,
              (times) => times + 1,
              ifAbsent: () => 1,
            );
            if (times > 1) {
              broken.add('AppRestarted written $times times for $strategyId '
                  'in one run');
            }
          }
        case SessionOpenedFor(:final strategyId, :final session, :final stamp):
          _opened[(strategyId, session)] = stamp;
        case ResultWritten(
            :final strategyId,
            :final session,
            :final stamp,
            :final inputsWhenWritten,
            :final result,
          ):
          if (!world.arrivals.any((seen) => identical(seen, result))) {
            broken.add('a result for $strategyId was recorded that never '
                'arrived');
          }
          _inArrivalOrder(result, 'a result for $strategyId');
          if (inputsWhenWritten != stamp) {
            broken.add('a result under $stamp was written while the inputs '
                'were $inputsWhenWritten');
          }
          if (stamp.signIns != _resultsSignIns) {
            broken.add('a result under sign-in ${stamp.signIns} was written '
                'in a run whose results began under $_resultsSignIns');
          }
          final under = _opened[(strategyId, session)];
          if (under == null ||
              under.connection != stamp.connection ||
              under.account != stamp.account) {
            broken.add('a result under $stamp went into session $session of '
                '$strategyId, which was opened for $under');
          }
        case _:
          break;
      }
    }
    _read = reports.length;
  }

  void checkAccounted() {
    _readReports();
    final present = _present();
    final removed = _removed;
    for (final MapEntry(key: id, value: strategy) in committed.entries) {
      if (present.contains(id) || folded.contains(id) || removed.contains(id)) {
        continue;
      }
      broken.add('$id of $strategy left the queue with no cause recorded');
    }
  }

  void transport() {
    final strategy = strategies[random.nextInt(2)];
    final choice = random.nextInt(7);
    log.add('transport $strategy $choice');
    switch (choice) {
      case 0:
        server.answerNext(strategy, (call) async {
          server.applyAll(call);
          return const StoreBatchLost(TransportFailure.network, 'lost after');
        });
      case 1:
        server.answerNext(
          strategy,
          (_) async =>
              const StoreBatchLost(TransportFailure.network, 'lost before'),
        );
      case 2:
        server.answerNext(strategy, (call) {
          server.applyAll(call);
          return Completer<StoreBatchOutcome>().future;
        });
      case 3:
        server.answerNext(
          strategy,
          (_) => Completer<StoreBatchOutcome>().future,
        );
      case 4:
        server.answerNext(
          strategy,
          (_) => Future.microtask(() {
            refusedAt = signIns;
            return const StoreBatchRefusedWhole(BatchRefusal.unauthenticated);
          }),
        );
      case 5:
        server.answerNext(
          strategy,
          (_) => Future.microtask(() {
            refusedAt = signIns;
            return const StoreBatchAccountMismatch('another account');
          }),
        );
      case _:
        final answer = Completer<StoreBatchOutcome>();
        server.answerNext(strategy, (call) {
          final outcome = server.applyAll(call);
          Timer(
            Duration(seconds: random.nextInt(90)),
            () => answer.complete(outcome),
          );
          return answer.future;
        });
    }
  }

  void changeDuringWrite() {
    final hold = storage.holdNextWrite();
    world.sender.wake();
    world.settle(const Duration(milliseconds: 300));
    remember();
    final choice = random.nextInt(3);
    if (choice == 2) {
      world.sender.hold('held while a write is held');
      log.add('hold while a write is held');
    } else if (choice == 0) {
      connection = nextConnection++;
      world.connection = connection;
      log.add('connection $connection while a write is held');
    } else {
      account = account == servedAccount ? otherAccount : servedAccount;
      world.account = account;
      log.add('account ${account?.subject} while a write is held');
    }
    hold.letGo();
    async.flushMicrotasks();
  }

  var _fresh = 0;

  void _probeHeld(
    String what,
    void Function() hand,
    void Function(ResultOutcome? outcome) check,
  ) {
    final sender = world.sender;
    final wasHeld = sender.held;
    sender.hold('held for a probe');
    world.settle(const Duration(milliseconds: 300));
    final hold = storage.holdNextWrite();
    var reached = false;
    unawaited(
      hold.reached.then((_) {
        reached = true;
        remember();
        connection = nextConnection++;
        world.connection = connection;
      }),
    );
    final arrivedBefore = world.arrivals.length;
    hand();
    final result = world.arrivals.length > arrivedBefore
        ? world.arrivals[arrivedBefore]
        : null;
    world.settle(const Duration(milliseconds: 300));
    hold.letGo();
    world.settle(const Duration(milliseconds: 300));
    if (wasHeld == null) {
      sender.release();
    } else {
      sender.hold(wasHeld);
    }
    log.add('$what${reached ? '' : ' (no write reached)'}');
    if (reached && result is ResultForStore) {
      check(world.intake.outcomes[result]);
    }
  }

  bool get _resultsWouldBeTaken =>
      !world.sender.busy &&
      connection != null &&
      account == servedAccount &&
      world.sender.resultsSignIns == signIns;

  void heldAdd() {
    if (!_resultsWouldBeTaken) return;
    final id = 'fresh-${++_fresh}';
    server.owners[id] = servedAccount;
    _probeHeld(
      'the add of $id is held while the connection changes',
      () {
        final given = stamp;
        world.shadow!.pageList(
          id,
          RemotePageList(
            header: app.RemoteStrategyHeader(
              publicId: id,
              name: 'Fresh',
              mapData: 'bind',
              revision: 1,
              createdAt: at,
              updatedAt: at,
              role: 'owner',
            ),
            pages: const [],
          ),
          given.connection,
          stamp: given,
        );
      },
      (outcome) {
        if (outcome is! ResultStale) {
          broken.add('the first page list of $id was added while the '
              'connection changed, and the intake was told $outcome');
        }
        if (world.sender.bound[id] case final session?) {
          broken.add('$id was bound to $session though its add outlived its '
              'connection');
        }
      },
    );
  }

  void heldSessionWrite() {
    if (!_resultsWouldBeTaken) return;
    remember();
    connection = nextConnection++;
    world.connection = connection;
    world.settle(const Duration(milliseconds: 300));
    if (!_resultsWouldBeTaken) return;
    final before = world.cloud().queue.session.number;
    _probeHeld(
      'the first session write after reconnecting is held while the '
      'connection changes',
      () {
        world.shadow!.page(
          strategyId,
          pageSnapshot(serverRows()),
          connection,
          stamp: stamp,
        );
      },
      (outcome) {
        final opened = world.cloud().queue.session.number;
        if (opened == before) return;
        if (outcome is! ResultStale) {
          broken.add('a result whose session write outlived its connection '
              'was answered $outcome');
        }
        if (world.sender.bound[strategyId] case final session?
            when session.number == opened) {
          broken.add('$strategyId was bound to session $opened, opened for a '
              'connection replaced during its write');
        }
      },
    );
  }

  void waitAndCountLooks(int seconds) {
    final sender = world.sender;
    final (looks, wakes, dues, acts) =
        (sender.looks, sender.wakes, sender.dues, sender.acts);
    world.settle(Duration(seconds: seconds));
    final caused =
        (sender.wakes - wakes) + (sender.dues - dues) + (sender.acts - acts);
    if (sender.looks - looks > 2 * caused + 2) {
      broken.add('${sender.looks - looks} looks in $seconds s with $caused '
          'wakes, due times and steps to cause them');
    }
  }

  void step() {
    world.dropsConnectionLost.value = switch (dropLost) {
      true => true,
      false => false,
      null => drops.nextBool(),
    };
    final choice = random.nextInt(19);
    switch (choice) {
      case 0 || 1 || 2:
        edit();
        log.add('edit');
      case 3:
        world.sender.wake();
        log.add('wake');
      case 4:
        remember();
        connection =
            connection == null || random.nextBool() ? nextConnection++ : null;
        world.connection = connection;
        log.add('connection $connection');
      case 5:
        remember();
        final options = [servedAccount, otherAccount, null];
        account = options[random.nextInt(3)];
        signIns++;
        world
          ..account = account
          ..authChanges = signIns;
        log.add('sign-in ${account?.subject}');
      case 6:
        transport();
      case 7:
        final strategy = strategies[random.nextInt(2)];
        if (!world.lease.refusedAreas.remove(strategy)) {
          world.lease.refusedAreas.add(strategy);
        }
        log.add('disk refuses ${world.lease.refusedAreas}');
      case 8:
        world.lease.refuseNext = 1;
        log.add('disk refuses one write');
      case 9:
        world.sender.hold('held by the model');
        log.add('hold');
      case 10:
        world.sender.release();
        log.add('release');
      case 11:
        restart();
        log.add('restart');
      case 12:
        results();
        log.add('results');
      case 13:
        changeDuringWrite();
      case 14:
        staleResult();
      case 15 when random.nextBool():
        world.slowStore.afterRead = random.nextBool()
            ? Duration(milliseconds: random.nextInt(1500))
            : Duration.zero;
        log.add('reads take ${world.slowStore.afterRead}');
      case 15:
        world.slowStore.dropSessionReadBack = 1;
        log.add('one session read-back is lost');
      case 17:
        heldAdd();
      case 18:
        heldSessionWrite();
      case _:
        final seconds = random.nextInt(60);
        waitAndCountLooks(seconds);
        log.add('wait $seconds s');
    }
    async.flushMicrotasks();
  }

  void checkSafety() {
    checkAccounted();
    expect(broken, isEmpty, reason: trail);
    expect(server.anyAppliedTwice, isFalse, reason: 'applied twice\n$trail');
    expect(
      server.wrongAccount.map((call) => '${call.strategyId} ${call.account}'),
      isEmpty,
      reason: 'sent as an account that does not own it\n$trail',
    );
    expect(
      [
        for (final report in world.shadow!.reports)
          if (report case ShadowSessionOpened(:final because)
              when because != 'the sender opened it' &&
                  because != 'the strategy was added')
            because,
      ],
      isEmpty,
      reason: 'the shadow opened a session itself\n$trail',
    );
  }

  bool get _healthy =>
      connection != null &&
      account == servedAccount &&
      world.sender.held == null &&
      !world.sender.upgradeAsked &&
      world.sender.signInWaitFrom != signIns &&
      world.lease.refuseNext == 0 &&
      server.answersNormally &&
      world.slowStore.dropSessionReadBack == 0 &&
      world.slowStore.afterRead == Duration.zero &&
      !world.sender.inStep;

  bool _idle(String strategy) =>
      !world.sender.notBefore.containsKey(strategy) &&
      world.cloud(strategy).queue.entries.isEmpty &&
      world.cloud(strategy).queue.landed.isEmpty;

  void checkIsolation() {
    final refused = world.lease.refusedAreas;
    if (refused.length != 1 || !_healthy) return;
    final healthy = strategies.firstWhere((id) => !refused.contains(id));
    if (!_idle(healthy)) return;
    final before = server.calls.length;
    edits++;
    final id = 'probe-$edits';
    world.commitRename(healthy, id);
    committed[id] = healthy;
    world.settle(const Duration(seconds: 1));
    if (!server.calls.skip(before).any((call) => call.strategyId == healthy)) {
      broken.add('work for $healthy waited behind $refused; sender '
          '${world.sender.view}');
    }
  }

  void checkFairness() {
    if (world.lease.refusedAreas.isNotEmpty || !_healthy) return;
    if (!strategies.every(_idle)) return;
    final before = server.calls.length;
    for (final strategy in strategies) {
      edits++;
      final id = 'fair-$edits';
      world.commitRename(strategy, id);
      committed[id] = strategy;
    }
    world.settle(const Duration(seconds: 2));
    final served = {
      for (final call in server.calls.skip(before)) call.strategyId,
    };
    if (served.length != 2) {
      broken.add('with work in both strategies, only $served was served in '
          '2 s; sender ${world.sender.view}');
    }
  }

  void heal() {
    server.answerNormally();
    world.slowStore
      ..afterRead = Duration.zero
      ..dropSessionReadBack = 0;
    world.lease
      ..refusedAreas.clear()
      ..refuseNext = 0;
    account = servedAccount;
    connection ??= nextConnection++;
    world
      ..account = account
      ..connection = connection;
    world.sender.release();
    final sender = world.sender;
    if ((sender.resultsSignIns != null && sender.resultsSignIns != signIns) ||
        sender.signInWaitFrom == signIns ||
        sender.upgradeAsked) {
      restart();
    }
  }

  void checkLiveness() {
    heal();
    world.settle(const Duration(minutes: 5));
    for (final strategy in strategies) {
      final cloud = world.cloud(strategy);
      final sendable = [
        for (final entry in cloud.queue.entries)
          if (cloud.views[entry.id]?.sendable ?? false) entry.id,
      ];
      expect(
        sendable,
        isEmpty,
        reason: 'after five quiet minutes $strategy still holds work it could '
            'send: the loop slept on it; sender ${world.sender.view}\n$trail',
      );
    }
    for (var round = 0; round < 30; round++) {
      world.settle(const Duration(minutes: 1));
      results();
      if (_settledOrNeedsYou()) break;
    }
    for (final strategy in strategies) {
      final cloud = world.cloud(strategy);
      for (final entry in cloud.queue.entries) {
        expect(
          _needsUser(cloud, entry.id),
          isTrue,
          reason: '${entry.id} of $strategy is neither sent nor needing the '
              'user; queue: ${[
            for (final other in cloud.queue.entries)
              '${other.id} ${cloud.views[other.id]?.state} '
                  '${cloud.views[other.id]?.holds}',
          ].join('; ')}; sender ${world.sender.view}\n$trail',
        );
      }
    }
    final looks = world.sender.looks;
    world.settle(const Duration(minutes: 10));
    expect(
      world.sender.looks - looks,
      lessThanOrEqualTo(2),
      reason: 'the loop kept looking with nothing to do\n$trail',
    );
    checkSafety();
  }

  void checkTurns() {
    const fresh = 'hand-turns';
    world.addOtherStrategy(id: fresh);
    world.settle();
    final before = server.calls.length;
    world.commitAdds(50, from: 1000 + edits);
    edits++;
    world.commitRename(fresh, 'turn-$edits');
    world.settle(const Duration(seconds: 20));
    final order = [
      for (final call in server.calls.skip(before)) call.strategyId,
    ];
    expect(
      order.indexOf(fresh),
      inInclusiveRange(0, 1),
      reason: 'with a backlog in one strategy, the other was served '
          '${order.indexOf(fresh)}th: $order\n$trail',
    );
  }

  ({Set<(String, String)> applied, Set<String> queued}) get outcome => (
        applied: server.appliedTimes.keys.toSet(),
        queued: {
          for (final strategy in strategies)
            for (final entry in world.cloud(strategy).queue.entries) entry.id,
        },
      );

  bool _settledOrNeedsYou() => strategies.every((strategy) {
        final cloud = world.cloud(strategy);
        return cloud.queue.entries.every(
          (entry) => _needsUser(cloud, entry.id),
        );
      });

  bool _needsUser(CloudStrategy cloud, String id, [int depth = 0]) {
    final view = cloud.views[id];
    if (view == null || depth > 100) return false;
    if (view.state is NeedsUser) return true;
    return view.holds.isNotEmpty &&
        view.holds.every(
          (hold) =>
              hold is BehindEntry && _needsUser(cloud, hold.opId, depth + 1),
        );
  }

  String get trail => log.skip(max(0, log.length - 40)).join(' | ');
}

typedef Outcome = ({Set<(String, String)> applied, Set<String> queued});

Outcome? runSeed(int seed, {bool? dropLost, List<String>? found}) {
  Outcome? ended;
  fakeAsync((async) {
    final model = Model(
      async,
      Random(seed),
      MemoryStorage(),
      FakeServer(),
      dropLost: dropLost,
      drops: dropLost == null ? null : Random(0),
    );
    model.open(first: true);
    try {
      for (var i = 0; i < steps; i++) {
        model.step();
        model.checkSafety();
        if (i % 10 == 9) model.checkIsolation();
        if (i % 10 == 4) model.checkFairness();
      }
      model.checkLiveness();
      model.checkTurns();
      model.checkSafety();
      final outcome = model.outcome;
      unawaited(model.world.store.close());
      model.world.settle(const Duration(seconds: 1));
      expect(
        model.world.sender.ended,
        isNotNull,
        reason: 'closing a quiet store did not end the loop',
      );
      ended = outcome;
    } on TestFailure catch (failure) {
      found?.add(
          'seed $seed${dropLost == null ? '' : ' (ConnectionLost ${dropLost ? 'dropped' : 'kept'})'}: ${failure.message}');
    } finally {
      model.world.sender.dispose();
      model.world.close();
      model.world.store.close();
      async.flushMicrotasks();
    }
  });
  return ended;
}

void main() {
  test('the loop keeps its promises through $seeds random runs', () {
    final found = <String>[];
    for (var seed = const int.fromEnvironment('SENDER_MODEL_FROM');
        seed < seeds;
        seed++) {
      runSeed(seed, found: found);
      if (found.isNotEmpty) break;
    }
    expect(found, isEmpty);
  });

  test(
      'the same schedule with ConnectionLost always dropped and never dropped '
      'ends the same way', () {
    final found = <String>[];
    for (var seed = 0; seed < 40; seed++) {
      final kept = runSeed(seed, dropLost: false, found: found);
      final dropped = runSeed(seed, dropLost: true, found: found);
      if (kept != null && dropped != null) {
        if (kept.applied.length != dropped.applied.length ||
            !kept.applied.containsAll(dropped.applied) ||
            kept.queued.length != dropped.queued.length ||
            !kept.queued.containsAll(dropped.queued)) {
          found.add('seed $seed ends differently: kept $kept, dropped '
              '$dropped');
        }
      }
      if (found.isNotEmpty) break;
    }
    expect(found, isEmpty);
  });
}
