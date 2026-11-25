import 'package:collection/collection.dart';
import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'package:icarus_library/src/cloud/op_facts.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';

sealed class Fact {
  Fact(this.label, {this.phase = 0});

  final String label;
  final int phase;
}

final class EventFact extends Fact {
  EventFact(this.event, super.label, {super.phase});

  final QueueEvent event;
}

final class ReadFact extends Fact {
  ReadFact(this.base, super.label, {super.phase});

  final ArrivedBase base;
  late final int session;
  late final ResultSource from;
}

final class ClockFact extends Fact {
  ClockFact(this.by, super.label);

  final Duration by;
}

final class ClaimFact extends Fact {
  ClaimFact() : super('claim between deliveries');
}

final class Scenario {
  Scenario(this.seed) : random = Random(seed);

  final int seed;
  final Random random;
  final client = Client();
  final model = Server();
  final open = <(int, List<StrategyOp>)>[];
  final facts = <Fact>[];
  final log = <String>[];
  int nextId = 0;

  String fresh(String prefix) => '$prefix${nextId++}';

  StrategyRowSet get server => model.rows;

  set server(StrategyRowSet rows) => model.rows = rows;

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];

  StrategyOp? editOp() {
    final rows = client.visible;
    final live = [
      for (final row in rows.elements)
        if (row case LiveElement(
          :final pagePublicId,
        ) when rows.page(pagePublicId) is LivePage)
          row,
    ];
    final pages = [
      for (final page in rows.pages)
        if (page is LivePage) page.publicId,
    ];
    final opId = fresh('op');
    return switch (random.nextInt(9)) {
      < 3 when live.isNotEmpty => () {
        final target = pick(live);
        return movePatch(
          opId,
          elementId: target.publicId,
          expected: target.revision,
          x: random.nextInt(100).toDouble(),
        );
      }(),
      3 when live.isNotEmpty => () {
        final target = pick(live);
        return elementDelete(
          opId,
          elementId: target.publicId,
          pageId: target.pagePublicId,
          expected: target.revision,
        );
      }(),
      4 when pages.isNotEmpty => elementAdd(
        opId,
        elementId: fresh('e'),
        pageId: pick(pages),
      ),
      5 when pages.length < 4 => pageAdd(
        opId,
        fresh('page-'),
        expected: rows.strategy.revision,
        copyFrom: random.nextBool() ? pick(pages) : null,
        sortIndex: pages.length,
      ),
      7 when pages.isNotEmpty => () {
        final page = rows.page(pick(pages))! as LivePage;
        return PagePatchOp(
          opId: opId,
          pagePublicId: page.publicId,
          expectedPageRevision: page.revision,
          name: 'Renamed ${random.nextInt(9)}',
        );
      }(),
      6 when pages.length > 2 => pageDelete(
        opId,
        pick(pages),
        expected: rows.strategy.revision,
      ),
      _ => null,
    };
  }

  void edit() {
    final op = editOp();
    if (op == null) return;
    if (applyOp(client.visible, onVisible(client.visible, op)) is! OpApplied) {
      return;
    }
    final ops = switch (op) {
      PageAddOp(copyContentFromPagePublicId: _?) => switch (expandCopy(
        client.visible,
        op,
      )) {
        CopyExpanded(:final ops) => ops,
        CopyNotExpanded() => const <StrategyOp>[],
      },
      _ => [op],
    };
    for (final each in ops) {
      if (client.step(client.editEvent(each)) is Stepped) log.add('edit $each');
    }
  }

  void claim() {
    final views = entryViews(client.queue, now);
    final ids = [
      for (final entry in client.queue.entries)
        if (views[entry.id]?.sendable ?? false) entry.id,
    ].take(3).toList();
    if (ids.isEmpty) return;
    final attempt = client.claim(ids);
    open.add((attempt, client.lastSent()));
    log.add('claim $attempt $ids');
  }

  List<EventFact> answersFor((int, List<StrategyOp>) sent) => [
    for (final op in sent.$2)
      EventFact(
        OpAnswered(sent.$1, model.apply(clientId, op)),
        'answer ${op.opId}',
      ),
  ];

  void deliverNow() {
    if (open.isEmpty) return;
    final sent = open.removeAt(0);
    for (final fact in answersFor(sent)) {
      client.must(fact.event);
    }
    log.add('answered ${sent.$1}');
  }

  void teammate() {
    final live = [
      for (final row in server.elements)
        if (row is LiveElement) row,
    ];
    if (live.isEmpty) return;
    final target = pick(live);
    final op = movePatch(
      fresh('t'),
      elementId: target.publicId,
      expected: target.revision,
      rotation: 45,
    );
    if (applyOp(server, op) case final OpApplied done) {
      server = server.withRows(done.rows);
      log.add('teammate moves ${target.publicId}');
    }
  }

  ReadFact headerRead({int phase = 0}) => ReadFact(
    headerReadOf(server),
    'read strategy at ${server.strategy.revision}',
    phase: phase,
  );

  ReadFact pageRead(String pageId, {int phase = 0}) =>
      ReadFact(pageReadOf(server, pageId), 'read $pageId', phase: phase);

  void teammateDeletesAndRestoresAPage() {
    final pages = [
      for (final page in server.pages)
        if (page is LivePage) page.publicId,
    ];
    if (pages.length < 2) return;
    final page = pick(pages);
    final before = server;
    server = withOp(
      server,
      pageDelete(fresh('t'), page, expected: server.strategy.revision),
    );
    facts.add(pageRead(page));
    if (random.nextBool()) facts.add(headerRead());
    final live = before.page(page)! as LivePage;
    server = server.withRows([
      LivePage(
        publicId: live.publicId,
        strategyPublicId: live.strategyPublicId,
        name: live.name,
        sortIndex: live.sortIndex,
        isAttack: live.isAttack,
        isAutoNamed: live.isAutoNamed,
        revision: revisionOfRow(server.page(page)!)!,
        unknownFields: live.unknownFields,
      ),
    ]);
    facts.add(pageRead(page));
  }

  void prefix(int steps) {
    for (var i = 0; i < steps; i++) {
      switch (random.nextInt(6)) {
        case < 2:
          edit();
        case 2:
          claim();
        case 3:
          deliverNow();
        case 4:
          client.read(server);
        case _:
          if (seed.isOdd) teammate();
      }
    }
  }

  void gatherFacts(int most) {
    claim();
    while (open.isNotEmpty && facts.length < most) {
      final sent = open.removeAt(0);
      switch (random.nextInt(7)) {
        case 0:
          facts.add(
            EventFact(
              BatchRefused(sent.$1, BatchRefusal.editAccessRemoved),
              'access refused ${sent.$1}',
            ),
          );
          facts.add(
            EventFact(
              EditAccessConfirmed(afterAttempt: sent.$1),
              'access confirmed after ${sent.$1}',
            ),
          );
        case 1:
          facts.add(
            EventFact(
              BatchRefused(sent.$1, BatchRefusal.upgradeRequired),
              'upgrade ${sent.$1}',
            ),
          );
        case 2:
          facts.add(
            EventFact(
              TransportFailed(sent.$1, TransportFailure.timeout, at: now),
              'transport failed ${sent.$1}',
            ),
          );
        case _:
          facts.addAll(answersFor(sent));
      }
      if (random.nextBool()) facts.add(headerRead());
      for (final page in server.pages) {
        if (random.nextInt(3) == 0) facts.add(pageRead(page.publicId));
      }
    }
    switch (random.nextInt(6)) {
      case 0:
        facts.add(
          EventFact(
            BaseArrived(
              const StrategyGone(),
              session: client.queue.session.number,
              from: readFrom(client.queue),
            ),
            'strategy gone',
          ),
        );
      case 1:
        teammateDeletesAndRestoresAPage();
      case 2:
        facts.add(ReadFact(PageGone(pick(['page-a', 'page-b'])), 'page gone'));
      case _:
        break;
    }
    switch (random.nextInt(4)) {
      case 0:
        facts.add(ClockFact(const Duration(hours: 1), '+1h'));
      case 1:
        facts.add(ClockFact(serverRemembersAnswersFor, '+30 days'));
      case _:
        break;
    }
    if (random.nextInt(3) == 0) facts.add(ClaimFact());
    if (facts.length > most) facts.removeRange(most, facts.length);
    if (random.nextBool()) {
      facts.add(
        EventFact(const AppRestarted(build: build), 'restart', phase: 1),
      );
      if (server.pages.isNotEmpty) {
        facts.add(pageRead(server.pages.first.publicId, phase: 2));
        facts.add(headerRead(phase: 2));
      }
    }
    for (final fact in facts) {
      if (fact is ReadFact) {
        fact.session = fact.phase == 2
            ? client.queue.nextSession
            : client.queue.session.number;
        fact.from = ReadOfThisDevice(
          fact.phase == 2
              ? ReadStart(session: fact.session, sequence: 0)
              : client.queue.session.readStart,
        );
      }
    }
  }
}

