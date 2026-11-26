import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_server.dart' show withoutPage;
import 'cloud_support.dart';
import 'stamp_source.dart';

typedef Items = Map<String, int?>;

final class ServerState {
  ServerState(this.index, this.rows, {required this.exists});

  final int index;
  final StrategyRowSet rows;
  final bool exists;

  ArrivedBase read(String? page) => switch ((exists, page)) {
    (false, null) => const StrategyGone(),
    (false, final page?) => PageGone(page),
    (true, null) => headerReadOf(rows),
    (true, final page?) => pageReadOf(rows, page),
  };
}

sealed class Fact {
  const Fact();
}

final class ReadFact extends Fact {
  ReadFact(this.page, this.state, this.point, this.run);

  final String? page;
  final ServerState state;
  final ResultPoint point;
  final int run;

  ArrivedBase get base => state.read(page);

  String get subject => page ?? 'the page list';

  @override
  String toString() =>
      '${switch (base) {
        HeaderRead() => 'list',
        StrategyGone() => 'strategy gone',
        PageRead() => 'page $page',
        PageGone() => '$page gone',
      }} of state ${state.index} at ${point.client}/${point.connection}/'
      '${point.snapshot} run $run';
}

final class ReconnectFact extends Fact {
  const ReconnectFact(this.generation, this.run);

  final Generation generation;
  final int run;

  @override
  String toString() => 'reconnect to $generation';
}

final class RestartFact extends Fact {
  const RestartFact(this.run, this.generation);

  final int run;
  final Generation generation;

  @override
  String toString() => 'restart into run $run on $generation';
}

final class Scenario {
  Scenario(this.seed) : random = Random(seed) {
    client = Client();
    start = client.queue;
    clock = (lastPoint.serverTime ?? firstServerTime) + 1000000000;
    stamps = StampSource(
      Random(seed * 7 + 3),
      from: lastPoint,
      now: () => clock,
    );
    states.add(ServerState(0, initialRows(), exists: true));
  }

  final int seed;
  final Random random;
  late final Client client;
  late final CloudQueue start;
  late final StampSource stamps;
  late int clock;
  final states = <ServerState>[];
  final facts = <Fact>[];
  int run = 0;

  ServerState get now => states.last;

  void pass() => clock += 1 + random.nextInt(50000000);

  void write(StrategyRowSet rows, {bool exists = true}) {
    pass();
    states.add(ServerState(states.length, rows, exists: exists));
  }

  void read(String? page) {
    pass();
    facts.add(ReadFact(page, now, stamps.at(now), run));
  }

  List<String> get livePages => [
    for (final page in now.rows.pages)
      if (page is LivePage) page.publicId,
  ];

  void teammateWrites(String page) {
    final live = [
      for (final row in now.rows.elementsOn(page))
        if (row is LiveElement) row,
    ];
    final StrategyOp op = switch (random.nextInt(3)) {
      0 when live.isNotEmpty => () {
        final target = live[random.nextInt(live.length)];
        return movePatch(
          't${states.length}',
          elementId: target.publicId,
          expected: target.revision,
          x: 1.0 + random.nextInt(500),
        );
      }(),
      1 when live.length > 1 => () {
        final target = live[random.nextInt(live.length)];
        return elementDelete(
          't${states.length}',
          elementId: target.publicId,
          pageId: page,
          expected: target.revision,
        );
      }(),
      _ => elementAdd(
        't${states.length}',
        elementId: 'n${states.length}',
        pageId: page,
      ),
    };
    write(withOp(now.rows, op));
  }

  void deletePage(String page) => write(withoutPage(now.rows, page));

  void restorePage(StrategyRowSet before) => write(before);

  void deleteStrategy() => write(now.rows, exists: false);

  void reconnect() {
    pass();
    final generation = random.nextInt(4) == 0
        ? stamps.anotherClient()
        : stamps.reconnect();
    facts.add(ReconnectFact(generation, run));
  }

