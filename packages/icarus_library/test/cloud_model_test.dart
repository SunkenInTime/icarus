import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/op_facts.dart';
import 'package:icarus_library/stamp_source.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';
import 'support.dart';

final reached = <String, int>{};

String? subjectOf(ArrivedBase base) => switch (base) {
  HeaderRead() || StrategyGone() => null,
  PageRead(:final page) => page.publicId,
  PageGone(:final pagePublicId) => pagePublicId,
};

ResultPoint? pointOf(QueueEvent event) => switch (event) {
  BaseArrived(:final point) ||
  ResultRefused(:final point) ||
  OpAnswered(:final point) ||
  BatchRefused(:final point) ||
  ServerTimeHeld(:final point) ||
  EditAccessConfirmed(:final point) ||
  ReadRefusedForUpgrade(:final point) ||
  ReadRefusedForSignIn(:final point) ||
  BatchAccountMismatch(:final point) => point,
  _ => null,
};

int? labelOf(QueueEvent event) => switch (event) {
  BaseArrived(:final session) ||
  ResultRefused(:final session) ||
  ServerTimeHeld(:final session) ||
  EditAccessConfirmed(:final session) ||
  ReadRefusedForUpgrade(:final session) ||
  ReadRefusedForSignIn(:final session) => session,
  _ => null,
};

void count(String what, [int by = 1]) =>
    reached[what] = (reached[what] ?? 0) + by;

final class Model {
  Model(this.seed, {required this.teammates, required this.folding})
    : random = Random(seed),
      replacing = Random(seed * 7919 + 1),
      lateness = Random(seed * 104729 + 3),
      making = Random(seed * 15485863 + 5) {
    skew = Duration(milliseconds: random.nextInt(180001) - 90000);
  }

  final int seed;
  final bool teammates;
  final bool folding;
  final Random random;
  final Random replacing;
  final Random lateness;
  final Random making;
  final readsInFlight = <(QueueEvent, String)>[];
  late final StampSource stamps;
  Generation? heldGeneration;
  int sessionNumber = 0;
  int labelsFrom = 0;
  bool lastAdmitted = false;
  int probes = 0;
  final mirrorTaken = <String?, ResultOrder>{};
  final mirrorRefused = <String?, ResultOrder>{};
  ResultOrder? mirrorFence;
  final delivered = <String?, Set<ResultOrder>>{};
  final gone = Object();

  void begin() {
    stamps = StampSource(
      Random(seed * 524287 + 11),
      from: const ResultPoint(client: 1, connection: 1, snapshot: 0),
      now: () => serverNow * 1000000,
    );
    client.queue = CloudQueue.start(build: client.queue.session.build);
    sessionNumber = client.queue.session.number;
    labelsFrom = client.queue.session.labelsFrom;
    heldGeneration = client.queue.session.generation;
    arrive(headerReadOf(server.rows), 'first read strategy', reliable: true);
    for (final page in server.rows.pages) {
      arrive(
        pageReadOf(server.rows, page.publicId),
        'first read ${page.publicId}',
        reliable: true,
      );
    }
  }

  final statesAt = <(int, int), Object>{};

  Object get serverState => server.exists ? server.rows : gone;

  ResultPoint stampOfState() {
    final state = serverState;
    while (true) {
      final point = stamps.at(state);
      final at = (point.client, point.snapshot);
      if (statesAt[at] case final held? when !identical(held, state)) {
        count('stamps drawn again so one snapshot holds one server state');
        continue;
      }
      statesAt[at] = state;
      return point;
    }
  }

  void openSession({required bool sameLabels}) {
    sessionNumber++;
    if (!sameLabels) labelsFrom = sessionNumber;
    mirrorTaken.clear();
    mirrorRefused.clear();
    mirrorFence = null;
  }

  bool labels(int label) =>
      label != 0 && label >= labelsFrom && label <= sessionNumber;

  void track(QueueEvent event) {
    lastAdmitted = false;
    switch (event) {
      case AppRestarted():
        heldGeneration = null;
        openSession(sameLabels: false);
        stamps.restart();
        statesAt.clear();
        readsInFlight.clear();
        return;
      case AccountChanged():
        heldGeneration = null;
        openSession(sameLabels: false);
        return;
      case ConnectionReturned(:final generation):
        final held = heldGeneration;
        if (generation.client < 1) return;
        if (held != null && (held == generation || generation.isBefore(held))) {
          return;
        }
        heldGeneration = generation;
        openSession(sameLabels: held != null);
        return;
      case _:
        break;
    }
    final point = pointOf(event);
    if (point == null) return;
    if (labelOf(event) case final label? when !labels(label)) {
      count('stamped events from a session the queue no longer labels');
      return;
    }
    final generation = point.generation;
    if (generation.client < 1) return;
    switch (heldGeneration) {
      case null:
        heldGeneration = generation;
      case final held when generation.isBefore(held):
        return;
      case final held when held.isBefore(generation):
        heldGeneration = generation;
        openSession(sameLabels: true);
        count('sessions opened by a stamp from a later connection');
      case _:
        break;
    }
    lastAdmitted = true;
  }

  final server = Server();
  final client = Client();
  StrategyRowSet reference = initialRows();
  DateTime clock = now;
  String clientId = 'client-0';
  String build = 'build-0';
  int restarts = 0;
  String openPage = 'page-a';
  final inFlight = <(int, String, List<StrategyOp>, int?, int)>[];
  final held = <(String, List<StrategyOp>, int?)>[];
  Duration elapsed = Duration.zero;
  late Duration skew;
  final writtenAt = <String, int>{};
  final teammateWrote = <(Target, String), int>{};
  final refusedLate = <String>{};
  final livesSent = <String, int>{};
  final refusedOps = <String>{};
  final heldAtCommit = <String>{};
  StrategyRowSet? lastDrawn;
  final strategyLifeSent = <String, int>{};
  final setAsideIds = <String>{};
  final refusedStrategyLives = <int>{};
  bool adoptedReplacement = false;

  bool namesAnotherStrategyLife(List<StrategyOp> ops) => ops.any(
    (op) => switch (strategyLifeSent[op.opId]) {
      final life? => life != createdAtOf(server.rows.strategy),
      null => false,
    },
  );

  int get serverNow => clock.millisecondsSinceEpoch + skew.inMilliseconds;

  void pass(Duration time) {
    clock = clock.add(time);
    elapsed += time;
  }

  List<OpAnswer>? receive(String owner, List<StrategyOp> ops, int? basis) {
    if (namesAnotherStrategyLife(ops)) {
      count('batches naming a replaced strategy life applied nothing');
      return [];
    }
    final at = serverNow;
    final unchecked = [
      for (final op in ops)
        if (uncheckedOnTheWire(op)) op,
    ];
    if (basis == null && unchecked.isNotEmpty) {
      throw StateError(
        'unchecked ${unchecked.map((op) => op.opId)} went out with no basis',
      );
    }
    if (basis != null && (basis > at || at - basis > 30000)) {
      count('batches refused outside the window');
      return null;
    }
    if (basis != null && at - basis > liveFor.inMilliseconds) {
      count('batches accepted 20 to 30 s after their basis');
    }
    final answers = <OpAnswer>[];
    for (final op in ops) {
      final answer = applyOwn(owner, op);
      answers.add(answer);
      if (!uncheckedOnTheWire(op) || answer is! AppliedAnswer) continue;
      count('unchecked ops applied');
      final late = at - writtenAt[op.opId]!;
      if (late > 30000) {
        throw StateError(
          'unchecked ${op.opId} applied ${late / 1000} s after it was written',
        );
      }
      final target = checkTargetOf(op);
      final fields = switch (op.toJson()) {
        {'merge': {'fields': final List<Object?> named}} => [
          ...named.map((f) => '$f'),
        ],
        _ => null,
      };
      final overwrote = teammateWrote.entries.any(
        (wrote) =>
            wrote.key.$1 == target &&
            wrote.value > writtenAt[op.opId]! &&
            (fields == null ||
                wrote.key.$2 == '*' ||
                fields.contains(wrote.key.$2)),
      );
      if (overwrote) {
        count(
          'unchecked ops applied over a teammate\'s newer write to their '
          'fields, in window',
        );
      }
    }
    return answers;
  }

  final late = <(int, OpAnswer, ResultPoint)>[];
  final inFlightLog = <String, String>{};
  final log = <String>[];
  bool teammateEdited = false;
  bool userRemoved = false;
  bool jumped = false;
  final seen = <Target, Set<int>>{};
  final produced = <Target, Set<int>>{};

  final seenDigest = <String, String>{};
  final history = <(Target, int?, int), String>{};

  void recordHistory() {
    for (final MapEntry(key: target, value: revision) in revisionsOf(
      server.rows,
    ).entries) {
      final row = rowOf(server.rows, target);
      if (row == null) continue;
      history[(target, createdAtOf(row), revision)] = target is StrategyTarget
          ? strategyDigest(server.rows.strategy, server.rows.pages)
          : rowDigest(row);
    }
  }

