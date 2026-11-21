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

int? revisionAt(StrategyRowSet rows, Target target) => switch (target) {
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

final class ServerModel {
  ServerModel(this.rows);

  StrategyRowSet rows;
  bool exists = true;
  int version = 0;
  final landedAt = <String, int>{};
  final recorded = <String, Recorded>{};
  final firstSent = <String, (String, String)>{};
  int received = 0;
  int sends = 0;

  OpAnswer apply(String clientId, StrategyOp op) {
    sends++;
    final sent = jsonEncode(op.toJson());
    final first = firstSent.putIfAbsent(op.opId, () {
      received++;
      return (clientId, sent);
    });
    if (first.$1 != clientId) {
      throw StateError('${op.opId} was sent under ${first.$1} and $clientId');
    }
    final key = '$clientId|${op.opId}';
    switch (recorded[key]) {
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
        final revision = revisionAt(rows, targetOf(op))!;
        answer = AppliedAnswer(op.opId, revision: revision);
        record = RecordedApplied(revision);
        landedAt[op.opId] = version;
      case OpUnchanged():
        final revision = revisionAt(rows, targetOf(op));
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
    recorded[key] = record;
    return answer;
  }

  Recorded? recordOf(String opId) {
    final first = firstSent[opId];
    return first == null ? null : recorded['${first.$1}|$opId'];
  }
}

StrategyRowSet visible(StrategyRowSet base, CloudQueue queue) {
  var rows = base;
  for (final entry in queue.entries) {
    if (entry case PendingOp(op: final sent, :final state)) {
      final StrategyOp op;
      switch ((sent, state)) {
        case (
          PageAddOp(copyContentFromPagePublicId: _?),
          Accepted(awaiting: AwaitingCopy(seen: CopySeen.strategyOnly)),
        ):
          continue;
        case (final PageAddOp add, Accepted(awaiting: AwaitingCopy())):
          op = PageAddOp(
            opId: add.opId,
            pagePublicId: add.pagePublicId,
            sortIndex: add.sortIndex,
            expectedStrategyRevision: add.expectedStrategyRevision,
            name: add.name,
            isAutoNamed: add.isAutoNamed,
            isAttack: add.isAttack,
            settings: add.settings,
          );
        case _:
          op = sent;
      }
      if (applyOp(rows, op) case final OpApplied applied) {
        rows = rows.withRows(applied.rows);
      }
    }
  }
  return rows;
}

String describeDifference(StrategyRowSet shown, StrategyRowSet server) {
  final a = {for (final row in shown.rows) row.key: row};
  final b = {for (final row in server.rows) row.key: row};
  return [
    for (final key in {...a.keys, ...b.keys})
      if (a[key] != b[key]) '$key: ${a[key]?.toJson()} vs ${b[key]?.toJson()}',
  ].join('; ');
}

final reached = <String, int>{};

void count(String what, [int by = 1]) =>
    reached[what] = (reached[what] ?? 0) + by;

final class Model {
  Model(this.seed, {required this.teammates, required this.folding})
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
  final bool folding;
  final Random random;
  final ServerModel server;
  StrategyRowSet base;
  final rowSeenAt = <Target, int>{};
  CloudQueue queue = CloudQueue.empty;
  DateTime clock = now;
  String client = 'client-0';
  int restarts = 0;
  String openPage = 'page-a';
  final inFlight = <(Attempt, List<StrategyOp>)>[];
  final late = <(Attempt, OpAnswer)>[];
  final log = <String>[];
  bool teammateEdited = false;
  bool droppedLandedWork = false;
  bool draining = false;
  int nextId = 0;

  String fresh(String prefix) => '$prefix${nextId++}';

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];

  Step apply(QueueEvent event, String label) {
    final before = queue;
    var result = transition(queue, event, now: clock);
    if (!folding) result = unfolded(before, event, result);
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
        throw StateError(
          'refused with no teammate editing: ${switch (event.answer) {
            RejectedAnswer(:final opId, :final reason) => '$opId ${reason.wireName}',
            FailedAnswer(:final opId, :final code) => '$opId $code',
            _ => '',
          }}',
        );
      }
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

  Step unfolded(CloudQueue before, QueueEvent event, Step result) {
    if (event case UserEdited(:final edit)) {
      if (result case Stepped(:final effects)
          when effects.any(
            (effect) =>
                effect is OpRemoved &&
                (effect.cause is FoldedInto || effect.cause is CancelledBy),
          )) {
        final target = targetOf(edit.op);
        final last = before.entries.lastWhere(
          (entry) => entry is PendingOp && targetOf(entry.op) == target,
        );
        return Stepped(
          CloudQueue(
            entries: [
              ...before.entries,
              PendingOp(
                place: before.entries.last.place + 1,
                work: OpWork(edit.op),
                scope: edit.scope,
                against: StackedOn(last.id, expectedOf(edit.op)),
                policy: before.session.connected
                    ? SendPolicy.live
                    : SendPolicy.checked,
                wait: const NoWait(),
                state: const Unsent(NeverSent(), Free()),
              ),
            ],
            standing: before.standing,
            session: before.session,
          ),
          const [],
        );
      }
    }
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
      final still = waiting.where(
        (id) => switch (queue.entry(id)) {
          PendingOp(state: Claimed()) => true,
          _ => false,
        },
      );
      if (event is! OpAnswered && still.isNotEmpty) {
        throw StateError('$label did not apply though $still wait for it');
      }
    }
  }

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
      if (cause == null) {
        throw StateError('${entry.id} disappeared with no removal');
      }
      final target = entry is PendingOp ? targetOf(entry.op) : null;
      final fits = switch (cause) {
        SeenInBase() =>
          entry is PendingOp &&
              (rowSeenAt[target] ?? 0) >= (server.landedAt[entry.id] ?? 0) &&
              switch (server.recordOf(entry.id)) {
                RecordedApplied() || RecordedNoop() => true,
                RecordedRefusal() || null => false,
              },
        NothingToWaitFor() =>
          event is OpAnswered && event.answer is NoopWithoutRevision,
        SettledByRemoval() =>
          event is BaseArrived ||
              (event is BatchRefused &&
                  event.refusal == BatchRefusal.strategyDeleted),
        FoldedInto(:final opId) || CancelledBy(:final opId) =>
          event is UserEdited &&
              event.edit.op.opId == opId &&
              entry is PendingOp &&
              entry.state == const Unsent(NeverSent(), Free()),
        RetriedUnder() => event is PageRestored,
        RemovedByUser(:final landing) =>
          event is UserAction &&
              event.opId == entry.id &&
              landing == landingOf(entry),
      };
      if (!fits) {
        throw StateError('${entry.id} was removed for $cause after $event');
      }
      if (cause is RemovedByUser &&
          server.recordOf(entry.id) is RecordedApplied) {
        droppedLandedWork = true;
      }
    }
  }

  void checkStates() {
    for (final entry in queue.entries) {
      if (entry is! PendingOp) continue;
      final record = server.recordOf(entry.id);
      final fits = switch ((record, entry.state)) {
        (RecordedApplied() || RecordedNoop(), Unsent(delivery: NeverSent())) ||
        (RecordedApplied() || RecordedNoop(), ServerRefused()) => false,
        (RecordedRefusal(), Unsent(delivery: NeverSent())) ||
        (RecordedRefusal(), Accepted()) => false,
        (null, Accepted() || ServerRefused()) => false,
        _ => true,
      };
      if (!fits) {
        throw StateError('${entry.id} is ${entry.state}, server has $record');
      }
    }
    final state = syncStateOf(
      Tally.of(queue),
      network: Network.online,
      signedIn: SignedIn.thisAccount,
    );
    if ((state is AllSaved) != queue.entries.isEmpty) {
      throw StateError('the sync state is $state with ${queue.entries}');
    }
    final allAccepted = queue.entries.every(
      (entry) =>
          entry is PendingOp &&
          entry.state is Accepted &&
          (entry.state as Accepted).awaiting is AwaitingRow,
    );
    if (!teammateEdited &&
        !droppedLandedWork &&
        allAccepted &&
        queue.entries.isNotEmpty) {
      count('prediction checked');
      final shown = visible(base, queue);
      if (shown != server.rows) {
        throw StateError(
          'with every op accepted, the user sees other rows: '
          '${describeDifference(shown, server.rows)}',
        );
      }
    }
  }

  StrategyOp? editOp() {
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
    final choice = random.nextInt(20);
    if (choice < 8 && live.isNotEmpty) {
      final target = pick(live);
      final merged = random.nextInt(3) == 0;
      return ElementPatchOp(
        opId: opId,
        elementPublicId: target.publicId,
        expectedElementRevision: target.revision,
        payload: agentPayload(target.publicId, {
          'position': {'dx': random.nextInt(1000), 'dy': 0},
        }),
        merge: merged
            ? FieldMerge(
                fields: ['position'],
                base: {'position': target.payload.data['position']},
              )
            : null,
      );
    }
    if (choice < 11 && live.isNotEmpty) {
      final target = pick(live);
      return elementDelete(
        opId,
        elementId: target.publicId,
        pageId: target.pagePublicId,
        expected: target.revision,
      );
    }
    if (choice < 14 && livePages.isNotEmpty) {
      return elementAdd(opId, elementId: fresh('e'), pageId: pick(livePages));
    }
    if (choice == 14 && livePages.length < 5) {
      return PageAddOp(
        opId: opId,
        pagePublicId: fresh('page-'),
        sortIndex: livePages.length,
        expectedStrategyRevision: rows.strategy.revision,
        name: 'Page',
        copyContentFromPagePublicId: random.nextBool() ? pick(livePages) : null,
      );
    }
    if (choice == 15 && livePages.length > 1) {
      return PageReorderOp(
        opId: opId,
        pagePublicId: pick(livePages),
        sortIndex: random.nextInt(livePages.length),
        expectedStrategyRevision: rows.strategy.revision,
      );
    }
    if (choice == 16 && livePages.isNotEmpty) {
      final target = rows.page(pick(livePages))! as LivePage;
      return PagePatchOp(
        opId: opId,
        pagePublicId: target.publicId,
        expectedPageRevision: target.revision,
        name: 'Renamed ${random.nextInt(100)}',
      );
    }
    if (choice == 17 && livePages.length > 2) {
      return pageDelete(
        opId,
        pick(livePages),
        expected: rows.strategy.revision,
      );
    }
    return null;
  }

  SeenPage? seenFor(String pageId) {
    for (final entry in queue.entries) {
      if (entry case PendingOp(
        op: PageAddOp(:final pagePublicId, copyContentFromPagePublicId: _?),
      ) when pagePublicId == pageId) {
        return null;
      }
    }
    final rows = visible(base, queue);
    if (rows.page(pageId) case final LivePage page) {
      if (!rowSeenAt.containsKey(SettingsTarget(pageId))) return null;
      return SeenPage(
        name: page.name,
        isAttack: page.isAttack,
        content: ContentSeen({
          if (rows.settingsOf(pageId) case ReadablePageSettings(
            :final revision,
          ))
            const SeenSettings(): revision,
          for (final row in rows.elementsOn(pageId))
            if (row case LiveElement(:final publicId, :final revision))
              SeenElement(publicId): revision,
        }),
      );
    }
    return null;
  }

  void edit() {
    final op = editOp();
    if (op == null) return;
    if (applyOp(visible(base, queue), op) is! OpApplied) return;
    final QueueEvent event;
    if (op case PageDeleteOp(:final pagePublicId)) {
      final seen = seenFor(pagePublicId);
      if (seen == null) return;
      event = UserEdited(PageDeleteEdit(op, seen));
    } else {
      final rowPage = switch (op) {
        ElementPatchOp(:final elementPublicId) => visible(
          base,
          queue,
        ).element(elementPublicId)!.pagePublicId,
        _ => null,
      };
      event = UserEdited(switch (editOf(op, rowPage: rowPage)) {
        EditMade(:final edit) => edit,
        NeedsRowPage() => throw StateError('no page for ${op.opId}'),
      });
    }
    mustApply(
      event,
      'edit ${op.opId} ${op.type.wireName} ${targetOf(op)} ${pagesNeeded(op)}',
    );
  }

  void claim() {
    if (queue.standing != Standing.good) return;
    final holds = holdsOf(queue, clock);
    String? batchClient;
    final ids = <String>[];
    final ops = <StrategyOp>[];
    for (final entry in queue.entries) {
      if (ids.length == 4) break;
      if (entry case PendingOp(state: Unsent(go: Free(), :final delivery))) {
        if (entry.work case CheckedDelete(verdict: HeldForUser())) continue;
        if (delivery case AnswerUnknown(
          retry: RetriesExhausted() || ServerForgotAnswer(),
        )) {
          continue;
        }
        final owner = switch (delivery) {
          AnswerUnknown(:final clientId) => clientId,
          NeverSent() => batchClient ?? client,
        };
        if (batchClient != null && owner != batchClient) continue;
        final blocking = (holds[entry.id] ?? const <Hold>[]).where(
          (hold) => !(hold is BehindPageWork && hold.opIds.every(ids.contains)),
        );
        if (blocking.isNotEmpty) continue;
        batchClient = owner;
        ids.add(entry.id);
        ops.add(sendForm(entry.op, entry.policy));
      }
    }
    if (ids.isEmpty) return;
    final attempt = Attempt(fresh('try'), clientId: batchClient!, at: clock);
    mustApply(BatchClaimed(attempt, ids), 'claim $ids as ${attempt.clientId}');
    inFlight.add((attempt, ops));
  }

  BaseRow baseRowFor(String opId) {
    final entry = queue.entry(opId);
    if (entry is! PendingOp) return const BaseLacks();
    return switch (revisionAt(base, targetOf(entry.op))) {
      final revision? => BaseHolds(revision),
      null => const BaseLacks(),
    };
  }

  void deliver({required bool reliable}) {
    if (inFlight.isEmpty) return;
    final (attempt, sent) = inFlight.removeAt(random.nextInt(inFlight.length));
    final ids = [for (final op in sent) op.opId];
    final roll = reliable ? 0 : random.nextInt(12);
    if (!server.exists) {
      settle(
        BatchRefused(attempt.id, BatchRefusal.strategyDeleted),
        'refused whole: strategy deleted',
        ids,
      );
      return;
    }
    if (roll == 11) {
      settle(
        TransportFailed(attempt.id, TransportFailure.network, at: clock),
        'lost before the server $ids',
        ids,
      );
      return;
    }
    if (roll == 10) {
      final refusal = pick(const [
        BatchRefusal.upgradeRequired,
        BatchRefusal.unauthenticated,
        BatchRefusal.editAccessRemoved,
      ]);
      settle(
        BatchRefused(attempt.id, refusal),
        'refused whole: ${refusal.name}',
        ids,
      );
      return;
    }
    final answers = [for (final op in sent) server.apply(attempt.clientId, op)];
    if (roll == 9) {
      settle(
        TransportFailed(attempt.id, TransportFailure.timeout, at: clock),
        'answer timed out $ids',
        ids,
      );
      if (random.nextBool()) {
        late.addAll([for (final answer in answers) (attempt, answer)]);
      }
      return;
    }
    final order = [...answers];
    if (roll == 8) order.shuffle(random);
    for (final answer in order) {
      settle(
        OpAnswered(attempt, answer, base: baseRowFor(answer.opId)),
        'answer for ${answer.opId}',
        [answer.opId],
      );
      if (roll == 7) {
        if (apply(
              OpAnswered(attempt, answer, base: baseRowFor(answer.opId)),
              'duplicate ${answer.opId}',
            )
            is Stepped) {
          throw StateError('a duplicate answer for ${answer.opId} applied');
        }
      }
    }
  }

  void lateAnswer() {
    if (late.isEmpty) return;
    final (attempt, answer) = late.removeAt(random.nextInt(late.length));
    if (apply(
          OpAnswered(attempt, answer, base: baseRowFor(answer.opId)),
          'late answer for ${answer.opId}',
        )
        is Stepped) {
      count('late answer applied');
    }
  }

  void restart() {
    for (final (attempt, sent) in inFlight) {
      if (random.nextBool() && server.exists) {
        for (final op in sent) {
          server.apply(attempt.clientId, op);
        }
      }
    }
    inFlight.clear();
    late.clear();
    client = 'client-${++restarts}';
    mustApply(const AppRestarted(), 'restart as $client');
  }

  void readHeader() {
    if (!server.exists) {
      mustApply(const BaseArrived(StrategyGone()), 'read: strategy gone');
      return;
    }
    final rows = server.rows;
    final kept = {for (final page in rows.pages) page.publicId};
    base = StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: base.elements.where((row) => kept.contains(row.pagePublicId)),
      lineupGroups: base.lineupGroups.where(
        (row) => kept.contains(row.pagePublicId),
      ),
    );
    rowSeenAt[const StrategyTarget()] = server.version;
    for (final page in rows.pages) {
      rowSeenAt[PageTarget(page.publicId)] = server.version;
    }
    for (final row in rows.settings) {
      rowSeenAt[SettingsTarget(row.pagePublicId)] = server.version;
    }
    mustApply(
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
    final rows = server.rows;
    final page = rows.page(pageId);
    if (page == null) {
      base = withoutPage(base, pageId);
      mustApply(BaseArrived(PageGone(pageId)), 'read $pageId: gone');
      return;
    }
    if (base.page(pageId) == null) return;
    final elements = rows.elementsOn(pageId).toList();
    final groups = rows.lineupGroupsOn(pageId).toList();
    base = StrategyRowSet(
      strategy: base.strategy,
      pages: base.pages,
      settings: base.settings,
      elements: [
        ...base.elements.where((row) => row.pagePublicId != pageId),
        ...elements,
      ],
      lineupGroups: [
        ...base.lineupGroups.where((row) => row.pagePublicId != pageId),
        ...groups,
      ],
    );
    for (final row in elements) {
      rowSeenAt[ElementTarget(row.publicId)] = server.version;
    }
    mustApply(
      BaseArrived(
        PageRead(
          page: page,
          settings: rows.settingsOf(pageId)!,
          elements: elements,
          lineupGroups: groups,
        ),
      ),
      'read $pageId',
    );
  }

  Set<String> pagesWithAcceptedWork() => {
    for (final entry in queue.entries)
      if (entry case PendingOp(state: Accepted())) ...pagesOf(entry),
  };

  void teammate() {
    if (!server.exists) return;
    final roll = random.nextInt(40);
    if (roll == 0) {
      final trashed = [
        for (final page in server.rows.pages)
          if (page is TrashedPage) page.publicId,
      ];
      if (trashed.isEmpty) return;
      final pageId = pick(trashed);
      server.rows = withoutPage(server.rows, pageId);
      server.version++;
      teammateEdited = true;
      log.add('teammate purges $pageId');
      return;
    }
    if (roll == 1 && random.nextInt(10) == 0) {
      server.exists = false;
      teammateEdited = true;
      log.add('teammate deletes the strategy');
      return;
    }
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

  void userActs(UserAction action) {
    if (!teammates && action is! UserRetried) {
      throw StateError(
        'the user was asked something avoidable: $action for '
        '${queue.entry(action.opId)}',
      );
    }
    mustApply(action, 'user ${action.runtimeType} ${action.opId}');
  }

  void resolve() {
    for (final entry in queue.entries) {
      switch (entry) {
        case PendingOp(
          state: Unsent(delivery: AnswerUnknown(retry: RetriesExhausted())),
        ):
          userActs(UserRetried(entry.id));
          return;
        case PendingOp() when queue.standing == Standing.deletedOnServer:
          if (entry.state is Claimed || entry.state is Accepted) continue;
          userActs(UserDiscarded(entry.id));
          return;
        case PendingOp(state: ServerRefused(), :final op):
          final replacement = keepMine(op);
          userActs(switch (random.nextInt(3)) {
            0 when replacement != null => UserKeptMine(entry.id, replacement),
            1 => UserUsedCloud(entry.id),
            _ => UserDiscarded(entry.id),
          });
          return;
        case PendingOp(work: CheckedDelete(verdict: HeldForUser())):
          userActs(
            random.nextBool()
                ? UserDeletedAnyway(entry.id)
                : UserDiscarded(entry.id),
          );
          return;
        case PendingOp(state: Unsent(go: NeedsUser())) ||
            PendingOp(
              state: Unsent(
                delivery: AnswerUnknown(retry: ServerForgotAnswer()),
              ),
            ):
          userActs(UserDiscarded(entry.id));
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

  void lane() {
    switch (queue.standing) {
      case Standing.editAccessLost:
        mustApply(const EditAccessConfirmed(), 'access confirmed');
      case Standing.upgradeRequired:
        restart();
      case Standing.good || Standing.deletedOnServer:
        break;
    }
  }

  void stepOnce() {
    clock = clock.add(Duration(milliseconds: random.nextInt(2000)));
    switch (random.nextInt(24)) {
      case < 7:
        edit();
      case < 10:
        claim();
      case < 14:
        deliver(reliable: false);
      case 14:
        restart();
      case 15:
        readHeader();
      case 16:
        readPage(openPage);
      case 17:
        for (final page in pagesWithAcceptedWork()) {
          readPage(page);
        }
      case 18:
        if (teammates) teammate();
      case 19:
        resolve();
      case 20:
        lateAnswer();
      case 21:
        final pages = [for (final page in base.pages) page.publicId];
        if (pages.isNotEmpty) openPage = pick(pages);
      case 22:
        lane();
      case _:
        mustApply(
          random.nextBool()
              ? const ConnectionLost()
              : const ConnectionReturned(),
          'connection',
        );
    }
  }

  void drain() {
    draining = true;
    for (var round = 0; round < 400 && queue.entries.isNotEmpty; round++) {
      clock = clock.add(const Duration(minutes: 1));
      lane();
      resolve();
      claim();
      while (inFlight.isNotEmpty) {
        deliver(reliable: true);
      }
      readHeader();
      readPage(openPage);
      for (final page in pagesWithAcceptedWork()) {
        readPage(page);
      }
      for (final entry in queue.entries) {
        if (entry case PendingOp(work: CheckedDelete(:final op))) {
          readPage(op.pagePublicId);
        }
      }
    }
    if (queue.entries.isNotEmpty) {
      throw StateError('the queue did not drain: ${queue.entries}');
    }
    if (server.exists && visible(base, queue) != server.rows) {
      readHeader();
      for (final page in [...server.rows.pages]) {
        readPage(page.publicId);
      }
      if (visible(base, queue) != server.rows) {
        throw StateError(
          'the drained queue shows other rows than the server: '
          '${describeDifference(visible(base, queue), server.rows)}',
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
    count(
      folding ? 'op sends, folding' : 'op sends, no folding',
      model.server.sends,
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
  'AppliedAnswer': 2000,
  'noop appliedWhenFirstReceived': 100,
  'rejected revision_mismatch': 50,
  'TransportFailed': 300,
  'AppRestarted': 300,
  'BatchRefused': 100,
  'UserKeptMine': 10,
  'UserUsedCloud': 10,
  'UserDiscarded': 10,
  'removed SeenInBase': 2000,
  'removed FoldedInto': 200,
  'removed CancelledBy': 20,
  'removed SettledByRemoval': 1,
  'late answer applied': 20,
  'prediction checked': 100,
};

void main() {
  final environment = Platform.environment;
  final steps = int.tryParse(environment['CLOUD_MODEL_STEPS'] ?? '') ?? 150;
  final one = int.tryParse(environment['CLOUD_MODEL_SEED'] ?? '');
  final seeds = int.tryParse(environment['CLOUD_MODEL_SEEDS'] ?? '') ?? 200;
  test('random interleavings keep every op and end where the server is', () {
    if (one != null) {
      runSeed(one, steps, folding: true);
      runSeed(one, steps, folding: false);
      return;
    }
    for (var seed = 1; seed <= seeds; seed++) {
      runSeed(seed, steps, folding: true);
      runSeed(seed, steps, folding: false);
    }
    if (environment['CLOUD_MODEL_COUNTS'] == '1') {
      for (final MapEntry(:key, :value) in reached.entries) {
        stdout.writeln('$key: $value');
      }
    }
    for (final MapEntry(key: what, value: least) in minimums.entries) {
      expect(reached[what] ?? 0, greaterThanOrEqualTo(least), reason: what);
    }
    expect(
      reached['ops received, folding']!,
      lessThan(reached['ops received, no folding']!),
    );
  });
}
