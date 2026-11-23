import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart'
    show at, pageList, pageSnapshot, serverRows, servedAccount, strategyId;
import 'sender_world.dart';

const seeds = int.fromEnvironment('SENDER_MODEL_SEEDS', defaultValue: 60);
const steps = 70;
const strategies = [strategyId, otherStrategy];

final class Model {
  Model(this.async, this.random, this.storage, this.server);

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
  int authChanges = 1;
  var nextConnection = 2;
  int? refusedAt;
  final broken = <String>[];

  void open({required bool first}) {
    world = World.open(
      async,
      storage: storage,
      server: server,
      clientId: 'client-${restarts + 1}',
    );
    world.account = account;
    world.connection = connection;
    world.authChanges = authChanges;
    server.onCall = (call) {
      final flight = world.sender.memories[call.strategyId]?.flight;
      final session = flight is CallInFlight ? flight.batch.session : null;
      if (session == null ||
          session.connection != connection ||
          session.authChanges != authChanges ||
          session.account != account) {
        broken.add('a batch went out under $session while the inputs were '
            '$account, $connection, $authChanges');
      }
      if (refusedAt == authChanges) {
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
    world.sender.dispose();
    world.close();
    world.store.close();
    async.flushMicrotasks();
    restarts++;
    refusedAt = null;
    open(first: false);
  }

  void results() {
    final shadow = world.shadow!;
    if (connection == null || account != servedAccount) return;
    for (final strategy in strategies) {
      final revision = server.revisions[strategy] ?? 1;
      if (strategy == strategyId) {
        shadow.pageList(
          strategy,
          pageList(serverRows(), revision: revision),
          connection,
        );
        shadow.page(strategy, pageSnapshot(serverRows()), connection);
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
          connection,
        );
      }
    }
    async.flushMicrotasks();
  }

  void edit() {
    final strategy = strategies[random.nextInt(2)];
    Reading<StrategyContent>? read;
    world.store.readStrategy(strategy).then((value) => read = value);
    async.flushMicrotasks();
    if (read case Found(value: StrategyContent(strategy: final row))) {
      final revision = (row.toJson()! as Map)['revision']! as int;
      edits++;
      world.store.commitAllAs(servedAccount, strategy, [
        StrategyPatchOp(
          opId: 'edit-$edits',
          expectedStrategyRevision: revision,
          name: 'Edit $edits',
        ),
      ]);
      async.flushMicrotasks();
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
            refusedAt = authChanges;
            return const StoreBatchRefusedWhole(BatchRefusal.unauthenticated);
          }),
        );
      case 5:
        server.answerNext(
          strategy,
          (_) => Future.microtask(() {
            refusedAt = authChanges;
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
    world.sender.nudge();
    world.settle(const Duration(milliseconds: 300));
    if (random.nextBool()) {
      connection = connection == null ? nextConnection++ : nextConnection++;
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

  void step() {
    final choice = random.nextInt(15);
    switch (choice) {
      case 14:
        changeDuringWrite();
      case 0 || 1 || 2:
        edit();
        log.add('edit');
      case 3:
        world.sender.nudge();
        log.add('wake');
      case 4:
        connection =
            connection == null || random.nextBool() ? nextConnection++ : null;
        world.connection = connection;
        log.add('connection $connection');
      case 5:
        final options = [servedAccount, otherAccount, null];
        account = options[random.nextInt(3)];
        authChanges++;
        world
          ..account = account
          ..authChanges = authChanges;
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
      case _:
        final seconds = random.nextInt(60);
        world.settle(Duration(seconds: seconds));
        log.add('wait $seconds s');
    }
    async.flushMicrotasks();
  }

  void checkSafety() {
    expect(broken, isEmpty, reason: trail);
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
    expect(server.anyAppliedTwice, isFalse, reason: 'applied twice\n$trail');
    expect(
      server.wrongAccount.map((call) => '${call.strategyId} ${call.account}'),
      isEmpty,
      reason: 'sent as an account that does not own it\n$trail',
    );
  }

  void checkIsolation() {
    final refused = world.lease.refusedAreas;
    if (refused.length != 1) return;
    final healthy = strategies.firstWhere((id) => !refused.contains(id));
    final memory = world.sender.memories[healthy];
    final run = world.sender.run;
    if (connection == null ||
        account != servedAccount ||
        run.held != null ||
        run.upgradeAsked ||
        run.signInWaitsFrom == authChanges ||
        world.lease.refuseNext > 0 ||
        memory == null ||
        memory.flight != null ||
        memory.owed != null ||
        memory.retry != null ||
        memory.parked != null ||
        world.cloud(healthy).queue.entries.isNotEmpty ||
        world.cloud(healthy).queue.landed.isNotEmpty) {
      return;
    }
    final before = server.calls.length;
    edits++;
    world.commitRename(healthy, 'probe-$edits');
    world.settle(const Duration(seconds: 1));
    expect(
      server.calls.skip(before).any((call) => call.strategyId == healthy),
      isTrue,
      reason: 'work for $healthy waited behind $refused; sender '
          '${world.sender.view}; reports ${world.sender.store.reports.skip(max(0, world.sender.store.reports.length - 6)).map((r) => switch (r) {
                EventsWritten(:final events) => 'wrote $events',
                WriteNotMade(:final trouble) => 'not ${trouble.why}',
                _ => '$r'
              }).join(', ')}\n$trail',
    );
  }

  void heal() {
    server.answerNormally();
    world.lease
      ..refusedAreas.clear()
      ..refuseNext = 0;
    account = servedAccount;
    connection ??= nextConnection++;
    authChanges++;
    world
      ..account = account
      ..connection = connection
      ..authChanges = authChanges;
    world.sender.release();
  }

  void checkLiveness() {
    heal();
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
          ].join('; ')}; landed ${cloud.queue.landed.length}; sender '
              '${world.sender.view}\n$trail',
        );
      }
    }
    checkSafety();
  }

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

void main() {
  test('the sender keeps its promises through $seeds random runs', () {
    final found = <String>[];
    for (var seed = 0; seed < seeds; seed++) {
      fakeAsync((async) {
        final model = Model(async, Random(seed), MemoryStorage(), FakeServer());
        model.open(first: true);
        try {
          for (var i = 0; i < steps; i++) {
            model.step();
            model.checkSafety();
            if (i % 10 == 9) model.checkIsolation();
          }
          model.checkLiveness();
        } on TestFailure catch (failure) {
          found.add('seed $seed: ${failure.message}');
        } finally {
          model.world.sender.dispose();
          model.world.close();
          model.world.store.close();
          async.flushMicrotasks();
        }
      });
      if (found.isNotEmpty) break;
    }
    expect(found, isEmpty);
  });
}