Iterable<List<Fact>> orderings(List<Fact> facts) sync* {
  final used = List.filled(facts.length, false);
  final chosen = <Fact>[];
  bool allowed(int index) {
    for (var other = 0; other < facts.length; other++) {
      if (!used[other] && facts[other].phase < facts[index].phase) return false;
      if (!used[other] &&
          other < index &&
          facts[other] is ReadFact &&
          facts[index] is ReadFact) {
        return false;
      }
      if (!used[other] &&
          other < index &&
          facts[other] is ReadFact &&
          switch (facts[index]) {
            EventFact(event: OpAnswered()) => true,
            _ => false,
          }) {
        return false;
      }
      if (!used[other] &&
          facts[index] is ClockFact &&
          switch (facts[other]) {
            EventFact(event: BatchRefused()) => true,
            _ => false,
          }) {
        return false;
      }
    }
    return true;
  }

  Iterable<List<Fact>> go() sync* {
    if (chosen.length == facts.length) {
      yield [...chosen];
      return;
    }
    for (var i = 0; i < facts.length; i++) {
      if (used[i] || !allowed(i)) continue;
      used[i] = true;
      chosen.add(facts[i]);
      yield* go();
      chosen.removeLast();
      used[i] = false;
    }
  }

  yield* go();
}

