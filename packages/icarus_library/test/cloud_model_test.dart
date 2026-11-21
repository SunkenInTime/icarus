import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/op_facts.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';
import 'support.dart';

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
  bool jumped = false;
  final seen = <Target, Set<int>>{};
  final produced = <Target, Set<int>>{};

  final seenDigest = <String, String>{};
  final history = <(Target, int), String>{};

  void recordHistory() {
    for (final MapEntry(key: target, value: revision) in revisionsOf(
      server.rows,
    ).entries) {
      final row = rowOf(server.rows, target);
      if (row == null) continue;
      history.putIfAbsent((
        target,
        revision,
      ), () => target is StrategyTarget ? '' : rowDigest(row));
    }
  }

  void checkJustified() {
    for (final work in client.queue.landed) {
      final produced = work.produced;
      if (produced == null) continue;
      final target = targetOf(work.op);
      final truth = history[(target, produced.revision)];
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
    final answer = server.apply(owner, op);
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
      if (event case OpAnswered(
        answer: NoopAnswer(replay: NoopReplay.notApplied),
      )) {
        count('nothing to do at another revision');
      }
      for (final effect in effects) {
        if (effect case OpRemoved(:final cause)) {
          count('removed ${cause.runtimeType}');
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
    return result;
  }

  Step unfolded(CloudQueue before, QueueEvent event, Step result) {
    if ((event, result) case (UserEdited(:final edit), Stepped(:final effects))
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
              refusal: const NotRefused(),
              retriedAfter: before.nextAttempt - 1,
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
        Delivered(how: Delivery.applied) =>
          event is OpAnswered && server.landed(entry.id),
        Delivered() => event is OpAnswered,
        FoldedInto(:final opId) =>
          event is UserEdited && event.edit.op.opId == opId,
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
      if (cause is RemovedByUser) userRemoved = true;
      if (cause is RemovedByUser &&
          event is UserAction &&
          event.opId != entry.id) {
        count('given up with its chain');
      }
    }
  }

  void checkStates() {
    final views = entryViews(client.queue, clock);
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
        Waiting() => server.landed(entry.id) || server.refused(entry.id),
        NeedsUser(reason: RefusedByServer()) => server.landed(entry.id),
        _ => false,
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
      reference = reference.withRows(done.rows);
    }
  }

  void claim() {
    if (standingOf(client.queue) != Standing.good) return;
    final seen = look(client.queue, clock);
    client.queue = seen.queue;
    final views = seen.views;
    String? owner;
    final ids = <String>[];
    for (final entry in client.queue.entries) {
      if (ids.length == 4) break;
      final view = views[entry.id];
      if (view == null || !view.sendable) continue;
      final mine = switch (view.state) {
        Unanswered(:final clientId) => clientId,
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
    final answers = [for (final op in ops) applyOwn(owner, op)];
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
          applyOwn(owner, op);
        }
      }
    }
    inFlight.clear();
    late.clear();
    clientId = 'client-${++restarts}';
    if (random.nextInt(3) == 0) build = 'build-$restarts';
    must(AppRestarted(build: build), 'restart as $clientId on $build');
  }

  void arrive(ArrivedBase base, String label) =>
      must(BaseArrived(base, session: client.queue.session.number), label);

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
    arrive(headerReadOf(rows), 'read strategy');
  }

  void readPage(String pageId) {
    if (!server.exists) return;
    final page = server.rows.page(pageId);
    if (page == null) {
      arrive(PageGone(pageId), 'read $pageId: gone');
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
      },
    for (final work in client.queue.landed) ...[
      ...pagesNeeded(work.op),
      ?pageHolding(targetOf(work.op)),
    ],
  };

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
      case Standing.good || Standing.deletedOnServer || Standing.held:
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
      final livePages = [
        for (final page in server.rows.pages)
          if (page is LivePage) page.publicId,
      ];
      final kind = random.nextInt(10);
      final StrategyOp op = switch (kind) {
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
          pick(livePages),
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
        server.rows = server.rows.withRows(done.rows);
        count('teammate ${op.type.wireName}');
      } else {
        return;
      }
    }
    teammateEdited = true;
    log.add('teammate acts');
  }

  void userActs({required bool draining}) {
    final seen = look(client.queue, clock);
    client.queue = seen.queue;
    final views = seen.views;
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
        (RetiredOp(), _) => UserDiscarded(entry.id),
        _
            when standingOf(client.queue) == Standing.deletedOnServer &&
                view?.state is! Sending =>
          UserDiscarded(entry.id),
        _ => null,
      };
      if (action == null) continue;
      final forgotten = switch ((view?.state, entry)) {
        (NeedsUser(reason: WindowClosed()), _) => true,
        (
          NeedsUser(reason: ChangedUnseen()),
          PendingOp(op: ElementAddOp(expectedElementRevision: _?)),
        ) =>
          jumped,
        _ => false,
      };
      if (forgotten) count('forgotten answers handed to the user');
      final expected = forgotten || userRemoved;
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
    if (jump) jumped = true;
    clock = clock.add(
      jump
          ? serverRemembersAnswersFor + const Duration(hours: 1)
          : Duration(milliseconds: random.nextInt(2000)),
    );
    switch (random.nextInt(22)) {
      case < 6:
        edit();
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
      final views = entryViews(client.queue, clock);
      throw StateError(
        'did not drain: ${[for (final entry in client.queue.entries) '${entry.id} ${views[entry.id]?.state} ${views[entry.id]?.holds}'].join('; ')} '
        'landed ${client.queue.landed}',
      );
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
  'removed Delivered': 1500,
  'removed FoldedInto': 20,
  'put-backs': 100,
  'given up with its chain': 5,
  'nothing to do at another revision': 20,
  'justified rows checked against the server': 100,
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