  void checkNothingTakenGoesBack(
    CloudQueue before,
    CloudQueue after,
    String label,
  ) {
    if (after.session.number != before.session.number ||
        after.shown.fence != before.shown.fence) {
      return;
    }
    for (final subject in {
      null,
      ...before.shown.pages.keys,
      ...before.shown.pagesTaken.keys,
    }) {
      final held = before.shown.contentTakenOf(subject);
      if (held == null) continue;
      final now = after.shown.contentTakenOf(subject);
      if (now == null || now.isBefore(held)) {
        throw StateError(
          '$label moved ${subject ?? 'the page list'} back from content '
          'taken at $held to ${now ?? 'no taken content'}',
        );
      }
      count('taken content checked not to go back');
      if (subject != null && !before.shown.pages.containsKey(subject)) {
        count('taken content of a page not shown checked not to go back');
      }
    }
  }

  void checkJustified() {
    for (final work in client.queue.landed) {
      final produced = work.produced;
      if (produced == null) continue;
      final target = targetOf(work.op);
      final held = [
        for (final MapEntry(key: (row, life, revision), :value)
            in history.entries)
          if (row == target &&
              revision == produced.revision &&
              (produced.life == null || life == produced.life))
            value,
      ];
      final truth = held.contains(produced.digest)
          ? produced.digest
          : held.firstOrNull;
      if (truth == null) {
        throw StateError(
          '${work.op.opId} justified $target at ${produced.revision}, a '
          'revision the server never held',
        );
      }
      if (truth != produced.digest) {
        throw StateError(
          '${work.op.opId} justified $target at ${produced.revision} with '
          'content the server did not hold then',
        );
      }
      count('justified rows checked against the server');
    }
  }

  OpAnswer applyOwn(String owner, StrategyOp op) {
    recordHistory();
    final before = revisionsOf(server.rows);
    final beforeRow = rowOf(server.rows, checkTargetOf(op));
    final replaying = server.recorded['$owner|${op.opId}'];
    final answer = server.apply(owner, op, expectedLife: livesSent[op.opId]);
    if (replaying case RecordedAnswer(
      answer: FailedAnswer(code: KnownFailure(code: FailureCode.pageDeleted)),
    )) {
      count('refusals as page deleted replayed after a lost answer');
    }
    if (answer case RejectedAnswer(reason: RejectionReason.rowReplaced)) {
      count('ops refused as naming a row life that was replaced');
    }
    if (answer case FailedAnswer(
      code: KnownFailure(code: FailureCode.pageDeleted),
    )) {
      count('own changes refused as their page deleted');
    }
    if (answer case AppliedAnswer()) {
      final target = checkTargetOf(op);
      final named = expectedOf(op);
      final asSeen =
          beforeRow != null &&
          seenDigest[op.opId] != null &&
          rowDigest(beforeRow) == seenDigest[op.opId];
      if (named != null &&
          !asSeen &&
          !(seen[target]?.contains(named) ?? false) &&
          !(produced[target]?.contains(named) ?? false)) {
        throw StateError(
          '${op.opId} landed on revision $named of $target, which the user '
          'never saw and no answer of this device produced',
        );
      }
      count('checked revisions verified');
      for (final MapEntry(:key, :value) in revisionsOf(server.rows).entries) {
        if (before[key] != value) (produced[key] ??= {}).add(value);
      }
    }
    recordHistory();
    return answer;
  }

  int drainHelps = 0;
  int nextId = 0;

  String fresh(String prefix) => '$prefix${nextId++}';

