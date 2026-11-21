import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

sealed class Recorded {
  const Recorded();
}

final class RecordedAnswer extends Recorded {
  const RecordedAnswer(this.answer, {required this.applied});

  final OpAnswer answer;
  final bool applied;
}

Map<String, Object?> liveContent(StrategyRowSet rows) => {
  for (final row in rows.rows)
    if (switch (row) {
      DeletedElement() || DeletedLineupGroup() => false,
      _ => true,
    })
      '${row.key}': switch (row.toJson()) {
        final Map<String, Object?> json => {
          for (final MapEntry(:key, :value) in json.entries)
            if (key != 'revision' && key != 'updatedAt' && key != 'sortIndex')
              key: value,
        },
        final other => other,
      },
};

StrategyRowSet withoutPage(StrategyRowSet rows, String pageId) =>
    StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages.where((page) => page.publicId != pageId),
      settings: rows.settings.where((row) => row.pagePublicId != pageId),
      elements: rows.elements.where((row) => row.pagePublicId != pageId),
      lineupGroups: rows.lineupGroups.where(
        (row) => row.pagePublicId != pageId,
      ),
    );

final class Server {
  StrategyRowSet rows = initialRows();
  bool exists = true;
  final recorded = <String, Recorded>{};
  final firstClient = <String, String>{};
  int received = 0;
  int sends = 0;

  OpAnswer apply(String client, StrategyOp op) {
    sends++;
    final owner = firstClient.putIfAbsent(op.opId, () {
      received++;
      return client;
    });
    if (owner != client) {
      throw StateError('${op.opId} was sent under $owner and $client');
    }
    final key = '$client|${op.opId}';
    switch (recorded[key]) {
      case RecordedAnswer(answer: AppliedAnswer(:final revision)):
        return NoopAnswer(
          op.opId,
          revision: revision,
          replay: NoopReplay.appliedWhenFirstReceived,
        );
      case RecordedAnswer(:final answer):
        return answer;
      case null:
        break;
    }
    final OpAnswer answer;
    var applied = false;
    switch (applyOp(rows, op)) {
      case final OpApplied done:
        rows = rows.withRows(done.rows);
        applied = true;
        answer = AppliedAnswer(op.opId, revision: visibleRevision(rows, op)!);
      case OpUnchanged():
        final revision = visibleRevision(rows, op);
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
      case OpRefused(refusal: UnreadableTarget(:final key)):
        throw StateError('no unreadable rows here: $key');
    }
    recorded[key] = RecordedAnswer(answer, applied: applied);
    return answer;
  }

  bool landed(String opId) => switch (firstClient[opId]) {
    final client? => switch (recorded['$client|$opId']) {
      RecordedAnswer(:final applied) => applied,
      null => false,
    },
    null => false,
  };

  bool refused(String opId) => switch (firstClient[opId]) {
    final client? => switch (recorded['$client|$opId']) {
      RecordedAnswer(answer: RejectedAnswer() || FailedAnswer()) => true,
      _ => false,
    },
    null => false,
  };
}

final reached = <String, int>{};

void count(String what, [int by = 1]) =>
    reached[what] = (reached[what] ?? 0) + by;

final class Model {
  Model(this.seed, {required this.teammates, required this.folding})
    : random = Random(seed);

  final int seed;
  final bool teammates;
  final bool folding;
  final Random random;
  final server = Server();
  final client = Client();
  StrategyRowSet reference = initialRows();
  DateTime clock = now;
  String clientId = 'client-0';
  String build = 'build-0';
  int restarts = 0;
  String openPage = 'page-a';
  final inFlight = <(int, String, List<StrategyOp>)>[];
  final late = <(int, OpAnswer)>[];
  final inFlightLog = <String, String>{};
  final log = <String>[];
  bool teammateEdited = false;
  bool userRemoved = false;
  int drainHelps = 0;
  int nextId = 0;

