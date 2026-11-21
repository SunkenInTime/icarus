import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

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
  late final int read;
}

final class ClockFact extends Fact {
  ClockFact(this.by, super.label);

  final Duration by;
}

OpAnswer answerOn(
  StrategyRowSet rows,
  StrategyOp op,
  void Function(StrategyRowSet) keep,
) {
  switch (applyOp(rows, op)) {
    case final OpApplied done:
      final after = rows.withRows(done.rows);
      keep(after);
      return AppliedAnswer(op.opId, revision: visibleRevision(after, op)!);
    case OpUnchanged():
      final revision = visibleRevision(rows, op);
      return revision == null
          ? NoopWithoutRevision(op.opId)
          : NoopAnswer(
              op.opId,
              revision: revision,
              replay: NoopReplay.notApplied,
            );
    case OpRefused(refusal: Rejected(:final reason)):
      return RejectedAnswer(op.opId, reason, const NoServerCopy());
    case OpRefused(refusal: Failed(:final code)):
      return FailedAnswer(op.opId, KnownFailure(code), code.wireName);
    case OpRefused(refusal: UnreadableTarget(:final key)):
      throw StateError('unreadable $key');
  }
}

final class Scenario {
  Scenario(this.seed) : random = Random(seed);

  final int seed;
  final Random random;
  final client = Client();
  StrategyRowSet server = initialRows();
  final open = <(int, List<StrategyOp>)>[];
  final facts = <Fact>[];
  final log = <String>[];
  int nextId = 0;

  String fresh(String prefix) => '$prefix${nextId++}';

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
    if (client.step(client.editEvent(op)) is Stepped) log.add('edit $op');
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
        OpAnswered(sent.$1, answerOn(server, op, (after) => server = after)),
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
    headerOf(server),
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
    server = before;
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
              read: client.startRead(),
              startedAt: now,
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
    if (random.nextBool()) {
      facts.add(ClockFact(const Duration(hours: 1), '+1h'));
    }
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
      if (fact is ReadFact) fact.read = client.startRead();
    }
  }
}

Iterable<List<Fact>> orderings(List<Fact> facts) sync* {
  final used = List.filled(facts.length, false);
  final chosen = <Fact>[];
  bool allowed(int index) {
    for (var other = 0; other < facts.length; other++) {
      if (!used[other] && facts[other].phase < facts[index].phase) return false;
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
  Delivered(this.queue, this.at, this.effects);

  final CloudQueue queue;
  final DateTime at;
  final List<String> effects;
}

Delivered deliver(CloudQueue start, List<Fact> order) {
  var queue = start;
  var at = now;
  final effects = <String>[];
  void step(QueueEvent event) {
    if (transition(queue, event, now: at) case Stepped(
      queue: final next,
      effects: final made,
    )) {
      queue = next;
      effects.addAll(made.map((effect) => '$effect'));
    }
  }

  for (final fact in order) {
    switch (fact) {
      case EventFact(:final event):
        step(event);
      case ReadFact(:final base, :final read):
        step(BaseArrived(base, read: read, startedAt: now));
      case ClockFact(:final by):
        at = at.add(by);
    }
  }
  return Delivered(queue, at, effects..sort());
}

String describe(CloudQueue queue, DateTime at) {
  final views = entryViews(queue, at);
  return [
    for (final entry in queue.entries)
      '${entry.id}: ${views[entry.id]?.state} ${views[entry.id]?.go} ${views[entry.id]?.holds}',
    'standing ${standingOf(queue).name}',
    'attempts ${queue.attempts.values}',
  ].join('\n');
}

void main() {
  final seeds =
      int.tryParse(Platform.environment['CLOUD_PERMUTATION_SEEDS'] ?? '') ?? 80;
  final one = int.tryParse(
    Platform.environment['CLOUD_PERMUTATION_SEED'] ?? '',
  );
  test('every causal order of the same facts ends in the same queue', () {
    var orders = 0;
    var factsSeen = 0;
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
        final end = deliver(start, order);
        if (first == null) {
          first = end;
          firstOrder = order;
          continue;
        }
        if (end.queue != first.queue ||
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
    expect(orders, greaterThan(seeds * 20));
  });
}