  String freshElementId() {
    final starting = {for (final row in initialRows().elements) row.publicId};
    var id = fresh('e');
    while (starting.contains(id)) {
      id = fresh('e');
    }
    return id;
  }

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];

  Step apply(QueueEvent event, String label) {
    client.clock = clock;
    if (event case UserEdited(edit: Edit(:final op))) {
      writtenAt[op.opId] = serverNow;
    }
    final before = client.queue;
    final sessionsBefore = sessionNumber;
    track(event);
    var result = transition(before, event, now: clock);
    if (!folding) result = unfolded(before, event, result);
    final session = result.queue.session;
    final opened = session.number - before.session.number;
    if (opened != sessionNumber - sessionsBefore) {
      throw StateError(
        '$label opened $opened sessions in the queue where the model\'s '
        'admission opens ${sessionNumber - sessionsBefore}',
      );
    }
    if (session.labelsFrom != labelsFrom) {
      throw StateError(
        '$label left the queue labelling sessions from ${session.labelsFrom}, '
        'the model from $labelsFrom',
      );
    }
    if (session.generation != heldGeneration) {
      throw StateError(
        '$label left the queue holding ${session.generation}, the model '
        '$heldGeneration',
      );
    }
    if (opened > 0) count('sessions opened, checked against the model');
    checkNothingTakenGoesBack(before, result.queue, label);
    if (result case NotApplicable(:final queue)) client.queue = queue;
    log.add(
      '$label -> ${switch (result) {
        Stepped(:final effects) => effects.isEmpty ? 'ok' : effects.join(', '),
        NotApplicable(:final why) => 'not applicable: $why',
      }}',
    );
    if (result case Stepped(queue: final after, :final effects)) {
      if ((before.shown.strategy?.life, after.shown.strategy?.life) case (
        final was?,
        final now?,
      ) when now > was) {
        reference = server.rows;
        adoptedReplacement = true;
      }
      checkRemovals(before, after, effects, event);
      client.queue = after;
      for (final entry in after.entries) {
        if (entry case PendingOp(
          refusal: RefusedWith(refusal: RejectedByServer()),
        )) {
          refusedOps.add(entry.id);
        }
      }
      if (after.strategy.setAside case SetAside(:final entries)) {
        setAsideIds.addAll([for (final entry in entries) entry.id]);
      }
      count(event.runtimeType.toString());
      if (event case OpAnswered(
        answer: NoopAnswer(replay: NoopReplay.notApplied),
      )) {
        count('nothing to do at another revision');
      }
      for (final effect in effects) {
        if (effect is StrategySetAside) {
          count('StrategySetAside');
        }
        if (effect case OpRemoved(:final opId, :final cause)) {
          count('removed ${cause.runtimeType}');
          if (cause case FoldedInto(opId: final into)) {
            for (final entry in before.entries) {
              if (entry case PendingOp(:final op) when entry.id == opId) {
                count('folded ${op.type.wireName}');
              }
            }
            final earlier = writtenAt[opId];
            if (earlier != null && earlier < (writtenAt[into] ?? earlier + 1)) {
              writtenAt[into] = earlier;
            }
          }
        }
      }
      if (event case OpAnswered(
        answer: RejectedAnswer() || FailedAnswer(),
      ) when !teammates && !userRemoved) {
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
    checkJustified();
    checkNothingStalls();
    if (event is! BaseArrived && event is! ResultRefused) checkTaken();
    return result;
  }

  List<ArrivedBase> resultsFor(ResultSubject subject) {
    final rows = server.rows;
    ArrivedBase pageResult(String page) =>
        rows.page(page) == null ? PageGone(page) : pageReadOf(rows, page);
    return switch (subject) {
      PageListResult() => [headerReadOf(rows)],
      PageResult(:final page) => [pageResult(page)],
      RowResult(target: StrategyTarget() || PageTarget() || SettingsTarget()) =>
        [headerReadOf(rows)],
      RowResult(:final page?) => [pageResult(page)],
      RowResult() => [headerReadOf(rows)],
    };
  }

  void checkNothingStalls() {
    if (!server.exists) return;
    final queue = client.queue;
    List<AwaitingResult> awaitedIn(EntryView? view) =>
        [
          for (final hold in view?.holds ?? const <Hold>[])
            if (hold is AwaitingResult) hold,
        ]..sort(
          (a, b) => (a.subject is PageListResult ? 0 : 1).compareTo(
            b.subject is PageListResult ? 0 : 1,
          ),
        );
    for (final MapEntry(key: id, value: view) in entryViews(
      queue,
      clock,
    ).entries) {
      if (view.state is! Waiting) continue;
      final first = awaitedIn(view);
      if (first.isEmpty) continue;
      var read = queue;
      var awaited = first;
      for (var round = 0; round < 3 && awaited.isNotEmpty; round++) {
        for (final hold in awaited) {
          for (final base in resultsFor(hold.subject)) {
            if (transition(
                  read,
                  BaseArrived(
                    base,
                    session: read.session.number,
                    point: stamps.probe(++probes),
                  ),
                  now: clock,
                )
                case Stepped(:final queue)) {
              read = queue;
            }
          }
        }
        awaited = awaitedIn(entryViews(read, clock)[id]);
      }
      if (awaited.isNotEmpty) {
        final purgedPutBack = switch (queue.entry(id)) {
          PendingOp(
            op: ElementAddOp(
              :final elementPublicId,
              expectedElementRevision: _?,
            ),
          ) =>
            server.rows.element(elementPublicId) == null,
          _ => false,
        };
        final windowLater = entryViews(read, clock.add(resendWindow))[id];
        if (!purgedPutBack ||
            (windowLater?.state is Waiting &&
                awaitedIn(windowLater).isNotEmpty)) {
          throw StateError(
            '$id waits for ${[for (final hold in first) hold.subject]}, and '
            'neither three rounds of reading what it asks for nor the resend '
            'window ending leave it free of '
            '${[for (final hold in awaited) hold.subject]}',
          );
        }
        count('put-backs of a purged row that wait out their resend window');
        continue;
      }
      count('waits for a result that a read would settle', first.length);
    }
  }

  Step unfolded(CloudQueue before, QueueEvent event, Step result) {
    if ((event, result)
        case (UserEdited(:final edit, :final madeAs), Stepped(:final effects))
        when effects.any(
          (effect) => effect is OpRemoved && effect.cause is FoldedInto,
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
              authoredIn: before.session.number,
              authoredAt: clock,
              refusal: const NotRefused(),
              retriedAfter: before.nextAttempt - 1,
              basis: before.session.basis,
              strategyLife: before.shown.strategy?.life,
              madeAs: madeAs,
            ),
          ],
          attempts: before.attempts,
          landed: before.landed,
          nextAttempt: before.nextAttempt,
          nextSession: before.nextSession,
          shown: before.shown,
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
    final kept = {
      for (final entry in after.entries) entry.id,
      if (after.strategy.setAside case SetAside(:final entries))
        if (event is BaseArrived && event.base is HeaderRead)
          for (final entry in entries) entry.id,
    };
    final removed = {
      for (final effect in effects)
        if (effect case OpRemoved(:final opId, :final cause)) opId: cause,
    };
    for (final entry in before.entries) {
      if (kept.contains(entry.id)) continue;
      final cause = removed[entry.id];
      if (cause == null) throw StateError('${entry.id} vanished');
      final fits = switch (cause) {
        Delivered(how: Delivery.applied) =>
          event is OpAnswered && server.landed(entry.id),
        Delivered() => event is OpAnswered,
        FoldedInto(:final opId) =>
          event is UserEdited && event.edit.op.opId == opId,
        LetGoWithItsPage(:final deleteOpId) =>
          event is OpAnswered &&
              event.answer.opId == deleteOpId &&
              switch ((before.entry(deleteOpId), entry)) {
                (
                  PendingOp(
                    op: PageDeleteOp(:final pagePublicId),
                    place: final at,
                  ),
                  final PendingOp gone,
                ) =>
                  gone.place < at &&
                      pagesJudgedOn(
                        before.shown,
                        gone,
                      ).contains(pagePublicId) &&
                      switch (entryViews(before, clock)[gone.id]?.state) {
                        Sending() || Unanswered() => false,
                        _ => true,
                      },
                _ => false,
              },
        SentAgainAs() =>
          event is BaseArrived &&
              event.base is HeaderRead &&
              entry is PendingOp &&
              refusedAsPageDeleted(entry),
        RemovedByUser() =>
          event is UserAction &&
              (event.opId == entry.id ||
                  switch ((before.entry(event.opId), entry)) {
                    (final PendingOp acted, final PendingOp later) =>
                      entityOf(acted.op) == entityOf(later.op) &&
                          acted.place < later.place,
                    _ => false,
                  }),
      };
      if (!fits) throw StateError('${entry.id} removed for $cause by $event');
      if (cause is LetGoWithItsPage) count('ops let go with their page');
      if (cause is SentAgainAs) count('ops sent again after the trash');
      if (cause is RemovedByUser) userRemoved = true;
      if (cause is RemovedByUser &&
          event is UserAction &&
          event.opId != entry.id) {
        count('given up with its chain');
      }
    }
  }

  final heldForTrash = <String>{};
  final wentToUser = <String>{};

  void countHolds(Map<String, EntryView> views) {
    for (final MapEntry(key: id, value: view) in views.entries) {
      final inTrash = view.holds.any((hold) => hold is PageInTrash);
      if (inTrash && heldForTrash.add(id)) count('ops held for the trash');
      if (!inTrash && heldForTrash.remove(id)) {
        count(
          view.state == const NeedsUser(RowPageGone())
              ? 'held ops whose page was purged'
              : 'held ops lifted',
        );
      }
      if (view.state case NeedsUser(
        reason: RefusedByServer(
          refusal: FailedOnServer(
            code: KnownFailure(code: FailureCode.pageDeleted),
          ),
        ),
      ) when wentToUser.add(id)) {
        count('refused as deleted again, to the user');
      }
    }
    heldForTrash.removeWhere((id) => !views.containsKey(id));
  }

  void checkStates() {
    final views = entryViews(client.queue, clock);
    countHolds(views);
    final queue = client.queue;
    final rebuilt = CloudQueue(
      entries: queue.entries,
      attempts: queue.attempts,
      landed: queue.landed,
      nextAttempt: queue.nextAttempt,
      nextSession: queue.nextSession,
      shown: queue.shown,
      strategy: queue.strategy,
      session: queue.session,
    );
    if (!const MapEquality<String, EntryView>().equals(
          views,
          entryViews(rebuilt, clock),
        ) ||
        Tally.of(queue, clock) != Tally.of(rebuilt, clock)) {
      throw StateError(
        'the carried views differ from views derived afresh:\n'
        '${views.entries.where((e) => entryViews(rebuilt, clock)[e.key] != e.value).map((e) => '${e.key}: ${e.value.state} ${e.value.sendable} ${e.value.holds} vs ${entryViews(rebuilt, clock)[e.key]?.state} ${entryViews(rebuilt, clock)[e.key]?.sendable} ${entryViews(rebuilt, clock)[e.key]?.holds}').join('\n')}\n'
        '${Tally.of(queue, clock).toJson()} vs ${Tally.of(rebuilt, clock).toJson()}',
      );
    }
    for (final entry in client.queue.entries) {
      if (entry is! PendingOp) continue;
      final state = views[entry.id]!.state;
      final bad = switch (state) {
        Waiting() =>
          server.landed(entry.id) ||
              (server.refused(entry.id) && !refusedAsPageDeleted(entry)),
        NeedsUser(
          reason: RefusedByServer(
            refusal: RejectedByServer() || FailedOnServer(),
          ),
        ) =>
          server.landed(entry.id),
        _ => false,
      };
      if (bad) throw StateError('${entry.id} is $state against the server');
    }
    final sync = syncStateOf(
      OwnedBy(testAccount),
      Tally.of(client.queue, clock),
      network: Network.online,
      signedIn: SignedInAs(testAccount),
    );
    if (Tally.of(queue, clock).setAside != queue.strategy.setAside.count) {
      throw StateError('the tally does not count what was set aside');
    }
    final quiet =
        client.queue.entries.isEmpty &&
        client.queue.strategy.setAside.count == 0 &&
        standingOf(client.queue) != Standing.deletedOnServer &&
        standingOf(client.queue) != Standing.editAccessLost &&
        ![
          client.queue.shown.list,
          ...client.queue.shown.pageReads.values,
        ].any((read) => read is ReadRefused || read is ReadOwed) &&
        client.queue.shown.pages.keys.every(
          client.queue.shown.content.containsKey,
        );
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
      return elementAdd(opId, elementId: freshElementId(), pageId: pick(pages));
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

  void deleteAndPutBack() {
    final rows = client.visible;
    final copying = {
      for (final entry in client.queue.entries)
        if (entry case PendingOp(
          op: PageAddOp(:final pagePublicId, copyContentFromPagePublicId: _?),
        ))
          pagePublicId,
    };
    final live = [
      for (final row in rows.elements)
        if (row case LiveElement(:final pagePublicId)
            when rows.page(pagePublicId) is LivePage &&
                !copying.contains(pagePublicId))
          row,
    ];
    if (live.isEmpty) return;
    final target = pick(live);
    final delete = elementDelete(
      fresh('op'),
      elementId: target.publicId,
      pageId: target.pagePublicId,
      expected: target.revision,
    );
    final applied = applyOp(rows, delete);
    if (applied is! OpApplied) return;
    final putBack = switch (buildUndo(
      rows.withRows(applied.rows),
      applied.undo,
      opId: fresh('op'),
      defaultSettings: defaultSettings,
    )) {
      UndoReady(op: final ElementAddOp op) => op,
      _ => null,
    };
    if (putBack == null) return;
    count('put-backs');
    edit(delete);
    edit(putBack);
  }

  void edit([StrategyOp? chosen]) {
    final op = chosen ?? editOp();
    if (op == null) return;
    final visible = client.visible;
    final onTop = onVisible(visible, op);
    if (applyOp(visible, onTop) is! OpApplied) return;
    final ops = switch (op) {
      PageAddOp(copyContentFromPagePublicId: _?) => switch (expandCopy(
        visible,
        op,
      )) {
        CopyExpanded(:final ops) => ops,
        CopyNotExpanded() => const <StrategyOp>[],
      },
      _ => [op],
    };
    var stepped = ops.isNotEmpty;
    for (final each in ops) {
      if (expectedOf(each) case final revision?) {
        (seen[checkTargetOf(each)] ??= {}).add(revision);
      }
      if (revisionsOf(client.base)[checkTargetOf(each)] case final shown?) {
        (seen[checkTargetOf(each)] ??= {}).add(shown);
      }
      if (rowOf(client.visible, checkTargetOf(each)) case final row?) {
        seenDigest[each.opId] = rowDigest(row);
      }
      stepped =
          apply(
                client.editEvent(each),
                'edit ${each.opId} ${each.type.wireName} ${targetOf(each)}',
              )
              is Stepped &&
          stepped;
    }
    if (!stepped) return;
    if (applyOp(reference, onVisible(reference, op))
        case final OpApplied done) {
      reference = bornWhereNew(reference, done.rows, addedLife);
    }
  }

  void madeEdit() {
    final current = client.visible;
    final drawn = teammates && making.nextBool()
        ? lastDrawn ?? current
        : current;
    lastDrawn = current;
    final copying = {
      for (final entry in client.queue.entries)
        if (entry case PendingOp(
          op: PageAddOp(:final pagePublicId, copyContentFromPagePublicId: _?),
        ))
          pagePublicId,
    };
    final live = [
      for (final row in drawn.elements)
        if (row case LiveElement(:final pagePublicId)
            when current.page(pagePublicId) is LivePage &&
                !copying.contains(pagePublicId) &&
                current.element(row.publicId) is LiveElement)
          row,
    ];
    final ownDeletes = {
      for (final op in [
        for (final entry in client.queue.entries.whereType<PendingOp>())
          entry.op,
        for (final work in client.queue.landed) work.op,
      ])
        if (op case ElementDeleteOp(:final elementPublicId)) elementPublicId,
    };
    final deleted = [
      for (final row in drawn.elements)
        if (row case LiveElement(:final pagePublicId)
            when current.page(pagePublicId) is LivePage &&
                !copying.contains(pagePublicId) &&
                !ownDeletes.contains(row.publicId) &&
                current.element(row.publicId) is DeletedElement)
          row,
    ];
    if (live.isEmpty && deleted.isEmpty) return;
    final replaced = [
      for (final row in live)
        if (createdAtOf(row) != createdAtOf(current.element(row.publicId)!))
          row,
    ];
    final target = deleted.isNotEmpty
        ? deleted[making.nextInt(deleted.length)]
        : replaced.isNotEmpty && making.nextBool()
        ? replaced[making.nextInt(replaced.length)]
        : live[making.nextInt(live.length)];
    final op = ElementPatchOp(
      opId: fresh('op'),
      elementPublicId: target.publicId,
      expectedElementRevision: target.revision,
      payload: agentPayload(target.publicId, {
        ...target.payload.data.toJson(),
        'position': {'dx': making.nextInt(1000), 'dy': 0},
      }),
      sortIndex: target.sortIndex,
      merge: FieldMerge(
        fields: ['position'],
        base: {'position': ?target.payload.data['position']},
      ),
    );
    final session = client.queue.session.number;
    final lives = {target.key: ?createdAtOf(target)};
    final made = switch (making.nextInt(4)) {
      0 || 1 => MadeLive(session, drawnLives: lives),
      2 => MadeLive(session - 1, drawnLives: lives),
      _ => MadeChecked(drawnLives: lives),
    };
    final at = client.atCommitOf(op, made);
    if (at case AppliedAs(
      op: final form,
    ) when applyOp(current, form) is! OpApplied) {
      return;
    }
    if (made is MadeLive && made.session != session) {
      count('made live in an ended session, made checked');
    }
    switch (at) {
      case AppliedAs(op: final form):
        if (form != op && applyOp(current, op) is OpRefused) {
          count('made live: a base the held row moved past, applied unchecked');
        }
      case HeldForUser(reason: RejectionReason.fieldConflict):
        count(
          'made checked: a base the held row moved past, held for the user',
        );
      case HeldForUser(reason: RejectionReason.deleted):
        count('a row deleted since the draw, held for the user');
      case HeldForUser():
        count('a row replaced since the draw, held for the user');
    }
    final row = rowOf(current, checkTargetOf(op))!;
    (seen[checkTargetOf(op)] ??= {}).add(target.revision);
    if (revisionsOf(client.base)[checkTargetOf(op)] case final shown?) {
      (seen[checkTargetOf(op)] ??= {}).add(shown);
    }
    seenDigest[op.opId] = rowDigest(row);
    if (apply(
          client.editEvent(op, made),
          'edit ${op.opId} made as ${made.runtimeType} ${targetOf(op)}',
        )
        is! Stepped) {
      return;
    }
    switch (at) {
      case AppliedAs(op: final form):
        if (applyOp(reference, onVisible(reference, withoutFieldBase(form)))
            case final OpApplied done) {
          reference = bornWhereNew(reference, done.rows, addedLife);
        }
      case HeldForUser():
        heldAtCommit.add(op.opId);
        if (rowDigest(rowOf(client.visible, checkTargetOf(op))!) !=
            rowDigest(row)) {
          throw StateError('${op.opId} was held at commit but drawn over');
        }
    }
  }

  void claim() {
    if (standingOf(client.queue) != Standing.good) return;
    final seen = look(client.queue, clock);
    client.queue = seen.queue;
    final views = seen.views;
    String? owner;
    PendingOp? first;
    final ids = <String>[];
    final most = 1 + random.nextInt(4);
    for (final entry in client.queue.entries) {
      if (ids.length == most) break;
      final view = views[entry.id];
      if (view == null || !view.sendable || entry is! PendingOp) continue;
      final mine = switch (view.state) {
        Unanswered(:final clientId) => clientId,
        _ => owner ?? clientId,
      };
      if (owner != null && mine != owner) continue;
      if (!fitsBatch(entry, first)) continue;
      owner = mine;
      first ??= entry;
      ids.add(entry.id);
    }
    if (ids.isEmpty) return;
    final entries = {
      for (final entry in client.queue.entries)
        if (entry is PendingOp) entry.id: entry,
    };
    final result = must(
      BatchClaimed(
        clientId: owner!,
        opIds: ids,
        at: clock,
        elapsed: () => elapsed,
      ),
      'claim $ids as $owner',
    );
    final sent = result.effects.whereType<SendBatch>().single;
    livesSent.addAll(sent.lives);
    for (final op in sent.ops) {
      if (sent.strategyLife case final life?) strategyLifeSent[op.opId] = life;
      if (sent.strategyLife case final life?
          when refusedStrategyLives.contains(life)) {
        throw StateError(
          '${op.opId} was sent naming strategy life $life after the server '
          'refused that life',
        );
      }
      if (setAsideIds.contains(op.opId)) {
        throw StateError('${op.opId} was sent after it was set aside');
      }
      if (refusedOps.contains(op.opId)) {
        throw StateError(
          '${op.opId} was sent again after the server refused it',
        );
      }
      if (heldAtCommit.contains(op.opId)) {
        throw StateError('${op.opId} was sent after its commit held it');
      }
    }
    count('ops sent naming a row life', sent.lives.length);
    if (sent.strategyLife != null) count('batches naming the strategy life');
    int? oldest;
    for (final op in sent.ops) {
      inFlightLog[op.opId] = '${op.toJson()}';
      if (!uncheckedOnTheWire(op)) continue;
      if (entries[op.opId]!.madeAs == MadeAs.checked) {
        throw StateError('${op.opId} was made checked and went out unchecked');
      }
      count('unchecked sends');
      final basis = entries[op.opId]!.basis;
      if (basis == null) {
        throw StateError('${op.opId} went out unchecked with no basis');
      }
      if (elapsed - basis.heldAt > liveFor) {
        throw StateError(
          '${op.opId} went out unchecked on a basis '
          '${elapsed - basis.heldAt} old',
        );
      }
      if (refusedLate.contains(op.opId)) {
        throw StateError(
          '${op.opId} went out unchecked again after a late refusal',
        );
      }
      if (oldest == null || basis.serverTime < oldest) {
        oldest = basis.serverTime;
      }
    }
    if ({
          for (final op in sent.ops)
            if (uncheckedOnTheWire(op)) entries[op.opId]!.basis!.serverTime,
        }.length >
        1) {
      count('batches whose live ops carry different bases');
    }
    if (sent.basis != oldest) {
      throw StateError(
        'the batch carries basis ${sent.basis}, its oldest unchecked op '
        '$oldest',
      );
    }
    inFlight.add((
      sent.attempt,
      sent.clientId,
      sent.ops,
      sent.basis,
      client.queue.session.number,
    ));
  }

  void deliver({required bool reliable}) {
    if (inFlight.isEmpty) return;
    final (attempt, owner, ops, basis, session) = inFlight.removeAt(
      random.nextInt(inFlight.length),
    );
    final roll = reliable ? 0 : random.nextInt(12);
    if (!server.exists) {
      apply(
        BatchRefused(
          attempt,
          BatchRefusal.strategyDeleted,
          point: stamps.answered,
        ),
        'refused: gone',
      );
      return;
    }
    if (namesAnotherStrategyLife(ops)) {
      count('batches refused as the strategy was replaced');
      apply(
        BatchRefused(
          attempt,
          BatchRefusal.strategyReplaced,
          point: stamps.answered,
        ),
        'refused: the strategy was replaced',
      );
      if (!lastAdmitted) {
        count('refusals stamped on an ended connection, taken as lost');
        return;
      }
      refusedStrategyLives.addAll([
        for (final op in ops) ?strategyLifeSent[op.opId],
      ]);
      return;
    }
    if (roll == 11) {
      if (random.nextBool()) held.add((owner, ops, basis));
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
      apply(
        BatchRefused(attempt, refusal, point: stamps.answered),
        'refused whole ${refusal.name}',
      );
      return;
    }
    if (roll == 6) {
      pass(Duration(milliseconds: 20000 + random.nextInt(9000)));
      count('calls the transport held 20 to 29 s');
    }
    final received = receive(owner, ops, basis);
    if (received == null) {
      apply(
        BatchRefused(
          attempt,
          BatchRefusal.uncheckedTooLate,
          point: stamps.answered,
        ),
        'refused late $attempt',
      );
      if (!lastAdmitted) {
        count('refusals stamped on an ended connection, taken as lost');
        return;
      }
      refusedLate.addAll([for (final op in ops) op.opId]);
      return;
    }
    final answers = received;
    final point = answers.any((answer) => answer is AppliedAnswer)
        ? stampOfState()
        : stamps.answered;
    if (roll == 9) {
      apply(
        TransportFailed(attempt, TransportFailure.timeout, at: clock),
        'timed out $attempt',
      );
      if (random.nextBool()) {
        late.addAll([for (final answer in answers) (attempt, answer, point)]);
      }
      return;
    }
    final order = [
      for (final answer in answers)
        switch (answer) {
          NoopAnswer(
            :final opId,
            :final revision,
            replay: NoopReplay.appliedWhenFirstReceived,
          )
              when teammates && random.nextInt(4) == 0 =>
            () {
              count('replays answered without a life');
              return AnswerWithoutLife(opId, revision: revision);
            }(),
          _ => answer,
        },
    ];
    if (roll == 8) order.shuffle(random);
    for (final answer in order) {
      apply(OpAnswered(attempt, answer, point: point), 'answer ${answer.opId}');
      if (roll == 7) {
        apply(
          OpAnswered(attempt, answer, point: point),
          'again ${answer.opId}',
        );
      }
    }
    apply(
      ServerTimeHeld(
        serverNow,
        at: elapsed,
        session: session,
        point: stamps.current,
      ),
      'server time $serverNow from session $session',
    );
  }

  void ownerReplaces() {
    if (server.exists && lateness.nextBool()) {
      count('reads of a strategy life answered after it was replaced');
      for (final base in [
        headerReadOf(server.rows),
        for (final page in server.rows.pages.take(1))
          pageReadOf(server.rows, page.publicId),
      ]) {
        readsInFlight.add((
          BaseArrived(
            base,
            session: client.queue.session.number,
            point: stampOfState(),
          ),
          'read ${subjectOf(base) ?? 'strategy'} before it was replaced',
        ));
      }
    }
    server.reupload();
    count('the strategy is replaced');
    log.add('the strategy is replaced');
  }

  void teammateReplacesARow() {
    final busy = {
      for (final op in [
        for (final entry in client.queue.entries.whereType<PendingOp>())
          entry.op,
        for (final work in client.queue.landed) work.op,
        for (final (_, _, ops, _, _) in inFlight) ...ops,
        for (final (_, ops, _) in held) ...ops,
      ])
        for (final target in [targetOf(op), checkTargetOf(op)])
          if (target case ElementTarget(:final elementPublicId))
            elementPublicId,
    };
    final shown = [
      for (final row in client.visible.elements)
        if (row is LiveElement && !busy.contains(row.publicId))
          if (server.rows.element(row.publicId) case final LiveElement live)
            if (server.rows.page(live.pagePublicId) is LivePage) live,
    ];
    if (shown.isEmpty) return;
    final row = pick(shown);
    final before = fieldsOf(server.rows);
    final deleted = applyOp(
      server.rows,
      elementDelete(
        fresh('t'),
        elementId: row.publicId,
        pageId: row.pagePublicId,
        expected: row.revision,
      ),
    );
    if (deleted is! OpApplied) return;
    server.write(deleted);
    server.purgeTombstone(row.publicId);
    final back = applyOp(
      server.rows,
      ElementAddOp(
        opId: fresh('t'),
        elementPublicId: row.publicId,
        pagePublicId: row.pagePublicId,
        payload: agentPayload(row.publicId, {
          ...row.payload.data.toJson(),
          'rotation': 135,
        }),
        sortIndex: row.sortIndex,
      ),
    );
    if (back is! OpApplied) return;
    server.write(back);
    teammateEdited = true;
    recordHistory();
    final after = fieldsOf(server.rows);
    for (final key in {...before.keys, ...after.keys}) {
      if (before[key] != after[key]) teammateWrote[key] = serverNow;
    }
    count('teammate replaces a row this device shows');
    log.add('teammate replaces ${row.publicId}');
    if (replacing.nextBool()) editBeforeReading(row.publicId);
  }

  void editBeforeReading(String elementId) {
    if (standingOf(client.queue) != Standing.good) return;
    if (client.visible.element(elementId) case final LiveElement row) {
      final opId = fresh('op');
      edit(
        movePatch(
          opId,
          elementId: elementId,
          expected: row.revision,
          rotation: 60,
        ),
      );
      claim();
      deliver(reliable: false);
      if (server.landed(opId) || server.refused(opId)) {
        count('edits of a replaced row the server answered before a read');
      }
    }
  }

  void teammateWrites() {
    final before = fieldsOf(server.rows);
    teammate();
    final after = fieldsOf(server.rows);
    for (final key in {...before.keys, ...after.keys}) {
      if (before[key] != after[key]) teammateWrote[key] = serverNow;
    }
  }

  void deliverHeld() {
    if (held.isEmpty || !server.exists) return;
    final (owner, ops, basis) = held.removeAt(random.nextInt(held.length));
    count('held calls delivered');
    log.add(
      'transport delivers a held call ${ops.map((op) => op.opId)}: '
      '${receive(owner, ops, basis) == null ? 'refused' : 'received'}',
    );
  }

  void restart() {
    for (final (_, owner, ops, basis, _) in inFlight) {
      if (random.nextBool() && server.exists) {
        receive(owner, ops, basis);
      } else if (random.nextBool()) {
        held.add((owner, ops, basis));
      }
    }
    inFlight.clear();
    late.clear();
    elapsed = Duration.zero;
    clientId = 'client-${++restarts}';
    if (random.nextInt(3) == 0) build = 'build-$restarts';
    must(AppRestarted(build: build), 'restart as $clientId on $build');
  }

  bool atAStandingRowRefusal(ArrivedBase base, ResultPoint point) {
    final state = switch (subjectOf(base)) {
      null => client.queue.shown.list,
      final page => client.queue.shown.pageRead(page),
    };
    return switch (state) {
      ReadOwed(since: AfterRefusal(visibleAt: true, point: final refused)) ||
      ReadRefused(since: AfterRefusal(visibleAt: true, point: final refused)) =>
        point.generation == refused.generation &&
            point.snapshot >= refused.snapshot,
      _ => false,
    };
  }

  void arrive(ArrivedBase base, String label, {bool reliable = false}) {
    final read = BaseArrived(
      base,
      session: client.queue.session.number,
      point: stampOfState(),
    );
    if (atAStandingRowRefusal(base, read.point)) {
      count(
        'results at or after a row refusal\'s snapshot while its debt '
        'stood',
      );
    }
    if (!reliable &&
        (base is HeaderRead || base is PageRead) &&
        lateness.nextInt(20) == 0) {
      refuse(read, label, 'came back in rows this build cannot read');
      return;
    }
    if (!reliable && lateness.nextInt(16) == 0) {
      readsInFlight.add((read, label));
      count('reads held in flight');
      return;
    }
    deliverRead(read, label, late: false, reliable: reliable);
  }

  void deliverLateRead() {
    if (readsInFlight.isEmpty) return;
    final (event, label) = readsInFlight.removeAt(
      lateness.nextInt(readsInFlight.length),
    );
    switch (event) {
      case final BaseArrived read:
        deliverRead(read, 'late $label', late: true, reliable: false);
      case final ResultRefused refusal:
        deliverRefusal(refusal, 'late $label');
      case _:
        throw StateError('$label: $event was held in flight as a read');
    }
  }

  String notTaken(Step result) => switch (result) {
    NotApplicable(:final why) => '${why.runtimeType}',
    Stepped(tookResult: true) => 'taken again at the order it holds',
    Stepped() => 'deferred',
  };

  void deliverRead(
    BaseArrived read,
    String label, {
    required bool late,
    required bool reliable,
  }) {
    final subject = subjectOf(read.base);
    final sessionBefore = sessionNumber;
    final shownBefore = client.queue.shown;
    final result = apply(read, label);
    final opened = sessionNumber != sessionBefore;
    final before = opened ? null : shownBefore.contentTakenOf(subject);
    final fenceBefore = opened ? null : shownBefore.fence;
    final mine = mirrorTaken[subject];
    final order = mirrorRead(read);
    if (result case Stepped(
      :final effects,
    ) when effects.any((effect) => effect is PageResultDeferred)) {
      if (mine == null) {
        mirrorTaken.remove(subject);
      } else {
        mirrorTaken[subject] = mine;
      }
      count('page reads deferred, moving no order');
    }
    final shown = client.queue.shown;
    final now = shown.contentTakenOf(subject);
    final taken = order != null && now == order && now != before;
    if (now != before && (now != order || mirrorTaken[subject] == mine)) {
      throw StateError(
        '$label: the queue took ${subject ?? 'the page list'} at $now, a '
        'result the model\'s order does not take over $before',
      );
    }
    if (shown.fence != fenceBefore) {
      if (!taken || read.base is! HeaderRead || shown.fence != order) {
        throw StateError(
          '$label: the queue fenced its results at ${shown.fence}, not at a '
          'page list result it took',
        );
      }
      mirrorFence = order;
      mirrorTaken.removeWhere((subject, _) => subject != null);
      mirrorRefused.clear();
      count('the model adopted another strategy life');
    }
    final kind = subject == null ? 'list' : 'page';
    if (late) {
      if (taken) {
        count('late reads taken');
      } else {
        count('late reads not taken: ${notTaken(result)}');
        count('late $kind reads not taken: ${notTaken(result)}');
      }
    } else if (!taken) {
      count('reads not taken on arrival: ${notTaken(result)}');
    }
    if (result case Stepped()) mirror(read.base, result);
    checkTaken();
    final queueTook = result is Stepped && result.tookResult;
    if (!queueTook && !reliable && lateness.nextInt(3) == 0) {
      refuse(read, label, 'the queue did not take it (${notTaken(result)})');
    }
  }

  ResultOrder? mirrorRead(BaseArrived read) {
    if (!lastAdmitted) return null;
    final subject = subjectOf(read.base);
    final order = ResultOrder(
      session: sessionNumber,
      client: read.point.client,
      snapshot: read.point.snapshot,
    );
    (delivered[subject] ??= {}).add(order);
    if (mirrorFence case final fence? when order.isBefore(fence)) {
      return order;
    }
    if (mirrorTaken[subject] case final last? when !last.isBefore(order)) {
      return order;
    }
    mirrorTaken[subject] = order;
    count('results the model took');
    return order;
  }

  void refuse(BaseArrived read, String label, String why) {
    final refusal = ResultRefused(
      page: subjectOf(read.base),
      problem: 'the read $why',
      session: read.session,
      point: read.point,
    );
    if (lateness.nextBool()) {
      readsInFlight.add((refusal, 'refusal of $label'));
      count('read refusals held in flight');
      return;
    }
    deliverRefusal(refusal, 'refusal of $label');
  }

  void deliverRefusal(ResultRefused refusal, String label) {
    final subject = refusal.page;
    final sessionBefore = sessionNumber;
    final shownBefore = client.queue.shown;
    apply(refusal, label);
    final opened = sessionNumber != sessionBefore;
    final content = opened ? null : shownBefore.contentTakenOf(subject);
    final fence = opened ? null : shownBefore.fence;
    final order = ResultOrder(
      session: sessionNumber,
      client: refusal.point.client,
      snapshot: refusal.point.snapshot,
    );
    final last = mirrorRefused[subject];
    if (!lastAdmitted) {
      count('read refusals not taken: from an ended connection');
    } else if (fence != null && order.isBefore(fence)) {
      count('read refusals not taken: from another strategy life');
    } else if (content != null && !content.isBefore(order)) {
      count('read refusals not taken: not newer than the content taken');
    } else if (last != null && order.isBefore(last)) {
      count('read refusals not taken: older than the last refusal taken');
    } else {
      mirrorRefused[subject] = order;
      count('read refusals taken');
    }
    checkTaken();
  }

  void checkTaken({bool exact = false}) {
    final shown = client.queue.shown;
    for (final subject in {
      null,
      ...shown.pagesTaken.keys,
      ...mirrorTaken.keys,
    }) {
      final taken = shown.contentTakenOf(subject);
      final mine = mirrorTaken[subject];
      final name = subject ?? 'the page list';
      if (taken != null && !(delivered[subject]?.contains(taken) ?? false)) {
        throw StateError(
          'the queue holds $name as taken at $taken, which no result the '
          'model delivered carried',
        );
      }
      if (taken != null && (mine == null || mine.isBefore(taken))) {
        throw StateError(
          'the queue took $name at $taken, newer than the newest result '
          'the model\'s order takes, $mine',
        );
      }
      if (exact && taken != mine) {
        throw StateError(
          'after a fresh read of everything the queue holds $name at '
          '$taken and the model at $mine',
        );
      }
    }
    for (final subject in {
      null,
      ...shown.pagesRefusedAt.keys,
      ...mirrorRefused.keys,
    }) {
      final held = shown.refusedAtOf(subject);
      if (held != mirrorRefused[subject]) {
        throw StateError(
          'the queue holds ${subject ?? 'the page list'} as refused at $held, '
          'the model at ${mirrorRefused[subject]}',
        );
      }
    }
  }

  void readEverything() {
    arrive(headerReadOf(server.rows), 'final read strategy', reliable: true);
    final pages = {
      for (final page in server.rows.pages) page.publicId,
      ...client.queue.shown.pagesTaken.keys,
      for (final subject in mirrorTaken.keys) ?subject,
    };
    for (final page in pages) {
      arrive(
        server.rows.page(page) == null
            ? PageGone(page)
            : pageReadOf(server.rows, page),
        'final read $page',
        reliable: true,
      );
    }
    checkTaken(exact: true);
    count('ends where the queue and the model took the same results');
  }

  void mirror(ArrivedBase base, Step step) {
    if (step case Stepped(tookResult: true)) {
      client.base = switch (base) {
        HeaderRead(
          strategy: final ReadableStrategy strategy,
          :final pages,
          :final settings,
        ) =>
          StrategyRowSet(
            strategy: strategy,
            pages: pages,
            settings: settings,
            elements: client.base.elements,
            lineupGroups: client.base.lineupGroups,
          ),
        PageRead(:final page, :final elements, :final lineupGroups) =>
          StrategyRowSet(
            strategy: client.base.strategy,
            pages: client.base.pages,
            settings: client.base.settings,
            elements: [
              ...client.base.elements.where(
                (row) => row.pagePublicId != page.publicId,
              ),
              ...elements,
            ],
            lineupGroups: [
              ...client.base.lineupGroups.where(
                (row) => row.pagePublicId != page.publicId,
              ),
              ...lineupGroups,
            ],
          ),
        HeaderRead() || PageGone() || StrategyGone() => client.base,
      };
    }
    final held = client.queue.shown.content.keys.toSet();
    client.base = StrategyRowSet(
      strategy: client.base.strategy,
      pages: client.base.pages,
      settings: client.base.settings,
      elements: client.base.elements.where(
        (row) => held.contains(row.pagePublicId),
      ),
      lineupGroups: client.base.lineupGroups.where(
        (row) => held.contains(row.pagePublicId),
      ),
    );
  }

  void readHeader() {
    if (!server.exists) {
      arrive(const StrategyGone(), 'read: gone');
      return;
    }
    final rows = server.rows;
    final kept = {for (final page in rows.pages) page.publicId};
    for (final page in client.base.pages) {
      if (!kept.contains(page.publicId)) {
        arrive(PageGone(page.publicId), 'read ${page.publicId}: gone');
      }
    }
    arrive(headerReadOf(rows), 'read strategy');
  }

  void readPage(String pageId) {
    if (!server.exists) return;
    final page = server.rows.page(pageId);
    if (page == null) {
      arrive(PageGone(pageId), 'read $pageId: gone');
      return;
    }
    arrive(pageReadOf(server.rows, pageId), 'read $pageId');
  }

  String? pageHolding(Target target) => switch (target) {
    ElementTarget(:final elementPublicId) =>
      client.visible.element(elementPublicId)?.pagePublicId,
    LineupTarget(:final lineupPublicId) =>
      client.visible.lineupGroup(lineupPublicId)?.pagePublicId,
    _ => null,
  };

  Set<String> pagesTheLaneReads() => {
    openPage,
    for (final subject in resultsNeeded(client.queue, clock))
      ?switch (subject) {
        RowResult(:final page?) => page,
        RowResult(:final target) => pageHolding(target),
        PageResult(:final page) => page,
        PageListResult() => null,
      },
    for (final work in client.queue.landed) ...[
      ...pagesNeeded(work.op),
      ?pageHolding(targetOf(work.op)),
    ],
  };

  void lane() {
    switch (standingOf(client.queue)) {
      case Standing.editAccessLost:
        final confirmed = EditAccessConfirmed(
          afterAttempt: client.queue.nextAttempt - 1,
          session: client.queue.session.number,
          point: stamps.at(serverState),
        );
        switch (apply(confirmed, 'access confirmed')) {
          case NotApplicable(why: FromAnEndedSession()):
            count('access confirmed on an ended connection, read again');
          case NotApplicable(:final why):
            throw StateError('access confirmed: $why');
          case Stepped():
            break;
        }
      case Standing.upgradeRequired:
        build = 'build-up-${restarts++}';
        late.clear();
        must(AppRestarted(build: build), 'upgraded to $build');
      case Standing.good || Standing.deletedOnServer || Standing.held:
        break;
    }
    readHeader();
    for (final page in pagesTheLaneReads()) {
      readPage(page);
      if (lateness.nextInt(3) == 0) deliverLateRead();
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
      final livePages = [
        for (final page in server.rows.pages)
          if (page is LivePage) page.publicId,
      ];
      final kind = random.nextInt(14);
      final deleting = [
        for (final entry in client.queue.entries)
          if (entry case PendingOp(
            op: PageDeleteOp(:final pagePublicId),
          ) when server.rows.page(pagePublicId) is LivePage)
            pagePublicId,
      ];
      final madeHere = [
        for (final page in livePages)
          if (page.startsWith('page-')) page,
      ];
      final aimed = deleting.isNotEmpty
          ? pick(deleting)
          : madeHere.isNotEmpty
          ? pick(madeHere)
          : pick(livePages);
      final mine = [
        for (final entry in client.queue.entries)
          if (entry case PendingOp(
            op: final ElementPatchOp op,
          ) when server.rows.element(op.elementPublicId) is LiveElement)
            op,
      ];
      final StrategyOp op = switch (kind) {
        10 || 11 when mine.isNotEmpty => sameAsMine(pick(mine), kind == 11),
        12 => settingsOn(aimed),
        13 => elementAdd(fresh('t'), elementId: fresh('t'), pageId: aimed),
        0 || 1 => ElementReorderOp(
          opId: fresh('t'),
          elementPublicId: target.publicId,
          pagePublicId: target.pagePublicId,
          sortIndex: random.nextInt(3),
          expectedElementRevision: target.revision,
        ),
        2 => elementDelete(
          fresh('t'),
          elementId: target.publicId,
          pageId: target.pagePublicId,
          expected: target.revision,
        ),
        3 when livePages.length > 1 => ElementPatchOp(
          opId: fresh('t'),
          elementPublicId: target.publicId,
          expectedElementRevision: target.revision,
          pagePublicId: pick([
            for (final page in livePages)
              if (page != target.pagePublicId) page,
          ]),
          payload: target.payload,
          sortIndex: 0,
        ),
        4 when livePages.length > 2 => pageDelete(
          fresh('t'),
          pick(switch ([
            for (final entry in client.queue.entries.whereType<PendingOp>())
              for (final page in pagesOf(entry))
                if (livePages.contains(page)) page,
          ]) {
            final edited when edited.isNotEmpty => edited,
            _ => livePages,
          }),
          expected: server.rows.strategy.revision,
        ),
        _ => movePatch(
          fresh('t'),
          elementId: target.publicId,
          expected: target.revision,
          rotation: 30,
        ),
      };
      if (applyOp(server.rows, op) case final OpApplied done) {
        server.write(done);
        count('teammate ${op.type.wireName}');
      } else {
        return;
      }
    }
    teammateEdited = true;
    log.add('teammate acts');
  }

  void purgeAndPutBack() {
    for (final (attempt, owner, ops, basis, _) in [...inFlight]) {
      if (random.nextBool()) receive(owner, ops, basis);
      apply(
        TransportFailed(attempt, TransportFailure.network, at: clock),
        'given up across 30 days $attempt',
      );
    }
    inFlight.clear();
    recordHistory();
    final purged = [
      for (final row in server.rows.elements)
        if (row is DeletedElement) row,
    ];
    if (purged.isEmpty) return;
    server.purgeAfterThirtyDays();
    count('tombstones purged');
    for (final row in purged) {
      if (!teammates || random.nextBool()) continue;
      if (server.rows.page(row.pagePublicId) is! LivePage) continue;
      final back = ElementAddOp(
        opId: fresh('t'),
        elementPublicId: row.publicId,
        pagePublicId: row.pagePublicId,
        payload: agentPayload(row.publicId, {
          ...row.payload.data.toJson(),
          'rotation': 135,
        }),
        sortIndex: row.sortIndex,
      );
      if (applyOp(server.rows, back) case final OpApplied done) {
        server.write(done);
        teammateEdited = true;
        count('teammate puts a purged element back at revision 1');
      }
    }
    recordHistory();
  }

  StrategyOp settingsOn(String page) {
    final current = server.rows.settingsOf(page)! as ReadablePageSettings;
    count('teammate changes a page\'s settings');
    return PageSettingsPatchOp(
      opId: fresh('t'),
      pagePublicId: page,
      settings: PageSettings(
        agentSize: 1.0 + random.nextInt(3),
        abilitySize: 1.0 + random.nextInt(3),
        useNeutralTeamColors: random.nextBool(),
      ),
      expectedPageSettingsRevision: current.revision,
    );
  }

  StrategyOp sameAsMine(ElementPatchOp mine, bool alsoRotated) {
    final row = server.rows.element(mine.elementPublicId)! as LiveElement;
    final payload = mine.payload ?? row.payload;
    count(
      alsoRotated
          ? 'teammate makes this device\'s change and rotates'
          : 'teammate makes this device\'s change',
    );
    return ElementPatchOp(
      opId: fresh('t'),
      elementPublicId: row.publicId,
      expectedElementRevision: row.revision,
      pagePublicId: mine.pagePublicId,
      payload: alsoRotated
          ? agentPayload(row.publicId, {
              ...payload.data.toJson(),
              'rotation': 45,
            })
          : payload,
      sortIndex: mine.sortIndex,
    );
  }

  void userActs({required bool draining}) {
    final seen = look(client.queue, clock);
    client.queue = seen.queue;
    final views = seen.views;
    if (client.queue.strategy.setAside.count > 0 &&
        (draining || random.nextBool())) {
      apply(const UserDiscardedReplaced(), 'user discards what was set aside');
    }
    for (final entry in client.queue.entries) {
      final view = views[entry.id];
      final UserAction? action = switch ((entry, view)) {
        (
          PendingOp(),
          EntryView(state: NeedsUser(reason: RetriesExhausted())),
        ) =>
          UserRetried(entry.id),
        (PendingOp(), EntryView(state: NeedsUser())) =>
          random.nextBool() ? UserUsedCloud(entry.id) : UserDiscarded(entry.id),
        (PendingOp(), EntryView(:final holds))
            when draining && holds.any((hold) => hold is PageInTrash) =>
          UserDiscarded(entry.id),
        (RetiredOp(), _) => UserDiscarded(entry.id),
        _
            when standingOf(client.queue) == Standing.deletedOnServer &&
                view?.state is! Sending =>
          UserDiscarded(entry.id),
        _ => null,
      };
      if (action == null) continue;
      final forgotten = switch ((view?.state, entry)) {
        (NeedsUser(reason: WindowClosed() || WrittenLongAgo()), _) => true,
        (
          NeedsUser(reason: ChangedUnseen()),
          PendingOp(op: ElementAddOp(expectedElementRevision: _?)),
        ) =>
          jumped,
        _ => false,
      };
      if (forgotten) count('forgotten answers handed to the user');
      final retriedAfterTheLadder = action is UserRetried;
      if (draining && retriedAfterTheLadder) {
        count('ladders run out by lost answers, retried in the drain');
      }
      final expected = forgotten || userRemoved || retriedAfterTheLadder;
      if (draining && !expected) drainHelps++;
      if (!teammates && action is! UserRetried && !expected) {
        throw StateError(
          'the user was asked $action for ${entry.id}: '
          '${view?.state}, ${view?.holds}',
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
    final jump = random.nextInt(400) == 0;
    if (jump) {
      jumped = true;
      purgeAndPutBack();
    }
    pass(
      jump
          ? serverRemembersAnswersFor + const Duration(hours: 1)
          : Duration(milliseconds: random.nextInt(2000)),
    );
    if (jump) held.clear();
    switch (random.nextInt(24)) {
      case < 6:
        edit();
        if (making.nextInt(4) == 0) madeEdit();
      case 6:
        deleteAndPutBack();
      case < 10:
        claim();
      case < 14:
        deliver(reliable: false);
      case 14:
        restart();
      case 15:
        lane();
      case 16:
        if (replacing.nextInt(30) == 0) {
          ownerReplaces();
        } else if (teammates && replacing.nextInt(6) == 0) {
          teammateReplacesARow();
        } else if (teammates) {
          teammateWrites();
        }
      case 22:
        final quiet = Duration(milliseconds: 10000 + random.nextInt(35000));
        if (random.nextBool()) {
          clock = clock.add(quiet);
          count('the device slept');
          log.add('the device slept $quiet: its monotonic clock did not move');
        } else {
          pass(quiet);
          log.add('a quiet spell');
        }
      case 23:
        if (random.nextInt(8) == 0) {
          clockBack();
        } else {
          deliverHeld();
        }
      case 17:
        userActs(draining: false);
      case 18:
        if (lateness.nextBool()) {
          deliverLateRead();
        } else if (late.isNotEmpty) {
          final (attempt, answer, point) = late.removeAt(
            random.nextInt(late.length),
          );
          apply(
            OpAnswered(attempt, answer, point: point),
            'late ${answer.opId}',
          );
        }
      case 19:
        final pages = [for (final page in client.base.pages) page.publicId];
        if (pages.isNotEmpty) openPage = pick(pages);
      case _:
        if (random.nextBool()) {
          must(const ConnectionLost(), 'connection lost');
        } else {
          reconnect();
        }
    }
  }

  void reconnect() {
    final generation = stamps.random!.nextInt(6) == 0
        ? stamps.anotherClient()
        : stamps.reconnect();
    if (stamps.random!.nextInt(3) == 0) {
      count('stamps delivered ahead of their reconnect event');
      if (server.exists) {
        arrive(headerReadOf(server.rows), 'read strategy ahead of $generation');
      } else {
        arrive(const StrategyGone(), 'read: gone ahead of $generation');
      }
    }
    must(ConnectionReturned(generation), 'connection returned $generation');
  }

  void clockBack() {
    final back = pick(const [Duration(seconds: 1), Duration(days: 1)]);
    clock = clock.subtract(back);
    skew += back;
    count('backward clock steps');
    log.add('the device clock moves back $back');
  }

  void drain() {
    while (readsInFlight.isNotEmpty) {
      deliverLateRead();
    }
    var idle = 0;
    String? before;
    for (
      var round = 0;
      round < 300 && client.queue.entries.isNotEmpty;
      round++
    ) {
      final views = entryViews(client.queue, clock);
      final now = [
        for (final entry in client.queue.entries)
          '${entry.id} ${views[entry.id]?.state} ${views[entry.id]?.holds}',
      ].join('; ');
      idle = now == before ? idle + 1 : 0;
      before = now;
      if (idle > 0) count('drain rounds that waited out a deadline');
      pass(Duration(minutes: min(1 << min(idle, 11), 1440)));
      lane();
      userActs(draining: true);
      claim();
      while (inFlight.isNotEmpty) {
        deliver(reliable: true);
      }
    }
    if (client.queue.entries.isNotEmpty) {
      final views = entryViews(client.queue, clock);
      throw StateError(
        'did not drain: ${[for (final entry in client.queue.entries) '${entry.id} ${views[entry.id]?.state} ${views[entry.id]?.holds}'].join('; ')} '
        'landed ${client.queue.landed}',
      );
    }
    if (!teammates && drainHelps > 0) {
      throw StateError('the drain helped the user $drainHelps times');
    }
    if (server.exists) readEverything();
    if (!teammateEdited && !userRemoved && server.exists) {
      count(
        adoptedReplacement
            ? 'end content compared after a replacement'
            : 'end content compared without a replacement',
      );
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
    model.begin();
    for (var i = 0; i < steps; i++) {
      model.stepOnce();
    }
    model.drain();
    for (final MapEntry(:key, :value) in model.stamps.made.entries) {
      count(key, value);
    }
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
  'removed Delivered': 1500,
  'removed FoldedInto': 15,
  'folded element.patch': 15,
  'put-backs': 100,
  'given up with its chain': 5,
  'nothing to do at another revision': 20,
  'justified rows checked against the server': 100,
  'teammate makes this device\'s change': 20,
  'teammate makes this device\'s change and rotates': 20,
  'teammate puts a purged element back at revision 1': 10,
  'ops refused as naming a row life that was replaced': 70,
  'made live: a base the held row moved past, applied unchecked': 60,
  'made checked: a base the held row moved past, held for the user': 60,
  'made live in an ended session, made checked': 300,
  'a row replaced since the draw, held for the user': 5,
  'a row deleted since the draw, held for the user': 5,
  'page reads deferred, moving no order': 8,
  'taken content checked not to go back': 100000,
  'taken content of a page not shown checked not to go back': 4000,
  'teammate replaces a row this device shows': 80,
  'edits of a replaced row the server answered before a read': 10,
  'the strategy is replaced': 5,
  'end content compared after a replacement': 5,
  'end content compared without a replacement': 80,
  'batches refused as the strategy was replaced': 50,
  'StrategySetAside': 5,
  'reads held in flight': 500,
  'late reads taken': 300,
  'late page reads not taken: OlderResult': 80,
  'late list reads not taken: OlderResult': 40,
  'late reads not taken: StartedInAnotherLife': 1,
  'late reads not taken: FromAnEndedSession': 25,
  'UserDiscardedReplaced': 5,
  'replays answered without a life': 1,
  'teammate changes a page\'s settings': 50,
  'waits for a result that a read would settle': 200,
  'unchecked sends': 20,
  'unchecked ops applied': 10,
  'ServerTimeHeld': 5000,
  'batches refused outside the window': 4,
  'batches accepted 20 to 30 s after their basis': 2,
  'held calls delivered': 200,
  'the device slept': 100,
  'calls the transport held 20 to 29 s': 100,
  'backward clock steps': 50,
  'stamps delivered ahead of their reconnect event': 400,
  'results at or after a row refusal\'s snapshot while its debt stood': 20,
  'a stamp at the snapshot already held': 3000,
  'a stamp at the snapshot held from before a reconnect': 185,
  'a new snapshot at the same time': 1500,
  'an answer before any state was applied': 150,
  'a read before any state was applied': 240,
  'an answer stamped on the connection before a reconnect': 60,
  'time went back on a new connection': 8,
  'a second client in one run': 200,
  'refusals stamped on an ended connection, taken as lost': 8,
  'ends where the queue and the model took the same results': 300,
  'the model adopted another strategy life': 50,
  'results the model took': 10000,
  'sessions opened by a stamp from a later connection': 250,
  'sessions opened, checked against the model': 2400,
  'stamped events from a session the queue no longer labels': 5,
  'reads of a strategy life answered after it was replaced': 20,
  'read refusals taken': 350,
  'read refusals not taken: not newer than the content taken': 100,
  'read refusals not taken: older than the last refusal taken': 1,
  'read refusals not taken: from an ended connection': 12,
  'ops held for the trash': 50,
  'own changes refused as their page deleted': 6,
  'refusals as page deleted replayed after a lost answer': 1,
  'ops let go with their page': 4,
};

void main() {
  final environment = Platform.environment;
  final steps = int.tryParse(environment['CLOUD_MODEL_STEPS'] ?? '') ?? 150;
  final one = int.tryParse(environment['CLOUD_MODEL_SEED'] ?? '');
  final seeds = int.tryParse(environment['CLOUD_MODEL_SEEDS'] ?? '') ?? 200;
  test(
    'seed 7: after the device clock moves back a day, a retry waiting out its '
    'backoff goes, so the queue drains',
    () {
      runSeed(7, 150, folding: true);
      runSeed(7, 150, folding: false);
    },
  );

  final sweepFrom = int.tryParse(environment['CLOUD_MODEL_FIRST_SEED'] ?? '');
  if (sweepFrom != null) {
    test('a sweep of $seeds seeds from $sweepFrom fails only where it is known '
        'to', () {
      final known = knownFailures();
      final unknown = <String>[];
      final fixed = <int>[];
      for (var seed = sweepFrom; seed < sweepFrom + seeds; seed++) {
        final failed = <String>[];
        for (final folding in [true, false]) {
          try {
            runSeed(seed, steps, folding: folding);
          } on TestFailure catch (failure) {
            failed.add((failure.message ?? '').split('\n').first.trim());
          }
        }
        switch ((known[seed], failed)) {
          case (final cause?, []):
            fixed.add(seed);
            stdout.writeln('SWEEP seed $seed passes, known for: $cause');
          case (final cause?, _):
            stdout.writeln('SWEEP seed $seed fails as known: $cause');
            for (final failure in failed) {
              stdout.writeln('SWEEP   $failure');
            }
          case (null, []):
            break;
          case (null, _):
            unknown.addAll(failed);
            for (final failure in failed) {
              stdout.writeln('SWEEP $failure');
            }
        }
      }
      expect(fixed, isEmpty, reason: 'remove these from $knownFailuresFile');
      expect(unknown, isEmpty);
    });
    return;
  }

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

const knownFailuresFile = 'test/cloud_model_known_failures.json';

Map<int, String> knownFailures() => {
  for (final entry
      in jsonDecode(File(knownFailuresFile).readAsStringSync()) as List)
    (entry as Map<String, Object?>)['seed']! as int: entry['cause']! as String,
};

bool uncheckedOnTheWire(StrategyOp op) => switch (op.toJson()) {
  {
    'type': 'element.patch' || 'lineup.patch',
    'merge': final Map<String, Object?> merge,
  } =>
    !merge.containsKey('base'),
  {'type': 'element.delete' || 'lineup.delete', 'lastWriterWins': true} => true,
  _ => false,
};

Map<(Target, String), String> fieldsOf(StrategyRowSet rows) => {
  for (final (target, row) in [
    for (final row in rows.elements)
      (ElementTarget(row.publicId) as Target, row),
    for (final row in rows.lineupGroups) (LineupTarget(row.publicId), row),
  ]) ...{
    (target, '*'): '${row.runtimeType}',
    if (row.toJson() case {
      'payload': {'data': final Map<String, Object?> data},
    })
      for (final MapEntry(:key, :value) in data.entries)
        (target, key): '$value',
  },
};

Map<Target, int> revisionsOf(StrategyRowSet rows) => {
  const StrategyTarget(): rows.strategy.revision,
  for (final page in rows.pages)
    PageTarget(page.publicId): ?revisionOfRowForTest(page),
  for (final settings in rows.settings)
    SettingsTarget(settings.pagePublicId): ?revisionOfRowForTest(settings),
  for (final row in rows.elements)
    ElementTarget(row.publicId): ?revisionOfRowForTest(row),
  for (final row in rows.lineupGroups)
    LineupTarget(row.publicId): ?revisionOfRowForTest(row),
};

Row? rowOf(StrategyRows rows, Target target) => switch (target) {
  StrategyTarget() => rows.strategy,
  PageTarget(:final pagePublicId) => rows.page(pagePublicId),
  SettingsTarget(:final pagePublicId) => rows.settingsOf(pagePublicId),
  ElementTarget(:final elementPublicId) => rows.element(elementPublicId),
  LineupTarget(:final lineupPublicId) => rows.lineupGroup(lineupPublicId),
};