  void restart() {
    pass();
    run++;
    if (random.nextBool()) stamps.anotherClient();
    facts.add(RestartFact(run, stamps.generation));
  }

  String pickPage() => livePages[random.nextInt(livePages.length)];

  void build() {
    final page = pickPage();
    switch (seed % families) {
      case 0:
        teammateWrites(page);
        read(page);
        teammateWrites(page);
        read(page);
        if (random.nextBool()) read(null);
        teammateWrites(page);
        read(page);
      case 1:
        if (random.nextBool()) reconnect();
        teammateWrites(page);
        read(page);
        if (random.nextBool()) read(null);
        restart();
        if (random.nextBool()) teammateWrites(page);
        if (random.nextBool()) read(page);
        read(null);
      case 2:
        teammateWrites(page);
        read(page);
        reconnect();
        if (random.nextBool()) teammateWrites(page);
        if (random.nextBool()) read(page);
        read(null);
        if (random.nextBool()) read(page);
      case 3:
        teammateWrites(page);
        read(page);
        if (random.nextBool()) read(null);
        deletePage(page);
        read(page);
        read(null);
        if (random.nextBool()) read(livePages.first);
      case 4:
        teammateWrites(page);
        if (random.nextBool()) {
          deletePage(livePages.firstWhere((other) => other != page));
        }
        read(null);
        read(page);
        if (random.nextBool()) teammateWrites(page);
        deleteStrategy();
        read(null);
        read(page);
      case _:
        if (random.nextBool()) teammateWrites(page);
        read(null);
        final before = now.rows;
        deletePage(page);
        if (random.nextBool()) read(null);
        if (random.nextBool()) read(page);
        if (random.nextInt(4) == 0) reconnect();
        if (random.nextInt(4) != 0) {
          restorePage(before);
          if (random.nextBool()) teammateWrites(page);
          read(page);
          if (random.nextBool()) read(null);
        }
    }
  }
}

const families = 6;

final class Reference {
  Reference(ServerState first, this.held)
    : listAt = 0,
      listed = {
        for (final page in first.rows.pages)
          if (page is LivePage) page.publicId,
      },
      pages = {
        for (final page in first.rows.pages)
          page.publicId: (at: 0, items: itemsOf(first.rows, page.publicId)),
      };

  int listAt;
  Set<String> listed;
  bool gone = false;
  int? owedSince;
  final Map<String, ({int at, Items? items})> pages;
  int run = 0;
  Generation? held;

  static Items itemsOf(StrategyRows rows, String page) => {
    for (final row in rows.elementsOn(page))
      row.publicId: revisionOfRowForTest(row),
  };

  static bool before(Generation a, Generation b) =>
      a.client < b.client ||
      (a.client == b.client && a.connection < b.connection);

  void apply(Fact fact) {
    switch (fact) {
      case RestartFact(:final run, :final generation):
        this.run = run;
        held = generation;
      case ReconnectFact(:final generation):
        if (held case final now? when !before(now, generation)) return;
        held = generation;
      case ReadFact():
        _read(fact);
    }
  }

  void _read(ReadFact read) {
    if (read.run != run) return;
    final generation = read.point.generation;
    if (held case final now? when before(generation, now)) return;
    held = generation;
    final at = read.state.index;
    switch (read.base) {
      case HeaderRead(:final pages):
        if (owedSince case final owed? when at < owed) return;
        if (at <= listAt) return;
        listAt = at;
        owedSince = null;
        bool newerThanList(String page) => (this.pages[page]?.at ?? -1) > at;
        listed = {
          for (final page in pages)
            if (page is LivePage &&
                !(newerThanList(page.publicId) &&
                    this.pages[page.publicId]!.items == null))
              page.publicId,
          for (final page in listed)
            if (newerThanList(page) && this.pages[page]!.items != null) page,
        };
        this.pages.removeWhere(
          (page, held) => !listed.contains(page) && held.at <= at,
        );
      case StrategyGone():
        if (owedSince case final owed? when at < owed) return;
        if (at <= listAt) return;
        listAt = at;
        owedSince = null;
        gone = true;
      case PageRead(:final page):
        final id = page.publicId;
        if (pages[id] case final held? when at <= held.at) return;
        if (!listed.contains(id)) {
          owedSince = max(owedSince ?? at, at);
          return;
        }
        pages[id] = (at: at, items: itemsOf(read.state.rows, id));
      case PageGone(:final pagePublicId):
        if (pages[pagePublicId] case final held? when at <= held.at) return;
        if (listed.contains(pagePublicId) && at < listAt) return;
        pages[pagePublicId] = (at: at, items: null);
        listed = {...listed}..remove(pagePublicId);
    }
  }
}

