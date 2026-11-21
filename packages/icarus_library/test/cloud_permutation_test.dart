import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';

final class Fact {
  Fact(this.event, this.label, {this.orderKey});

  final QueueEvent event;
  final String label;
  final String? orderKey;
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
    final views = viewsOf(client.queue, now);
    final ids = [
      for (final entry in client.queue.entries)
        if (views[entry.id]?.sendable ?? false) entry.id,
    ].take(3).toList();
    if (ids.isEmpty) return;
    final attempt = client.claim(ids);
    open.add((attempt, client.lastSent()));
    log.add('claim $attempt $ids');
  }

  List<Fact> answersFor((int, List<StrategyOp>) sent) => [
    for (final op in sent.$2)
      Fact(
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

  Fact headerRead() => Fact(
    BaseArrived(
      HeaderRead(
        strategy: server.strategy,
        pages: server.pages.toList(),
        settings: server.settings.toList(),
      ),
    ),
    'read strategy at ${server.strategy.revision}',
    orderKey: 'header',
  );

  Fact? pageRead(String pageId) => switch (server.page(pageId)) {
    null => null,
    final page => Fact(
      BaseArrived(
        PageRead(
          page: page,
          settings: server.settingsOf(pageId)!,
          elements: server.elementsOn(pageId).toList(),
          lineupGroups: server.lineupGroupsOn(pageId).toList(),
        ),
      ),
      'read $pageId',
      orderKey: pageId,
    ),
  };

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
      switch (random.nextInt(6)) {
        case 0:
          facts.add(
            Fact(
              BatchRefused(sent.$1, BatchRefusal.editAccessRemoved),
              'access refused ${sent.$1}',
            ),
          );
          facts.add(
            Fact(
              EditAccessConfirmed(afterAttempt: sent.$1),
              'access confirmed after ${sent.$1}',
            ),
          );
        case 1:
          facts.add(
            Fact(
              BatchRefused(sent.$1, BatchRefusal.upgradeRequired),
              'upgrade ${sent.$1}',
            ),
          );
        case _:
          facts.addAll(answersFor(sent));
      }
      if (random.nextBool()) facts.add(headerRead());
      for (final page in server.pages) {
        if (random.nextInt(3) == 0) {
          if (pageRead(page.publicId) case final read?) facts.add(read);
        }
      }
    }
    if (random.nextInt(8) == 0) {
      facts.add(Fact(const BaseArrived(StrategyGone()), 'strategy gone'));
    }
    if (facts.length > most) facts.removeRange(most, facts.length);
  }
}

Iterable<List<Fact>> orderings(List<Fact> facts) sync* {
  final used = List.filled(facts.length, false);
  final chosen = <Fact>[];
  bool allowed(int index) {
    final key = facts[index].orderKey;
    if (key == null) return true;
    for (var earlier = 0; earlier < index; earlier++) {
      if (facts[earlier].orderKey == key && !used[earlier]) return false;
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

CloudQueue deliver(CloudQueue start, List<Fact> order) {
  var queue = start;
  for (final fact in order) {
    if (transition(queue, fact.event, now: now) case Stepped(
      queue: final next,
    )) {
      queue = next;
    }
  }
  return queue;
}

String describe(CloudQueue queue) {
  final views = viewsOf(queue, now);
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
      scenario.gatherFacts(7);
      final start = scenario.client.queue;
      final facts = scenario.facts;
      factsSeen += facts.length;
      CloudQueue? first;
      List<Fact>? firstOrder;
      for (final order in orderings(facts)) {
        orders++;
        final end = deliver(start, order);
        final views = describe(end);
        if (first == null) {
          first = end;
          firstOrder = order;
          continue;
        }
        if (end != first || views != describe(first)) {
          fail(
            'seed $seed: two orders of the same facts disagree\n'
            'prefix:\n${scenario.log.join('\n')}\n'
            'first order: ${firstOrder!.map((f) => f.label).join(' | ')}\n'
            '${describe(first)}\n'
            'other order: ${order.map((f) => f.label).join(' | ')}\n'
            '$views',
          );
        }
      }
    }
    print('$orders orders of $factsSeen facts');
    expect(orders, greaterThan(seeds * 20));
  });
}