  String fresh(String prefix) => '$prefix${nextId++}';

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];

  Step apply(QueueEvent event, String label) {
    client.clock = clock;
    final before = client.queue;
    var result = transition(before, event, now: clock);
    if (!folding) result = unfolded(before, event, result);
    log.add(
      '$label -> ${switch (result) {
        Stepped(:final effects) => effects.isEmpty ? 'ok' : effects.join(', '),
        NotApplicable(:final why) => 'not applicable: $why',
      }}',
    );
    if (result case Stepped(queue: final after, :final effects)) {
      checkRemovals(before, after, effects, event);
      client.queue = after;
      count(event.runtimeType.toString());
      for (final effect in effects) {
        if (effect case OpRemoved(:final cause)) {
          count('removed ${cause.runtimeType}');
        }
      }
      if (event case OpAnswered(
        answer: RejectedAnswer() || FailedAnswer(),
      ) when !teammates) {
        throw StateError(
          'refused with no teammate: ${switch (event.answer) {
            RejectedAnswer(:final opId, :final reason) => '$opId ${reason.wireName} sent ${inFlightLog[opId]}',
            FailedAnswer(:final opId, :final code) => '$opId $code',
            _ => '',
          }}',
        );
      }
    }
    checkStates();
    return result;
  }

  Step unfolded(CloudQueue before, QueueEvent event, Step result) {
    if ((event, result) case (UserEdited(:final edit), Stepped(:final effects))
        when effects.any(
          (effect) =>
              effect is OpRemoved &&
              (effect.cause is FoldedInto || effect.cause is CancelledBy),
        )) {
      return Stepped(
        CloudQueue(
          entries: [
            ...before.entries,
            PendingOp(
              place: before.entries.last.place + 1,
              work: OpWork(edit.op),
              scope: edit.scope,
              authored: edit.authored,
              policy: before.session.connected
                  ? SendPolicy.live
                  : SendPolicy.checked,
              answer: const NoAnswer(),
              retriedAfter: before.nextAttempt - 1,
            ),
          ],
          attempts: before.attempts,
          nextAttempt: before.nextAttempt,
          base: before.base,
          strategy: before.strategy,
          session: before.session,
        ),
        const [],
      );
    }
    return result;
  }

  Stepped must(QueueEvent event, String label) => switch (apply(event, label)) {
    final Stepped done => done,
    NotApplicable(:final why) => throw StateError('$label: $why'),
  };

  void checkRemovals(
    CloudQueue before,
    CloudQueue after,
    List<QueueEffect> effects,
    QueueEvent event,
  ) {
    final kept = {for (final entry in after.entries) entry.id};
    final removed = {
      for (final effect in effects)
        if (effect case OpRemoved(:final opId, :final cause)) opId: cause,
    };
    for (final entry in before.entries) {
      if (kept.contains(entry.id)) continue;
      final cause = removed[entry.id];
      if (cause == null) throw StateError('${entry.id} vanished');
      final fits = switch (cause) {
        SeenInBase() || SettledByRemoval() =>
          server.landed(entry.id) ||
              server.recorded.containsKey(
                '${server.firstClient[entry.id]}|${entry.id}',
              ),
        NothingToWaitFor() => event is OpAnswered,
        FoldedInto(:final opId) || CancelledBy(:final opId) =>
          event is UserEdited && event.edit.op.opId == opId,
        RetriedUnder() => event is PageRestored,
        RemovedByUser() => event is UserAction && event.opId == entry.id,
      };
      if (!fits) throw StateError('${entry.id} removed for $cause by $event');
      if (cause is RemovedByUser) userRemoved = true;
    }
  }

  void checkStates() {
    final views = entryViews(client.queue, clock);
    for (final entry in client.queue.entries) {
      if (entry is! PendingOp) continue;
      final state = views[entry.id]!.state;
      final bad = switch (state) {
        NeverSent() => server.landed(entry.id) || server.refused(entry.id),
        ServerRefused() => server.landed(entry.id),
        Accepted() => server.refused(entry.id),
        Claimed() || AnswerUnknown() => false,
      };
      if (bad) throw StateError('${entry.id} is $state against the server');
    }
    final sync = syncStateOf(
      Tally.of(client.queue, clock),
      network: Network.online,
      signedIn: SignedIn.thisAccount,
    );
    final quiet =
        client.queue.entries.isEmpty &&
        standingOf(client.queue) != Standing.deletedOnServer &&
        standingOf(client.queue) != Standing.editAccessLost;
    if ((sync is AllSaved) != quiet) {
      throw StateError('sync $sync with ${client.queue.entries}');
    }
  }

  StrategyOp? editOp() {
    final rows = client.visible;
    final copying = {
      for (final entry in client.queue.entries)
        if (entry case PendingOp(
          op: PageAddOp(:final pagePublicId, copyContentFromPagePublicId: _?),
        ))
          pagePublicId,
    };
    final pages = [
      for (final page in rows.pages)
        if (page is LivePage && !copying.contains(page.publicId)) page.publicId,
    ];
    final live = [
      for (final row in rows.elements)
        if (row case LiveElement(
          :final pagePublicId,
        ) when pages.contains(pagePublicId))
          row,
    ];
    final opId = fresh('op');
    final roll = random.nextInt(20);
    if (roll < 7 && live.isNotEmpty) {
      final target = pick(live);
      final payload = agentPayload(target.publicId, {
        ...target.payload.data.toJson(),
        'position': {'dx': random.nextInt(1000), 'dy': 0},
      });
      return ElementPatchOp(
        opId: opId,
        elementPublicId: target.publicId,
        expectedElementRevision: target.revision,
        payload: payload,
        sortIndex: target.sortIndex,
        merge: switch (random.nextInt(3)) {
          0 => FieldMerge(
            fields: ['position'],
            base: {'position': target.payload.data['position']},
          ),
          1 => FieldMerge(fields: ['position']),
          _ => null,
        },
      );
    }
    if (roll < 9 && live.isNotEmpty) {
      final target = pick(live);
      return ElementReorderOp(
        opId: opId,
        elementPublicId: target.publicId,
        pagePublicId: target.pagePublicId,
        sortIndex: random.nextInt(3),
        expectedElementRevision: target.revision,
      );
    }
    if (roll < 11 && live.isNotEmpty) {
      final target = pick(live);
      return elementDelete(
        opId,
        elementId: target.publicId,
        pageId: target.pagePublicId,
        expected: target.revision,
      );
    }
    if (roll < 14 && pages.isNotEmpty) {
      return elementAdd(opId, elementId: fresh('e'), pageId: pick(pages));
    }
    if (roll == 14 && pages.length < 5) {
      return pageAdd(
        opId,
        fresh('page-'),
        expected: rows.strategy.revision,
        copyFrom: random.nextBool() ? pick(pages) : null,
        sortIndex: pages.length,
      );
    }
    if (roll == 15 && pages.length > 1) {
      return PageReorderOp(
        opId: opId,
        pagePublicId: pick(pages),
        sortIndex: random.nextInt(pages.length),
        expectedStrategyRevision: rows.strategy.revision,
      );
    }
    if (roll == 16 && pages.isNotEmpty) {
      final page = rows.page(pick(pages))! as LivePage;
      return PagePatchOp(
        opId: opId,
        pagePublicId: page.publicId,
        expectedPageRevision: page.revision,
        name: 'Renamed ${random.nextInt(100)}',
      );
    }
    if (roll == 17 && pages.length > 2) {
      final page = pick(pages);
      if (client.queue.entries.whereType<PendingOp>().any(
        (entry) => entry.op is PageAddOp && pagesOf(entry).contains(page),
      )) {
        return null;
      }
      return pageDelete(opId, page, expected: rows.strategy.revision);
    }
    return null;
  }

  void edit() {
    final op = editOp();
    if (op == null) return;
    final visible = client.visible;
    final onTop = onVisible(visible, op);
    if (applyOp(visible, onTop) is! OpApplied) return;
    if (apply(
          client.editEvent(op),
          'edit ${op.opId} ${op.type.wireName} ${targetOf(op)}',
        )
        is Stepped) {
      if (applyOp(reference, onVisible(reference, op))
          case final OpApplied done) {
        reference = reference.withRows(done.rows);
      }
    }
  }

  void claim() {
    if (standingOf(client.queue) != Standing.good) return;
    final views = entryViews(client.queue, clock);
    String? owner;
    final ids = <String>[];
    for (final entry in client.queue.entries) {
      if (ids.length == 4) break;
      final view = views[entry.id];
      if (view == null || !view.sendable) continue;
      final mine = switch (view.state) {
        AnswerUnknown(:final clientId) => clientId,
        _ => owner ?? clientId,
      };
      if (owner != null && mine != owner) continue;
      owner = mine;
      ids.add(entry.id);
    }
    if (ids.isEmpty) return;
    final result = must(
      BatchClaimed(clientId: owner!, opIds: ids, at: clock),
      'claim $ids as $owner',
    );
    final sent = result.effects.whereType<SendBatch>().single;
    for (final op in sent.ops) {
      inFlightLog[op.opId] = '${op.toJson()}';
    }
    inFlight.add((sent.attempt, sent.clientId, sent.ops));
  }

  void deliver({required bool reliable}) {
    if (inFlight.isEmpty) return;
    final (attempt, owner, ops) = inFlight.removeAt(
      random.nextInt(inFlight.length),
    );
    final roll = reliable ? 0 : random.nextInt(12);
    if (!server.exists) {
      apply(
        BatchRefused(attempt, BatchRefusal.strategyDeleted),
        'refused: gone',
      );
      return;
    }
    if (roll == 11) {
      apply(
        TransportFailed(attempt, TransportFailure.network, at: clock),
        'lost $attempt',
      );
      return;
    }
    if (roll == 10) {
      final refusal = pick(const [
        BatchRefusal.upgradeRequired,
        BatchRefusal.unauthenticated,
        BatchRefusal.editAccessRemoved,
      ]);
      apply(BatchRefused(attempt, refusal), 'refused whole ${refusal.name}');
      return;
    }
    final answers = [for (final op in ops) server.apply(owner, op)];
    if (roll == 9) {
      apply(
        TransportFailed(attempt, TransportFailure.timeout, at: clock),
        'timed out $attempt',
      );
      if (random.nextBool()) {
        late.addAll([for (final answer in answers) (attempt, answer)]);
      }
      return;
    }
    final order = [...answers];
    if (roll == 8) order.shuffle(random);
    for (final answer in order) {
      apply(OpAnswered(attempt, answer), 'answer ${answer.opId}');
      if (roll == 7) apply(OpAnswered(attempt, answer), 'again ${answer.opId}');
    }
  }

  void restart() {
    for (final (_, owner, ops) in inFlight) {
      if (random.nextBool() && server.exists) {
        for (final op in ops) {
          server.apply(owner, op);
        }
      }
    }
    inFlight.clear();
    late.clear();
    clientId = 'client-${++restarts}';
    if (random.nextInt(3) == 0) build = 'build-$restarts';
    must(AppRestarted(build: build), 'restart as $clientId on $build');
  }

  void readHeader() {
    if (!server.exists) {
      must(const BaseArrived(StrategyGone()), 'read: gone');
      return;
    }
    final rows = server.rows;
    final kept = {for (final page in rows.pages) page.publicId};
    for (final page in client.base.pages) {
      if (!kept.contains(page.publicId)) {
        must(
          BaseArrived(PageGone(page.publicId)),
          'read ${page.publicId}: gone',
        );
      }
    }
    client.base = StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: client.base.elements.where(
        (r) => kept.contains(r.pagePublicId),
      ),
      lineupGroups: client.base.lineupGroups.where(
        (r) => kept.contains(r.pagePublicId),
      ),
    );
    must(
      BaseArrived(
        HeaderRead(
          strategy: rows.strategy,
          pages: rows.pages.toList(),
          settings: rows.settings.toList(),
        ),
      ),
      'read strategy',
    );
  }

  void readPage(String pageId) {
    if (!server.exists) return;
    final page = server.rows.page(pageId);
    if (page == null) {
      must(BaseArrived(PageGone(pageId)), 'read $pageId: gone');
      return;
    }
    if (client.base.page(pageId) != null) {
      client.base = StrategyRowSet(
        strategy: client.base.strategy,
        pages: client.base.pages,
        settings: client.base.settings,
        elements: [
          ...client.base.elements.where((row) => row.pagePublicId != pageId),
          ...server.rows.elementsOn(pageId),
        ],
        lineupGroups: [
          ...client.base.lineupGroups.where(
            (row) => row.pagePublicId != pageId,
          ),
          ...server.rows.lineupGroupsOn(pageId),
        ],
      );
    }
    must(
      BaseArrived(
        PageRead(
          page: page,
          settings: server.rows.settingsOf(pageId)!,
          elements: server.rows.elementsOn(pageId).toList(),
          lineupGroups: server.rows.lineupGroupsOn(pageId).toList(),
        ),
      ),
      'read $pageId',
    );
  }

  Set<String> pagesTheLaneReads() {
    final views = entryViews(client.queue, clock);
    return {
      openPage,
      for (final entry in client.queue.entries)
        if (entry is PendingOp &&
            (views[entry.id]!.state is Accepted ||
                views[entry.id]!.holds.any(
                  (hold) => hold is AwaitingPageRead || hold is AwaitingBase,
                )))
          ...pagesOf(entry),
    };
  }

  void lane() {
    switch (standingOf(client.queue)) {
      case Standing.editAccessLost:
        must(
          EditAccessConfirmed(afterAttempt: client.queue.nextAttempt - 1),
          'access confirmed',
        );
      case Standing.upgradeRequired:
        build = 'build-up-${restarts++}';
        must(AppRestarted(build: build), 'upgraded to $build');
      case Standing.good || Standing.deletedOnServer:
        break;
    }
    readHeader();
    for (final page in pagesTheLaneReads()) {
      readPage(page);
    }
  }

  void teammate() {
    if (!server.exists) return;
    final roll = random.nextInt(40);
    if (roll == 0) {
      final trashed = [
        for (final page in server.rows.pages)
          if (page is TrashedPage) page.publicId,
      ];
      if (trashed.isEmpty) return;
      server.rows = withoutPage(server.rows, pick(trashed));
    } else if (roll == 1 && random.nextInt(8) == 0) {
      server.exists = false;
    } else {
      final live = [
        for (final row in server.rows.elements)
          if (row is LiveElement) row,
      ];
      if (live.isEmpty) return;
      final target = pick(live);
      final op = movePatch(
        fresh('t'),
        elementId: target.publicId,
        expected: target.revision,
        rotation: 30,
      );
      if (applyOp(server.rows, op) case final OpApplied done) {
        server.rows = server.rows.withRows(done.rows);
      } else {
        return;
      }
    }
    teammateEdited = true;
    log.add('teammate acts');
  }

  void userActs({required bool draining}) {
    final views = entryViews(client.queue, clock);
    for (final entry in client.queue.entries) {
      final view = views[entry.id];
      final UserAction? action = switch ((entry, view)) {
        (
          PendingOp(),
          EntryView(state: AnswerUnknown(backoff: RetriesExhausted())),
        ) =>
          UserRetried(entry.id),
        (PendingOp(), EntryView(state: ServerRefused())) ||
        (PendingOp(), EntryView(go: NeedsUser())) =>
          random.nextBool() ? UserUsedCloud(entry.id) : UserDiscarded(entry.id),
        (RetiredOp() || UnreadableEntry(), _) => UserDiscarded(entry.id),
        _
            when standingOf(client.queue) == Standing.deletedOnServer &&
                view?.state is! Claimed &&
                view?.state is! Accepted =>
          UserDiscarded(entry.id),
        _ => null,
      };
      if (action == null) continue;
      if (draining) drainHelps++;
      if (!teammates && action is! UserRetried) {
        throw StateError(
          'the user was asked $action for ${entry.id}: '
          '${view?.state}, ${view?.go}, ${view?.holds}',
        );
      }
      if (apply(action, 'user ${action.runtimeType} ${entry.id}') is Stepped) {
        return;
      }
      if (action is UserUsedCloud) {
        apply(UserDiscarded(entry.id), 'user discards ${entry.id}');
        return;
      }
    }
  }

  void stepOnce() {
    clock = clock.add(Duration(milliseconds: random.nextInt(2000)));
    switch (random.nextInt(22)) {
      case < 7:
        edit();
      case < 10:
        claim();
      case < 14:
        deliver(reliable: false);
      case 14:
        restart();
      case 15:
        lane();
      case 16:
        if (teammates) teammate();
      case 17:
        userActs(draining: false);
      case 18:
        if (late.isNotEmpty) {
          final (attempt, answer) = late.removeAt(random.nextInt(late.length));
          apply(OpAnswered(attempt, answer), 'late ${answer.opId}');
        }
      case 19:
        final pages = [for (final page in client.base.pages) page.publicId];
        if (pages.isNotEmpty) openPage = pick(pages);
      case _:
        must(
          random.nextBool()
              ? const ConnectionLost()
              : const ConnectionReturned(),
          'connection',
        );
    }
  }

  void drain() {
    for (
      var round = 0;
      round < 300 && client.queue.entries.isNotEmpty;
      round++
    ) {
      clock = clock.add(const Duration(minutes: 1));
      lane();
      userActs(draining: true);
      claim();
      while (inFlight.isNotEmpty) {
        deliver(reliable: true);
      }
    }
    if (client.queue.entries.isNotEmpty) {
      throw StateError('did not drain: ${client.queue.entries}');
    }
    if (!teammates && drainHelps > 0) {
      throw StateError('the drain helped the user $drainHelps times');
    }
    if (!teammateEdited && !userRemoved && server.exists) {
      final want = liveContent(reference);
      final got = liveContent(server.rows);
      if (!const DeepCollectionEquality().equals(want, got)) {
        final keys = {...want.keys, ...got.keys}.where(
          (key) => !const DeepCollectionEquality().equals(want[key], got[key]),
        );
        throw StateError(
          'the server does not hold the user\'s edits: '
          '${[for (final key in keys) '$key: ${want[key]} vs ${got[key]}'].join('; ')}',
        );
      }
    }
  }
}