final class Delivered {
  Delivered(this.queue, this.at, this.effects, this.server);

  final CloudQueue queue;
  final DateTime at;
  final List<String> effects;
  final Server server;
}

Delivered deliver(CloudQueue start, List<Fact> order, Server model) {
  var queue = start;
  var at = now;
  final server = model.copy();
  final effects = <String>[];
  List<QueueEffect> step(QueueEvent event) {
    if (transition(queue, event, now: at) case Stepped(
      queue: final next,
      effects: final made,
    )) {
      queue = next;
      effects.addAll([for (final effect in made) '$effect']);
      return made;
    }
    return const [];
  }

  final lastDelivered = <String?, ArrivedBase>{};
  String? subjectOf(ArrivedBase base) => switch (base) {
    PageRead(:final page) => page.publicId,
    PageGone(:final pagePublicId) => pagePublicId,
    _ => null,
  };
  for (final fact in order) {
    switch (fact) {
      case EventFact(:final event):
        step(event);
      case ReadFact(:final base, :final session, :final from):
        if (base is! StrategyGone) lastDelivered[subjectOf(base)] = base;
        step(BaseArrived(base, session: session, from: from));
      case ClockFact(:final by):
        at = at.add(by);
      case ClaimFact():
        final views = entryViews(queue, at);
        final ids = [
          for (final entry in queue.entries)
            if (views[entry.id]?.sendable ?? false) entry.id,
        ].take(3).toList();
        if (ids.isEmpty) break;
        final made = step(BatchClaimed(clientId: clientId, opIds: ids, at: at));
        for (final sent in made.whereType<SendBatch>()) {
          for (final op in sent.ops) {
            if (server.firstClient.containsKey(op.opId) &&
                !at.isBefore(now.add(serverRemembersAnswersFor))) {
              throw StateError(
                '${op.opId} was sent again after the server forgot it',
              );
            }
            step(OpAnswered(sent.attempt, server.apply(sent.clientId, op)));
          }
        }
    }
  }
  queue = look(queue, at).queue;
  for (final entry in lastDelivered.entries.toList()) {
    final page = entry.key;
    final ArrivedBase current = page == null
        ? headerReadOf(server.rows)
        : pageReadOf(server.rows, page);
    if (!const DeepCollectionEquality().equals(
      describeBase(current),
      describeBase(entry.value),
    )) {
      step(
        BaseArrived(
          current,
          session: queue.session.number,
          from: readFrom(queue),
        ),
      );
    }
  }
  for (var round = 0; ; round++) {
    final asked = resultsNeeded(queue, at);
    if (asked.isEmpty) break;
    if (round == 5) {
      throw StateError('still asking for $asked after five fetches');
    }
    for (final subject in asked) {
      final page = switch (subject) {
        PageListResult() => null,
        PageResult(:final page) => page,
        RowResult(
          target: StrategyTarget() || PageTarget() || SettingsTarget(),
        ) =>
          null,
        RowResult(:final page?) => page,
        RowResult(:final target) => switch (target) {
          ElementTarget(:final elementPublicId) =>
            server.rows.element(elementPublicId)?.pagePublicId,
          LineupTarget(:final lineupPublicId) =>
            server.rows.lineupGroup(lineupPublicId)?.pagePublicId,
          _ => null,
        },
      };
      step(
        BaseArrived(
          page == null
              ? headerReadOf(server.rows)
              : pageReadOf(server.rows, page),
          session: queue.session.number,
          from: readFrom(queue),
        ),
      );
    }
  }
  final views = entryViews(queue, at);
  for (final entry in queue.entries) {
    final view = views[entry.id]!;
    if (view.state case Waiting() || Unanswered()
        when view.holds.isEmpty && !view.sendable) {
      throw StateError('${entry.id} waits with nothing asked for');
    }
  }
  step(const ConnectionLost());
  return Delivered(queue, at, effects..sort(), server);
}

