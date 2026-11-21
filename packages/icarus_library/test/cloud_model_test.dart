import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

sealed class Recorded {
  const Recorded();
}

final class RecordedApplied extends Recorded {
  const RecordedApplied(this.revision);

  final int revision;
}

final class RecordedNoop extends Recorded {
  const RecordedNoop(this.revision);

  final int? revision;
}

final class RecordedRefusal extends Recorded {
  const RecordedRefusal(this.answer);

  final OpAnswer answer;
}

final class ServerModel {
  ServerModel(this.rows);

  StrategyRowSet rows;
  int version = 0;
  final landedAt = <String, int>{};
  final recorded = <String, Recorded>{};
  final firstSent = <String, String>{};

  int? revisionAt(Target target) => switch (target) {
    StrategyTarget() => rows.strategy.revision,
    PageTarget(:final pagePublicId) => switch (rows.page(pagePublicId)) {
      ReadablePageRow(:final revision) => revision,
      _ => null,
    },
    SettingsTarget(:final pagePublicId) => switch (rows.settingsOf(
      pagePublicId,
    )) {
      ReadablePageSettings(:final revision) => revision,
      _ => null,
    },
    ElementTarget(:final elementPublicId) => switch (rows.element(
      elementPublicId,
    )) {
      ReadableElementRow(:final revision) => revision,
      _ => null,
    },
    LineupTarget(:final lineupPublicId) => switch (rows.lineupGroup(
      lineupPublicId,
    )) {
      ReadableLineupGroupRow(:final revision) => revision,
      _ => null,
    },
  };

  List<OpAnswer> applyBatch(List<StrategyOp> ops) => [
    for (final op in ops) apply(op),
  ];

  OpAnswer apply(StrategyOp op) {
    final sent = canonical(op);
    final first = firstSent.putIfAbsent(op.opId, () => sent);
    if (first != sent) {
      throw StateError('${op.opId} was sent again with other content');
    }
    switch (recorded[op.opId]) {
      case RecordedApplied(:final revision):
        return NoopAnswer(
          op.opId,
          revision: revision,
          replay: NoopReplay.appliedWhenFirstReceived,
        );
      case RecordedNoop(revision: final revision?):
        return NoopAnswer(
          op.opId,
          revision: revision,
          replay: NoopReplay.notApplied,
        );
      case RecordedNoop(revision: null):
        return NoopWithoutRevision(op.opId);
      case RecordedRefusal(:final answer):
        return answer;
      case null:
        break;
    }
    final OpAnswer answer;
    final Recorded record;
    switch (applyOp(rows, op)) {
      case final OpApplied applied:
        rows = rows.withRows(applied.rows);
        version++;
        final revision = revisionAt(targetOf(op))!;
        answer = AppliedAnswer(op.opId, revision: revision);
        record = RecordedApplied(revision);
      case OpUnchanged():
        final revision = revisionAt(targetOf(op));
        answer = revision == null
            ? NoopWithoutRevision(op.opId)
            : NoopAnswer(
                op.opId,
                revision: revision,
                replay: NoopReplay.notApplied,
              );
        record = RecordedNoop(revision);
      case OpRefused(refusal: Rejected(:final reason)):
        answer = RejectedAnswer(op.opId, reason, const NoServerCopy());
        record = RecordedRefusal(answer);
      case OpRefused(refusal: Failed(:final code)):
        answer = FailedAnswer(op.opId, KnownFailure(code), code.wireName);
        record = RecordedRefusal(answer);
      case OpRefused(refusal: UnreadableTarget(:final key)):
        throw StateError('the model holds no unreadable row: $key');
    }
    recorded[op.opId] = record;
    if (record is RecordedApplied) landedAt[op.opId] = version;
    return answer;
  }
}

String canonical(StrategyOp op) => jsonEncode(op.toJson());

StrategyRowSet visible(StrategyRowSet base, CloudQueue queue) {
  var rows = base;
  for (final entry in queue.entries) {
    if (entry case PendingOp(:final op)) {
      if (applyOp(rows, op) case final OpApplied applied) {
        rows = rows.withRows(applied.rows);
      }
    }
  }
  return rows;
}

final reached = <String, int>{};