void runSeed(int seed, int steps, {required bool folding}) {
  final model = Model(seed, teammates: seed.isOdd, folding: folding);
  try {
    for (var i = 0; i < steps; i++) {
      model.stepOnce();
    }
    model.drain();
    count(
      folding ? 'ops received, folding' : 'ops received, no folding',
      model.server.received,
    );
  } on StateError catch (error) {
    fail(
      'seed $seed (folding: $folding) failed: ${error.message}\n'
      'rerun with CLOUD_MODEL_SEED=$seed CLOUD_MODEL_STEPS=$steps\n'
      'steps:\n${model.log.join('\n')}',
    );
  }
}

const minimums = {
  'OpAnswered': 2000,
  'TransportFailed': 200,
  'AppRestarted': 200,
  'BatchRefused': 50,
  'UserUsedCloud': 5,
  'UserDiscarded': 5,
  'removed SeenInBase': 1500,
  'removed FoldedInto': 100,
};

void main() {
  final environment = Platform.environment;
  final steps = int.tryParse(environment['CLOUD_MODEL_STEPS'] ?? '') ?? 150;
  final one = int.tryParse(environment['CLOUD_MODEL_SEED'] ?? '');
  final seeds = int.tryParse(environment['CLOUD_MODEL_SEEDS'] ?? '') ?? 200;
  test('random interleavings keep every edit and end where the user meant', () {
    final picked = one == null ? [for (var s = 1; s <= seeds; s++) s] : [one];
    for (final seed in picked) {
      runSeed(seed, steps, folding: true);
      runSeed(seed, steps, folding: false);
    }
    if (environment['CLOUD_MODEL_COUNTS'] == '1') {
      for (final MapEntry(:key, :value) in reached.entries) {
        stdout.writeln('$key: $value');
      }
    }
    if (one != null) return;
    for (final MapEntry(key: what, value: least) in minimums.entries) {
      expect(reached[what] ?? 0, greaterThanOrEqualTo(least), reason: what);
    }
  });
}