Iterable<List<Fact>> orders(List<Fact> facts) sync* {
  final used = List.filled(facts.length, false);
  final chosen = <Fact>[];
  int runOf(Fact fact) => switch (fact) {
    ReadFact(:final run) ||
    ReconnectFact(:final run) ||
    RestartFact(:final run) => run,
  };
  bool allowed(int index) {
    for (var other = 0; other < facts.length; other++) {
      if (used[other] || other == index) continue;
      if (facts[other] is RestartFact &&
          runOf(facts[index]) >= runOf(facts[other])) {
        return false;
      }
      if (facts[index] is RestartFact &&
          facts[other] is ReconnectFact &&
          runOf(facts[other]) < runOf(facts[index])) {
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

final cases = <String, int>{};

void count(String what) => cases[what] = (cases[what] ?? 0) + 1;

void countCases(List<Fact> order) {
  final reads = order.whereType<ReadFact>().toList();
  for (var i = 0; i < reads.length; i++) {
    for (var j = i + 1; j < reads.length; j++) {
      final (newer, older) = (reads[i], reads[j]);
      if (newer.subject != older.subject ||
          newer.state.index <= older.state.index ||
          newer.run != older.run) {
        continue;
      }
      count('a late older read after a newer one');
      switch ((newer.base, older.base)) {
        case (PageGone(), PageRead()):
          count('a newer page-gone before a delayed older live page read');
        case (StrategyGone(), HeaderRead()):
          count('a newer strategy-gone before a delayed older live list');
        case _:
          break;
      }
    }
  }
  for (final (at, fact) in order.indexed) {
    switch (fact) {
      case RestartFact(:final run):
        if (order
            .skip(at)
            .whereType<ReadFact>()
            .any((read) => read.run < run)) {
          count('a read from before a restart delivered after it');
        }
      case ReconnectFact(:final generation):
        if (order
            .take(at)
            .whereType<ReadFact>()
            .any((read) => read.point.generation == generation)) {
          count('a stamp from a later connection before its reconnect event');
        }
        if (order
            .skip(at)
            .whereType<ReadFact>()
            .any(
              (read) => Reference.before(read.point.generation, generation),
            )) {
          count('a read from an earlier connection after a reconnect event');
        }
      case ReadFact():
        break;
    }
  }
  if (reads.any((read) => read.base is PageGone)) {
    count('orders with a page gone');
  }
  if (reads.any((read) => read.base is StrategyGone)) {
    count('orders with the strategy gone');
  }
  final points = <ResultPoint>{};
  if (reads.any((read) => !points.add(read.point))) {
    count('orders with two reads of one snapshot');
  }
}

final class Delivered {
  Delivered(this.queue, this.labels);

  final CloudQueue queue;
  final List<String> labels;
}

CloudQueue deliver(CloudQueue start, List<Fact> order) {
  var queue = start;
  final labelsFrom = <int, int>{0: start.session.labelsFrom};
  void step(QueueEvent event) {
    queue = transition(queue, event, now: now).queue;
  }

  for (final fact in order) {
    switch (fact) {
      case RestartFact(:final run, :final generation):
        step(const AppRestarted(build: build));
        step(ConnectionReturned(generation));
        labelsFrom[run] = queue.session.labelsFrom;
      case ReconnectFact(:final generation):
        step(ConnectionReturned(generation));
      case ReadFact(:final base, :final point, :final run):
        step(
          BaseArrived(
            base,
            session: labelsFrom[run]!,
            point: point,
            requestedAt: null,
          ),
        );
    }
  }
  return queue;
}

String? disagreement(CloudQueue queue, Reference want) {
  final shown = queue.shown;
  final gone = standingOf(queue) == Standing.deletedOnServer;
  if (gone != want.gone) {
    return 'the strategy is ${gone ? '' : 'not '}shown as deleted, the '
        'reference says ${want.gone ? '' : 'not '}deleted';
  }
  final listed = shown.pages.keys.toSet();
  if (!listed.containsAll(want.listed) || !want.listed.containsAll(listed)) {
    return 'the page list shows $listed, the reference ${want.listed}';
  }
  final owes = shown.list is ReadOwed;
  if (owes != (want.owedSince != null)) {
    return 'the page list is ${shown.list}, the reference '
        '${want.owedSince == null ? 'owes nothing' : 'owes a list at or after '
                  'state ${want.owedSince}'}';
  }
  final pages = {...shown.content.keys, ...want.pages.keys};
  for (final page in pages) {
    final held = shown.content.containsKey(page)
        ? <String, int?>{
            for (final MapEntry(:key, :value) in shown.rows.entries)
              if (key case ElementTarget(
                :final elementPublicId,
              ) when value.page == page)
                elementPublicId: value.revision,
          }
        : null;
    final wanted = want.pages[page]?.items;
    final same =
        (held == null && wanted == null) ||
        (held != null &&
            wanted != null &&
            held.length == wanted.length &&
            held.entries.every((entry) => wanted[entry.key] == entry.value));
    if (!same) {
      return 'page $page holds $held, the reference '
          '${wanted ?? 'nothing'} from state ${want.pages[page]?.at}';
    }
  }
  return null;
}

void main() {
  final seeds =
      int.tryParse(Platform.environment['ARRIVAL_ORDER_SEEDS'] ?? '') ??
      80 * families;
  final one = int.tryParse(Platform.environment['ARRIVAL_ORDER_SEED'] ?? '');
  test('reads delivered in every order end where a model of the server says, '
      'whatever their stamps', () {
    var checked = 0;
    for (final seed
        in one == null ? [for (var s = 1; s <= seeds; s++) s] : [one]) {
      final scenario = Scenario(seed)..build();
      for (final order in orders(scenario.facts)) {
        checked++;
        countCases(order);
        final want = Reference(scenario.states.first, lastHeld(scenario));
        order.forEach(want.apply);
        final queue = deliver(scenario.start, order);
        if (disagreement(queue, want) case final problem?) {
          fail(
            'seed $seed: $problem\n'
            'states: ${[for (final state in scenario.states) '${state.index}${state.exists ? '' : ' (deleted)'}'].join(', ')}\n'
            'order:\n  ${order.join('\n  ')}',
          );
        }
      }
    }
    if (Platform.environment['ARRIVAL_ORDER_COUNTS'] == '1') {
      stdout.writeln('$checked orders');
      for (final MapEntry(:key, :value) in cases.entries) {
        stdout.writeln('$key: $value');
      }
    }
    if (one != null) return;
    expect(checked, greaterThan(seeds * 20));
    for (final MapEntry(key: what, value: least) in floors.entries) {
      expect(cases[what] ?? 0, greaterThanOrEqualTo(least), reason: what);
    }
  });
}

Generation? lastHeld(Scenario scenario) => scenario.start.session.generation;

const floors = {
  'a late older read after a newer one': 4000,
  'a newer page-gone before a delayed older live page read': 1400,
  'a newer strategy-gone before a delayed older live list': 480,
  'a read from before a restart delivered after it': 700,
  'a stamp from a later connection before its reconnect event': 1500,
  'a read from an earlier connection after a reconnect event': 900,
  'orders with a page gone': 2800,
  'orders with the strategy gone': 960,
  'orders with two reads of one snapshot': 3000,
};