void count(String what) => reached[what] = (reached[what] ?? 0) + 1;

final class Model {
  Model(this.seed, {required this.teammates})
    : random = Random(seed),
      server = ServerModel(initialRows()),
      base = initialRows();

  static StrategyRowSet initialRows() => strategyRows(
    elements: [
      element('e1'),
      element('e2'),
      element('e3', pageId: 'page-b'),
    ],
  );

  final int seed;
  final bool teammates;
  final Random random;
  final ServerModel server;
  StrategyRowSet base;
  int baseVersion = 0;
  CloudQueue queue = CloudQueue.empty;
  DateTime clock = now;
  final inFlight = <List<StrategyOp>>[];
  final late = <OpAnswer>[];
  final log = <String>[];
  bool teammateEdited = false;
  bool droppedLandedWork = false;
  int nextId = 0;

  String fresh(String prefix) => '$prefix${nextId++}';

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];

  Step apply(QueueEvent event, String label) {
    final before = queue;
    final result = transition(queue, event, now: clock);
    log.add(
      '$label -> ${switch (result) {
        Stepped(:final effects) => effects.isEmpty ? 'ok' : effects.join(', '),
        NotApplicable(:final why) => 'not applicable: $why',
      }}',
    );
    if (result case Stepped(queue: final after, :final effects)) {
      checkRemovals(before, after, effects, event);
      count(event.runtimeType.toString());
      if (event case OpAnswered(
        answer: RejectedAnswer() || FailedAnswer(),
      ) when !teammates) {
        throw StateError('refused with no teammate editing: $event');
      }
      if (log.last.startsWith('late answer')) count('late answer applied');
      if (event case OpAnswered(:final answer)) {
        count(switch (answer) {
          NoopAnswer(:final replay) => 'noop ${replay.name}',
          RejectedAnswer(:final reason) => 'rejected ${reason.wireName}',
          _ => answer.runtimeType.toString(),
        });
      }
      for (final effect in effects) {
        count(switch (effect) {
          OpRemoved(:final cause) => 'removed ${cause.runtimeType}',
          _ => effect.runtimeType.toString(),
        });
      }
      queue = after;
    }
    checkStates();
    return result;
  }

  Stepped mustApply(QueueEvent event, String label) =>
      switch (apply(event, label)) {
        final Stepped done => done,
        NotApplicable(:final why) => throw StateError('$label: $why'),
      };

  void settle(QueueEvent event, String label, List<String> ids) {
    final waiting = [
      for (final id in ids)
        if (queue.entry(id) case PendingOp(
          state: Claimed() || Unsent(delivery: AnswerUnknown()),
        ))
          id,
    ];
    if (apply(event, label) is NotApplicable && waiting.isNotEmpty) {
      throw StateError('$label did not apply though $waiting wait for it');
    }
  }

  void checkRemovals(
    CloudQueue before,
    CloudQueue after,
    List<QueueEffect> effects,
    QueueEvent event,
  ) {
    final kept = {for (final entry in after.entries) entry.opId};
    final removed = {
      for (final effect in effects)
        if (effect case OpRemoved(:final opId, :final cause)) opId: cause,
    };
    for (final entry in before.entries) {
      if (kept.contains(entry.opId)) continue;
      final cause = removed[entry.opId];
      if (cause == null) {
        throw StateError('${entry.opId} disappeared with no removal');
      }
      final fits = switch (cause) {
        SeenInBase() =>
          entry is PendingOp &&
              baseVersion >= (server.landedAt[entry.opId] ?? 0) &&
              entry.state is Accepted &&
              switch (server.recorded[entry.opId]) {
                RecordedApplied() || RecordedNoop() => true,
                RecordedRefusal() || null => false,
              },
        NothingToWaitFor() =>
          event is OpAnswered && event.answer is NoopWithoutRevision,
        RemovedByUser(:final landing) =>
          event is UserAction &&
              event.opId == entry.opId &&
              landing == landingOf(entry),
        LandedBeforeStrategyDeleted() => false,
      };
      if (!fits) {
        throw StateError('${entry.opId} was removed for $cause after $event');
      }
      if (cause is RemovedByUser &&
          server.recorded[entry.opId] is RecordedApplied) {
        droppedLandedWork = true;
      }
    }
  }

  void checkStates() {
    final ids = <String>{};
    for (final entry in queue.entries) {
      if (!ids.add(entry.opId)) {
        throw StateError('${entry.opId} is in the queue twice');
      }
      if (entry is! PendingOp) continue;
      final record = server.recorded[entry.opId];
      final state = entry.state;
      final fits = switch ((record, state)) {
        (RecordedApplied() || RecordedNoop(), Unsent(delivery: NeverSent())) ||
        (RecordedApplied() || RecordedNoop(), ServerRefused()) => false,
        (RecordedRefusal(), Unsent(delivery: NeverSent())) ||
        (RecordedRefusal(), Accepted()) => false,
        (null, Accepted() || ServerRefused()) => false,
        _ => true,
      };
      if (!fits) {
        throw StateError(
          '${entry.opId} is $state but the server recorded $record',
        );
      }
    }
    final acceptedNotShown = [
      for (final entry in queue.entries)
        if (entry case PendingOp(state: Accepted())) entry.opId,
    ];
    final allAccepted = queue.entries.every(
      (entry) => entry is PendingOp && entry.state is Accepted,
    );
    if (!teammateEdited && !droppedLandedWork && allAccepted) {
      if (queue.entries.isNotEmpty) count('prediction checked');
      if (acceptedNotShown.isEmpty) return;
      final shown = visible(base, queue);
      if (shown != server.rows) {
        throw StateError(
          'with every op accepted, the user sees rows the server lacks',
        );
      }
    }
  }

  StrategyOp? edit() {
    final rows = visible(base, queue);
    final livePages = [
      for (final page in rows.pages)
        if (page is LivePage) page.publicId,
    ];
    final live = [
      for (final row in rows.elements)
        if (row case LiveElement(
          :final pagePublicId,
        ) when livePages.contains(pagePublicId))
          row,
    ];
    final opId = fresh('op');
    final choice = random.nextInt(10);
    final StrategyOp op;
    if (choice < 5 && live.isNotEmpty) {
      final target = pick(live);
      op = movePatch(
        opId,
        elementId: target.publicId,
        expected: target.revision,
        x: random.nextInt(1000).toDouble(),
      );
    } else if (choice < 7 && live.isNotEmpty) {
      final target = pick(live);
      op = ElementDeleteOp(
        opId: opId,
        elementPublicId: target.publicId,
        pagePublicId: target.pagePublicId,
        expectedElementRevision: target.revision,
      );
    } else if (choice < 9 && livePages.isNotEmpty) {
      op = elementAdd(opId, elementId: fresh('e'), pageId: pick(livePages));
    } else if (livePages.length < 5) {
      op = PageAddOp(
        opId: opId,
        pagePublicId: fresh('page-'),
        sortIndex: livePages.length,
        expectedStrategyRevision: rows.strategy.revision,
        name: 'Page',
      );
    } else {
      final target = rows.page(pick(livePages))! as LivePage;
      op = PagePatchOp(
        opId: opId,
        pagePublicId: target.publicId,
        expectedPageRevision: target.revision,
        name: 'Renamed ${random.nextInt(100)}',
      );
    }
    return switch (applyOp(rows, op)) {
      OpApplied() => op,
      OpUnchanged() || OpRefused() => null,
    };
  }

  List<String> ready() {
    final holds = holdsOf(queue, clock);
    for (final waiting in holds.values) {
      for (final hold in waiting) {
        count('held ${hold.runtimeType}');
      }
    }
    return [
      for (final entry in queue.entries)
        if (entry case PendingOp(
          state: Unsent(go: Free()),
        ) when !holds.containsKey(entry.opId))
          entry.opId,
    ];
  }

  List<StrategyOp> opsOf(List<String> ids) => [
    for (final id in ids) (queue.entry(id)! as PendingOp).op,
  ];

  void claim() {
    final ids = ready().take(1 + random.nextInt(4)).toList();
    if (ids.isEmpty) return;
    mustApply(BatchClaimed(ids), 'claim $ids');
    inFlight.add(opsOf(ids));
  }

  void deliver({required bool reliable}) {
    if (inFlight.isEmpty) return;
    final sent = inFlight.removeAt(random.nextInt(inFlight.length));
    final ids = [for (final op in sent) op.opId];
    final roll = reliable ? 0 : random.nextInt(10);
    if (roll == 9) {
      settle(
        TransportFailed(ids, TransportFailure.network, at: clock),
        'lost before the server $ids',
        ids,
      );
      return;
    }
    if (roll == 5) {
      final refusal = pick(const [
        BatchRefusal.upgradeRequired,
        BatchRefusal.unauthenticated,
        BatchRefusal.editAccessRemoved,
      ]);
      settle(BatchRefused(ids, refusal), 'refused whole: ${refusal.name}', ids);
      return;
    }
    final answers = server.applyBatch(sent);
    if (roll == 8) {
      settle(
        TransportFailed(ids, TransportFailure.timeout, at: clock),
        'answer timed out $ids',
        ids,
      );
      if (random.nextBool()) late.addAll(answers);
      return;
    }
    final order = [...answers];
    if (roll == 7) order.shuffle(random);
    for (final answer in order) {
      settle(OpAnswered(answer), 'answer for ${answer.opId}', [answer.opId]);
      if (roll == 6) {
        if (apply(OpAnswered(answer), 'duplicate ${answer.opId}') is Stepped) {
          throw StateError('a duplicate answer for ${answer.opId} applied');
        }
      }
    }
  }

  void lateAnswer() {
    if (late.isEmpty) return;
    final answer = late.removeAt(random.nextInt(late.length));
    apply(OpAnswered(answer), 'late answer for ${answer.opId}');
  }

  void restart() {
    late.clear();
    for (final sent in inFlight) {
      if (random.nextBool()) server.applyBatch(sent);
    }
    inFlight.clear();
    mustApply(const AppRestarted(), 'restart');
  }

  (StrategyRowSet, int)? lagging;

  void startRead() => lagging ??= (server.rows, server.version);

  void finishRead() {
    if (lagging case final snapshot?) {
      lagging = null;
      read(snapshot);
    }
  }

  void read([(StrategyRowSet, int)? snapshot]) {
    if (snapshot == null) {
      lagging = null;
      droppedLandedWork = false;
    }
    final (rows, version) = snapshot ?? (server.rows, server.version);
    base = rows;
    baseVersion = version;
    mustApply(
      BaseArrived(
        HeaderRead(
          strategy: base.strategy,
          pages: base.pages.toList(),
          settings: base.settings.toList(),
        ),
      ),
      'read strategy',
    );
    for (final page in base.pages) {
      mustApply(
        BaseArrived(
          PageRead(
            page: page,
            settings: base.settingsOf(page.publicId)!,
            elements: base.elementsOn(page.publicId).toList(),
            lineupGroups: base.lineupGroupsOn(page.publicId).toList(),
          ),
        ),
        'read ${page.publicId}',
      );
    }
  }

  void teammate() {
    final live = [
      for (final row in server.rows.elements)
        if (row is LiveElement) row,
    ];
    if (live.isEmpty) return;
    final target = pick(live);
    final op = movePatch(
      fresh('teammate'),
      elementId: target.publicId,
      expected: target.revision,
      x: -1,
    );
    if (applyOp(server.rows, op) case final OpApplied applied) {
      server.rows = server.rows.withRows(applied.rows);
      server.version++;
      teammateEdited = true;
      log.add('teammate moves ${target.publicId}');
    }
  }

  void resolve() {
    for (final entry in queue.entries) {
      switch (entry) {
        case PendingOp(state: ServerRefused(), :final op):
          final replacement = keepMine(op);
          final action = switch (random.nextInt(3)) {
            0 when replacement != null => UserKeptMine(entry.opId, replacement),
            1 => UserUsedCloud(entry.opId),
            _ => UserDiscarded(entry.opId),
          };
          mustApply(action, 'user ${action.runtimeType} ${entry.opId}');
          return;
        case PendingOp(state: Unsent(go: Paused())):
          mustApply(UserRetried(entry.opId), 'user retries ${entry.opId}');
          return;
        case PendingOp(state: Unsent(go: NeedsUser())):
          mustApply(UserDiscarded(entry.opId), 'user discards ${entry.opId}');
          return;
        case _:
          break;
      }
    }
  }

  StrategyOp? keepMine(StrategyOp op) => switch ((
    op,
    base.element(switch (targetOf(op)) {
      ElementTarget(:final elementPublicId) => elementPublicId,
      _ => '',
    }),
  )) {
    (
      ElementPatchOp(:final elementPublicId, :final payload?),
      LiveElement(:final revision),
    ) =>
      ElementPatchOp(
        opId: fresh('op'),
        elementPublicId: elementPublicId,
        expectedElementRevision: revision,
        payload: payload,
      ),
    _ => null,
  };

  void stepOnce() {
    clock = clock.add(Duration(milliseconds: random.nextInt(2000)));
    switch (random.nextInt(20)) {
      case < 6:
        if (edit() case final op?) {
          mustApply(
            UserEdited(PlainEdit(op), clientId: clientId),
            'edit ${op.opId} ${op.type.wireName}',
          );
        }
      case < 9:
        claim();
      case < 13:
        deliver(reliable: false);
      case 13:
        restart();
      case 14:
        read();
      case 15:
        if (random.nextBool()) {
          startRead();
        } else {
          finishRead();
        }
      case 16:
        if (teammates) teammate();
      case 17:
        if (random.nextBool()) {
          resolve();
        } else {
          lateAnswer();
        }
      case 18:
        mustApply(const ConnectionLost(), 'connection lost');
      case _:
        mustApply(const ConnectionReturned(), 'connection returned');
    }
  }

  void drain() {
    finishRead();
    for (var round = 0; round < 400 && queue.entries.isNotEmpty; round++) {
      clock = clock.add(const Duration(minutes: 1));
      resolve();
      claim();
      while (inFlight.isNotEmpty) {
        deliver(reliable: true);
      }
      read();
    }
    if (queue.entries.isNotEmpty) {
      throw StateError('the queue did not drain: ${queue.entries}');
    }
    if (visible(base, queue) != server.rows) {
      throw StateError('the drained queue shows other rows than the server');
    }
  }
}

