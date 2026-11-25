import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/landed_retiring.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart'
    show secondPage, serverRows, servedAccount, strategyId;
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
  int signOuts = 0;

  void _signedInAs(Account? next) {
    if (account != null && next == null) signOuts++;
    account = next;
  }

  var nextConnection = 2;
  int? refusedAt;
  final broken = <String>[];
  final committed = <String, String>{};
  final folded = <String>{};

  Snapshot get stamp => (
        account: account,
        connection: connection,
        signIns: signIns,
        signOuts: signOuts,
      );

  void open({required bool first}) {
    world = World.open(
      async,
      storage: storage,
      server: server,
      clientId: 'client-${restarts + 1}',
      startingWith: stamp,
    );
    server.onRead = (call) {
      _underAt[call] = (restarts, world.readEras);
      if (call.why == 'edit access was lost') {
        _lossAt[call] = (
          world.cloud(call.strategyId).queue.strategy.accessLostAt,
          (restarts, world.readEras),
        );
      }
      if (world.sender.sendingUnder != stamp) {
        broken.add('$call of ${call.strategyId} went out under '
            '${world.sender.sendingUnder} while the inputs were $stamp');
      }
      if (world.sender.held case final reason?) {
        broken.add('a read while sending was held ($reason)');
      }
      if (refusedAt == signIns) {
        broken.add('a read after a sign-in refusal, with the sign-in '
            'unchanged');
      }
    };
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
      world
        ..secondPageOnServer()
        ..addServedStrategy();
      _requestsSeen = server.readCalls.length;
      world.addOtherStrategy();
    }
  }

  void restart() {
    _readReports();
    world.sender.dispose();
    world.store.close();
    async.flushMicrotasks();
    restarts++;
    refusedAt = null;
    _read = 0;
    _restartsWritten.clear();
    _retired.clear();
    _lastViewer.clear();
    _lastAccess.clear();
    _requestsSeen = server.readCalls.length;
    open(first: false);
  }

  void teammate() {
    final strategy = strategies[random.nextInt(2)];
    final row = server.rows[strategy]!.strategy;
    final revision = (row.toJson() as Map)['revision']! as int;
    teammates++;
    server.teammate(
      strategy,
      StrategyPatchOp(
        opId: 'teammate-$teammates',
        expectedStrategyRevision: revision,
        name: 'Teammate $teammates',
      ),
    );
    log.add('teammate renames $strategy');
  }

  var teammates = 0;

  Set<String> _presentIn(String strategy) {
    final cloud = world.cloud(strategy);
    return {
      for (final entry in cloud.queue.entries) entry.id,
      for (final work in cloud.queue.landed) work.op.opId,
    };
  }

  Set<String> _present() => {for (final id in strategies) ..._presentIn(id)};

  StrategyContent? _content(String strategy) {
    Reading<StrategyContent>? read;
    world.store.readStrategy(strategy).then((value) => read = value);
    async.flushMicrotasks();
    return switch (read) {
      Found(:final value) => value,
      _ => null,
    };
  }

  static int _revision(Row row) => (row.toJson()! as Map)['revision']! as int;

  void _commitTracked(String strategy, StrategyOp op) {
    final before = {for (final id in strategies) id: _presentIn(id)};
    final entries = world.cloud(strategy).queue.entries;
    final lastEntry = entries.isEmpty ? null : entries.last.id;
    Saving<List<Committed>, CommitRefusal>? saved;
    world.store
        .commitAllAs(servedAccount, strategy, [op],
            madeOn: world.viewedLife(strategy))
        .then((value) => saved = value);
    async.flushMicrotasks();
    if (saved is! Saved) return;
    final id = op.opId;
    committed[id] = strategy;
    _epochs[strategy] = (_epochs[strategy] ?? 0) + 1;
    for (final other in strategies) {
      final after = _presentIn(other);
      final gone = before[other]!.difference(after);
      if (gone.isEmpty) continue;
      if (other == strategy &&
          gone.length == 1 &&
          gone.single == lastEntry &&
          after.contains(id)) {
        folded.add(gone.single);
      } else {
        broken.add('committing $id to $strategy took $gone out of the '
            'queue of $other');
      }
    }
  }

  void edit() {
    final strategy = strategies[random.nextInt(2)];
    final content = _content(strategy);
    if (content == null) return;
    edits++;
    _commitTracked(
      strategy,
      StrategyPatchOp(
        opId: 'edit-$edits',
        expectedStrategyRevision: _revision(content.strategy),
        name: 'Edit $edits',
      ),
    );
  }

  LiveElement? _element() {
    final first = serverRows().elements.whereType<LiveElement>().first;
    Reading<PageContent>? read;
    world.store
        .readPage(strategyId, first.pagePublicId)
        .then((value) => read = value);
    async.flushMicrotasks();
    return switch (read) {
      Found(:final value) => value.elements
          .whereType<LiveElement>()
          .where((element) => element.publicId == first.publicId)
          .firstOrNull,
      _ => null,
    };
  }

  void ownMove() {
    final element = _element();
    if (element == null) return;
    edits++;
    _commitTracked(strategyId, World.moveOf(element, edits, 'move-$edits'));
    log.add('own whole-row move');
  }

  String get _second => secondPage().page.publicId;

  void ownPageOp() {
    final content = _content(strategyId);
    if (content == null ||
        !content.pages.any((page) => page.publicId == _second) ||
        content.pages.length < 2) {
      return;
    }
    edits++;
    final revision = _revision(content.strategy);
    final choice = random.nextInt(3);
    if (choice == 2) {
      final page = content.pages.firstWhere((row) => row.publicId == _second);
      _commitTracked(
        strategyId,
        PagePatchOp(
          opId: 'page-rename-$edits',
          pagePublicId: _second,
          expectedPageRevision: _revision(page),
          name: 'Page $edits',
        ),
      );
      log.add('own page rename');
    } else if (choice == 1) {
      _commitTracked(
        strategyId,
        PageReorderOp(
          opId: 'reorder-$edits',
          pagePublicId: _second,
          sortIndex: random.nextInt(2),
          expectedStrategyRevision: revision,
        ),
      );
      log.add('own page reorder');
    } else {
      _commitTracked(
        strategyId,
        PageDeleteOp(
          opId: 'page-delete-$edits',
          pagePublicId: _second,
          expectedStrategyRevision: revision,
        ),
      );
      log.add('own page delete');
    }
  }

  void teammateOnRows() {
    switch (random.nextInt(3)) {
      case 0:
        final first = serverRows().elements.whereType<LiveElement>().first;
        if (server.rows[strategyId]!.element(first.publicId) is LiveElement) {
          teammates++;
          world.teammateMoves(teammates);
          log.add('teammate moves the element');
        }
      case 1:
        if (server.rows[strategyId]!.page(_second) != null) {
          world.teammateDeletesPage(_second);
          log.add('teammate deletes the second page');
        }
      case _:
        teammate();
    }
  }

  void viewerRefusal() {
    final strategy = strategies[random.nextInt(2)];
    server
      ..roles[strategy] = StoreReadRole.viewer
      ..answerWith(
        strategy,
        const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved),
      );
    log.add('$strategy refused as a viewer');
  }

  void checkRetireFloor() {
    heal();
    if (_element() == null) return;
    world.settle(const Duration(minutes: 11));
    final before = server.readCalls.length;
    ownMove();
    world.settle(const Duration(seconds: 40));
    ownMove();
    world.settle(const Duration(minutes: 1));
    final retires = [
      for (final call in server.readCalls.skip(before))
        if (call.why == 'landed work waits for a result' &&
            call.strategyId == strategyId)
          call,
    ];
    if (retires.length > 1) {
      broken.add('landed work of $strategyId was read for retirement '
          '${retires.length} times within five minutes: $retires');
    }
    log.add('retire probe');
  }

  void checkScheduled() {
    final sender = world.sender;
    if (connection == null ||
        account != servedAccount ||
        sender.held != null ||
        sender.runHold != null) {
      return;
    }
    if (sender.busy || sender.woken) return;
    final now = start.add(async.elapsed);
    final latest = now.add(timing.readAgainAfter + const Duration(minutes: 1));
    for (final stored in sender.store.strategies()) {
      if (stored.ownerAccount != servedAccount) continue;
      if (sender.cannotRead(stored.id) != null) continue;
      final cloud = world.cloud(stored.id);
      final shown = sender.couldNotResolve(stored.id, cloud)?.subjects ?? [];
      final unshown = {
        for (final view in cloud.views.values)
          for (final hold in view.holds)
            if (hold case AwaitingResult(:final subject)
                when !shown.contains('$subject'))
              '$subject',
      };
      if (unshown.isEmpty) continue;
      final outlook = sender.outlook(stored.id, cloud);
      final settled = now.add(timing.longestWait);
      final due = switch (outlook) {
        ReadAt(:final at) when at.isAfter(settled) => at,
        _ => settled,
      };
      final armed = sender.armedFor;
      final problem = switch (outlook) {
        _ when !sender.looksAt(stored) => 'the sender does not look at it',
        NothingToRead() => 'nothing is planned',
        _ when armed == null => 'a read is due by $due and no timer is armed',
        _ when armed.isAfter(due) =>
          'a read is due by $due and the timer is armed for $armed',
        _ when armed.isAfter(latest) =>
          'the timer is armed for $armed, past ten minutes from now',
        _ => null,
      };
      if (problem != null) {
        broken.add('${stored.id} asks for $unshown, none of it shown as '
            'could not resolve: $problem ($outlook)');
      }
    }
  }

  void reopen() {
    final strategy = strategies[random.nextInt(2)];
    world.sender.adopt(strategy);
    log.add('the editor opens $strategy again');
  }

  void checkRequests() {
    final calls = server.readCalls;
    for (var n = _requestsSeen; n < calls.length; n++) {
      final call = calls[n];
      final key = (call.strategyId, '$call');
      if (call.why == 'the strategy was adopted' && call.page == null) {
        broken.add('the page list of ${call.strategyId}, which the store '
            'holds, was read again for adoption');
      }
      switch (call.why) {
        case 'landed work waits for a result':
          final last = (_retired[key] ?? const [])
              .where(
                (read) =>
                    read.under == _underAt[call] && read.at.isBefore(call.at!),
              )
              .map((read) => read.at)
              .fold<DateTime?>(
                null,
                (latest, at) =>
                    latest == null || at.isAfter(latest) ? at : latest,
              );
          if (last != null &&
              call.at!.difference(last) < timing.retireAgainAfter) {
            broken.add('$call of ${call.strategyId} was requested to retire '
                'landed work ${call.at!.difference(last)} after a recorded '
                'read');
          }
        case 'edit access was lost':
          if ((_lastViewer[call.strategyId], _lossAt[call])
              case ((final at, final answered), final asked?)
              when answered == asked &&
                  call.at!.isAfter(at) &&
                  call.at!.difference(at) < timing.readAgainAfter) {
            broken.add('the page list of ${call.strategyId} was requested for '
                'edit access ${call.at!.difference(at)} after a viewer\'s '
                'answer to the same loss, under the same sign-in and '
                'connection');
          }
          _lastAccess[call.strategyId] = call;
      }
    }
    _requestsSeen = calls.length;
  }

  final _lossAt = <ReadCall, (int, (int, int))>{};
  final _underAt = <ReadCall, (int, int)>{};

  var _requestsSeen = 0;
  final _retired =
      <(String, String), List<({DateTime at, (int, int)? under})>>{};
  final _lastViewer = <String, (DateTime, (int, (int, int)))>{};
  final _lastAccess = <String, ReadCall>{};
  final _epochs = <String, int>{};
  final _needReads = <(String, String), List<(int, DateTime)>>{};

  final _removed = <String>{};
  final _restartsWritten = <String, int>{};
  var _read = 0;

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
          if (batch != null) {
            _epochs[strategyId] = (_epochs[strategyId] ?? 0) + 1;
          }
          if (events.any((event) => event is EditAccessConfirmed)) {
            final call = server.readCalls
                .where(
                  (call) =>
                      call.strategyId == strategyId &&
                      call.why == 'edit access was lost',
                )
                .lastOrNull;
            if (call == null || !(call.role?.edits ?? false)) {
              broken.add('edit access of $strategyId was confirmed after a '
                  'page list that said ${call?.role}');
            }
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
        case SessionOpenedFor(:final strategyId):
          _epochs[strategyId] = (_epochs[strategyId] ?? 0) + 1;
        case ReadRecorded(:final strategyId, :final read, :final why, :final at)
            when why == 'the queue asked for it':
          final epoch = _epochs[strategyId] ?? 0;
          final reads = (_needReads[(strategyId, read)] ??= [])
            ..add((epoch, at));
          final recent = reads.where(
            (entry) =>
                entry.$1 == epoch &&
                at.difference(entry.$2) < timing.readAgainAfter,
          );
          if (recent.length > timing.unresolvedRounds) {
            broken.add('$read of $strategyId was read ${recent.length} times '
                'for the queue within ten minutes with nothing changed');
          }
        case ReadRecorded(:final strategyId, :final read, :final why, :final at)
            when why == 'landed work waits for a result':
          (_retired[(strategyId, read == 'the page list' ? 'list' : read)] ??=
                  [])
              .add((
            at: at,
            under: _underAt[server.readCalls.lastWhere(
              (call) => call.strategyId == strategyId && call.at == at,
            )],
          ));
        case ReadRecorded(:final strategyId, :final why, :final at)
            when why == 'edit access was lost':
          if (_lastAccess[strategyId] case final call?
              when call.role?.edits == false) {
            if (_lossAt[call] case final asked?) {
              _lastViewer[strategyId] = (at, asked);
            }
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
        final delay = Duration(seconds: random.nextInt(90));
        server.answerNext(strategy, (call) {
          final outcome = server.applyAll(call);
          Timer(delay, () => answer.complete(outcome));
          return answer.future;
        });
    }
  }

  void changeDuringWrite() {
    final hold = storage.holdNextWrite();
    world.sender.wake();
    world.settle(const Duration(milliseconds: 300));
    final choice = random.nextInt(3);
    if (choice == 2) {
      world.sender.hold('held while a write is held');
      log.add('hold while a write is held');
    } else if (choice == 0) {
      connection = nextConnection++;
      world.connection = connection;
      log.add('connection $connection while a write is held');
    } else {
      _signedInAs(account == servedAccount ? otherAccount : servedAccount);
      world.account = account;
      log.add('account ${account?.subject} while a write is held');
    }
    hold.letGo();
    async.flushMicrotasks();
  }

  void readFault() {
    final strategy = strategies[random.nextInt(2)];
    final choice = random.nextInt(8);
    log.add('read fault $strategy $choice');
    switch (choice) {
      case 0:
        server.answerReadNext(
          strategy,
          (_) => Future.microtask(() {
            refusedAt = signIns;
            return const StoreReadRefused(
              StoreReadRefusal.accountMismatch,
              'another account',
            );
          }),
        );
      case 1:
        server.answerReadNext(
          strategy,
          (_) => Future.microtask(() {
            refusedAt = signIns;
            return const StoreReadRefused(
              StoreReadRefusal.unauthenticated,
              'signed out',
            );
          }),
        );
      case 2:
        server.answerReadWith(
          strategy,
          const StoreReadRefused(StoreReadRefusal.forbidden, 'forbidden'),
        );
      case 3:
        server.answerReadWith(
          strategy,
          const StoreReadLost(TransportFailure.network, 'lost'),
        );
      case 4:
        server.answerReadWith(
          strategy,
          const StoreReadUnreadable('rows this build cannot read'),
        );
      case 7:
        server.answerReadNext(strategy, (call) {
          if (call.page == _second) world.teammateDeletesPage(_second);
          return Future.value(server.answerNow(call));
        });
      case 5:
        server.answerReadNext(strategy, (_) {
          final late = Completer<StoreReadOutcome>();
          Timer(
            const Duration(seconds: 60),
            () => late.complete(const StoreReadAnswered(StrategyGone())),
          );
          return late.future;
        });
      case _:
        final change = random.nextInt(3);
        server.answerReadNext(strategy, (call) async {
          switch (change) {
            case 0:
              connection = nextConnection++;
              world.connection = connection;
            case 1:
              _signedInAs(null);
              world.account = null;
              _signedInAs(servedAccount);
              world.account = servedAccount;
            case _:
              _signedInAs(
                account == servedAccount ? otherAccount : servedAccount,
              );
              world.account = account;
          }
          return const StoreReadAnswered(StrategyGone());
        });
    }
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
    final choice = random.nextInt(25);
    switch (choice) {
      case 0 || 1 || 2:
        edit();
        log.add('edit');
      case 3:
        world.sender.wake();
        log.add('wake');
      case 4:
        connection =
            connection == null || random.nextBool() ? nextConnection++ : null;
        world.connection = connection;
        log.add('connection $connection');
      case 5:
        final options = [servedAccount, otherAccount, null];
        _signedInAs(options[random.nextInt(3)]);
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
        teammate();
      case 13:
        changeDuringWrite();
      case 14:
        readFault();
      case 15 when random.nextBool():
        world.slowStore.afterRead = random.nextBool()
            ? Duration(milliseconds: random.nextInt(1500))
            : Duration.zero;
        log.add('reads take ${world.slowStore.afterRead}');
      case 15:
        world.slowStore.dropSessionReadBack = 1;
        log.add('one session read-back is lost');
      case 17:
        readFault();
      case 18:
        teammate();
      case 19 || 20:
        ownMove();
      case 21:
        ownPageOp();
      case 22:
        teammateOnRows();
      case 23:
        viewerRefusal();
      case 24 when random.nextBool():
        reopen();
      case 24:
        reopen();
      case _:
        final seconds =
            random.nextBool() ? random.nextInt(60) : 30 + random.nextInt(400);
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
      server.wrongAccountReads.map((call) => '${call.strategyId} $call'),
      isEmpty,
      reason: 'read as an account that does not own it\n$trail',
    );
    expect(
      [
        for (final strategy in strategies)
          if (standingOf(world.cloud(strategy).queue) ==
              Standing.deletedOnServer)
            strategy,
      ],
      isEmpty,
      reason: 'a read answered after the loop moved on was recorded: the '
          'store holds a strategy as deleted that the server never deleted\n'
          '$trail',
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
    _signedInAs(servedAccount);
    connection = nextConnection++;
    world
      ..account = account
      ..connection = connection;
    server.roles.clear();
    world.sender.release();
    final sender = world.sender;
    if (sender.signInWaitFrom == signIns || sender.upgradeAsked) restart();
  }

  void checkLiveness() {
    heal();
    world.settle(const Duration(minutes: 11));
    for (final strategy in strategies) {
      final cloud = world.cloud(strategy);
      final sendable = [
        for (final entry in cloud.queue.entries)
          if (cloud.views[entry.id]?.sendable ?? false) entry.id,
      ];
      expect(
        sendable,
        isEmpty,
        reason:
            'after eleven quiet minutes $strategy still holds work it could '
            'send: the loop slept on it; sender ${world.sender.view}\n$trail',
      );
    }
    for (var round = 0; round < 30; round++) {
      world.settle(const Duration(minutes: 1));
      if (_settledOrNeedsYou()) break;
    }
    for (final strategy in strategies) {
      final cloud = world.cloud(strategy);
      expect(
        _landedNotShown(strategy, cloud),
        isEmpty,
        reason: 'the loop\'s reads did not clear the landed work of '
            '$strategy\n$trail',
      );
      expect(
        [
          for (final entry in cloud.queue.entries)
            for (final hold in cloud.views[entry.id]?.holds ?? const <Hold>[])
              if (hold is AwaitingResult && !_needsUser(cloud, entry.id))
                '${entry.id} awaits ${hold.subject}',
        ],
        isEmpty,
        reason: 'a need the queue raised was never read; sender '
            '${world.sender.view}\n$trail',
      );
      expect(
        world.sender.cannotRead(strategy),
        isNull,
        reason: 'healed, $strategy is still held as unreadable\n$trail',
      );
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

  Outcome get outcome => (
        applied: server.appliedTimes.keys.toSet(),
        queued: {
          for (final strategy in strategies)
            for (final entry in world.cloud(strategy).queue.entries) entry.id,
        },
        landed: {
          for (final strategy in strategies)
            for (final work in world.cloud(strategy).queue.landed) work.op.opId,
        },
      );

  bool _settledOrNeedsYou() => strategies.every((strategy) {
        final cloud = world.cloud(strategy);
        return _landedNotShown(strategy, cloud).isEmpty &&
            world.sender.cannotRead(strategy) == null &&
            cloud.queue.entries.every(
              (entry) => _needsUser(cloud, entry.id),
            );
      });

  List<String> _landedNotShown(String strategy, CloudStrategy cloud) {
    final shown = world.sender.couldNotResolve(strategy, cloud)?.subjects ??
        const <String>[];
    return [
      for (final MapEntry(key: page, value: works)
          in Retiring.landedByPage(cloud).entries)
        if (!shown.contains(
          'landed work on '
          '${page == Retiring.list ? 'the page list' : 'page $page'}',
        ))
          for (final (attempt, position) in works)
            'attempt $attempt position $position on '
                '${page == Retiring.list ? 'the page list' : 'page $page'}',
    ];
  }

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

typedef Outcome = ({
  Set<(String, String)> applied,
  Set<String> queued,
  Set<String> landed,
});

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
        model.checkScheduled();
        model.checkRequests();
        if (i % 10 == 9) model.checkIsolation();
        if (i % 10 == 4) model.checkFairness();
        if (i % 35 == 7) model.checkRetireFloor();
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
            !kept.queued.containsAll(dropped.queued) ||
            kept.landed.length != dropped.landed.length ||
            !kept.landed.containsAll(dropped.landed)) {
          found.add('seed $seed ends differently: kept $kept, dropped '
              '$dropped');
        }
      }
      if (found.isNotEmpty) break;
    }
    expect(found, isEmpty);
  });
}