String? disagreement(Delivered end) {
  final views = entryViews(end.queue, end.at);
  for (final entry in end.queue.entries) {
    final state = views[entry.id]?.state;
    final wrong = switch (state) {
      Waiting() ||
      NeedsUser(reason: RefusedByServer()) => end.server.landed(entry.id),
      _ => false,
    };
    if (wrong) return '${entry.id} is $state but the server says otherwise';
  }
  return null;
}

Object describeBase(ArrivedBase base) => switch (base) {
  HeaderRead(:final strategy, :final pages, :final settings) => [
    strategy.toJson(),
    for (final page in pages) page.toJson(),
    for (final row in settings) row.toJson(),
  ],
  PageRead(:final page, :final elements, :final lineupGroups) => [
    page.toJson(),
    for (final row in elements) row.toJson(),
    for (final row in lineupGroups) row.toJson(),
  ],
  PageGone(:final pagePublicId) => 'gone $pagePublicId',
  StrategyGone() => 'strategy gone',
};

bool sameApartFromResults(CloudQueue a, CloudQueue b) {
  CloudQueue plain(CloudQueue queue) => CloudQueue(
    entries: queue.entries,
    attempts: queue.attempts,
    landed: [
      for (final work in queue.landed)
        LandedWork(
          attempt: work.attempt,
          position: work.position,
          op: work.op,
          revision: work.revision,
          life: work.life,
          shape: work.shape,
          own: work.own,
          firstSentAt: work.firstSentAt,
          produced: work.produced,
          movedRow: work.movedRow,
          shownWithout: work.shownWithout,
          answeredAt: ReadStart.beforeAnyRead,
        ),
    ],
    nextAttempt: queue.nextAttempt,
    nextSession: queue.nextSession,
    shown: Shown.nothing,
    strategy: queue.strategy,
    session: QueueSession(
      connected: queue.session.connected,
      build: queue.session.build,
      number: queue.session.number,
      sequence: 0,
      basis: queue.session.basis,
    ),
  );
  return plain(a) == plain(b);
}

String describe(CloudQueue queue, DateTime at) {
  final views = entryViews(queue, at);
  return [
    for (final entry in queue.entries)
      '${entry.id}: ${views[entry.id]?.state} ${views[entry.id]?.sendable} ${views[entry.id]?.holds}',
    'standing ${standingOf(queue).name}',
    'attempts ${queue.attempts.values}',
    'landed ${queue.landed}',
  ].join('\n');
}

void main() {
  final seeds =
      int.tryParse(Platform.environment['CLOUD_PERMUTATION_SEEDS'] ?? '') ?? 80;
  final one = int.tryParse(
    Platform.environment['CLOUD_PERMUTATION_SEED'] ?? '',
  );
  test('every causal order of the same facts ends in the same queue, and a '
      'claim between deliveries never disagrees with the server', () {
    var orders = 0;
    var factsSeen = 0;
    var claimed = 0;
    for (final seed
        in one == null ? [for (var s = 1; s <= seeds; s++) s] : [one]) {
      final scenario = Scenario(seed)..prefix(40);
      scenario.gatherFacts(6);
      final start = scenario.client.queue;
      final facts = scenario.facts;
      factsSeen += facts.length;
      Delivered? first;
      List<Fact>? firstOrder;
      for (final order in orderings(facts)) {
        orders++;
        final Delivered end;
        try {
          end = deliver(start, order, scenario.model);
        } on StateError catch (error) {
          fail(
            'seed $seed: ${error.message}\n'
            'order: ${order.map((f) => f.label).join(' | ')}',
          );
        }
        if (disagreement(end) case final problem?) {
          fail(
            'seed $seed: $problem\n'
            'order: ${order.map((f) => f.label).join(' | ')}\n'
            '${describe(end.queue, end.at)}',
          );
        }
        if (facts.any((fact) => fact is ClaimFact)) {
          claimed++;
          continue;
        }
        if (first == null) {
          first = end;
          firstOrder = order;
          continue;
        }
        if (!sameApartFromResults(end.queue, first.queue) ||
            describe(end.queue, end.at) != describe(first.queue, first.at) ||
            end.effects.join('\n') != first.effects.join('\n')) {
          fail(
            'seed $seed: two orders of the same facts disagree\n'
            'prefix:\n${scenario.log.join('\n')}\n'
            'first order: ${firstOrder!.map((f) => f.label).join(' | ')}\n'
            '${describe(first.queue, first.at)}\n${first.effects}\n'
            'other order: ${order.map((f) => f.label).join(' | ')}\n'
            '${describe(end.queue, end.at)}\n${end.effects}',
          );
        }
      }
    }
    printOnFailure('$orders orders of $factsSeen facts');
    if (Platform.environment['CLOUD_PERMUTATION_COUNTS'] == '1') {
      stdout.writeln('$orders orders of $factsSeen facts');
    }
    if (one != null) return;
    expect(orders, greaterThan(seeds * 20));
    expect(claimed, greaterThan(seeds));
  });
}