void runSeed(int seed, int steps) {
  final model = Model(seed, teammates: seed.isOdd);
  try {
    for (var i = 0; i < steps; i++) {
      model.stepOnce();
    }
    model.drain();
  } on StateError catch (error) {
    fail(
      'seed $seed failed: ${error.message}\n'
      'rerun with CLOUD_MODEL_SEED=$seed CLOUD_MODEL_STEPS=$steps\n'
      'steps:\n${model.log.join('\n')}',
    );
  }
}

const minimums = {
  'AppliedAnswer': 2000,
  'noop appliedWhenFirstReceived': 100,
  'rejected revision_mismatch': 100,
  'TransportFailed': 300,
  'AppRestarted': 300,
  'UserKeptMine': 30,
  'UserUsedCloud': 30,
  'UserDiscarded': 30,
  'UserRetried': 50,
  'BatchRefused': 100,
  'OpRebased': 20,
  'removed SeenInBase': 2000,
  'held BehindEarlierEdit': 500,
  'held BehindPageAdd': 100,
  'held BehindStrategyChange': 50,
  'held UntilRetryTime': 30,
  'late answer applied': 30,
  'prediction checked': 200,
};

void main() {
  final environment = Platform.environment;
  final steps = int.tryParse(environment['CLOUD_MODEL_STEPS'] ?? '') ?? 150;
  final one = int.tryParse(environment['CLOUD_MODEL_SEED'] ?? '');
  final seeds = int.tryParse(environment['CLOUD_MODEL_SEEDS'] ?? '') ?? 200;
  test('random interleavings keep every op and end where the server is', () {
    if (one != null) {
      runSeed(one, steps);
      return;
    }
    for (var seed = 1; seed <= seeds; seed++) {
      runSeed(seed, steps);
    }
    if (environment['CLOUD_MODEL_COUNTS'] == '1') {
      for (final MapEntry(:key, :value) in reached.entries) {
        stdout.writeln('$key: $value');
      }
    }
    for (final MapEntry(key: what, value: least) in minimums.entries) {
      expect(reached[what] ?? 0, greaterThanOrEqualTo(least), reason: what);
    }
  });
}
