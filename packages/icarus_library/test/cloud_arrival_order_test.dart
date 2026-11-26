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

  int get run;
}

final class ReadFact extends Fact {
  ReadFact(this.page, this.state, this.point, this.run, {required this.tick});

  final String? page;
  final ServerState state;
  final ResultPoint point;
  @override
  final int run;
  final int tick;

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
  @override
  final int run;

  @override
  String toString() => 'reconnect to $generation';
}

final class RestartFact extends Fact {
  const RestartFact(this.run, this.generation);

  @override
  final int run;
  final Generation generation;

  @override
  String toString() => 'restart into run $run on $generation';
}

final class Scenario {
  Scenario(this.seed) : random = Random(seed) {
    start = Client().queue;
    lastStamp = lastPoint;
    clock = (lastPoint.serverTime ?? 0) + 1000000000;
    stamps = StampSource(
      Random(seed * 7 + 3),
      from: lastPoint,
      now: () => clock,
    );
    states.add(ServerState(0, initialRows(), exists: true));
  }

  final int seed;
  final Random random;
  late final CloudQueue start;
  late final StampSource stamps;
  late int clock;
  final states = <ServerState>[];
  final facts = <Fact>[];
  int run = 0;
  late ResultPoint lastStamp;
  int tick = 0;

  int tickOf(ResultPoint point) {
    if (point != lastStamp) {
      tick++;
      lastStamp = point;
    }
    return tick;
  }

  ServerState get now => states.last;

  void pass() => clock += 1 + random.nextInt(50000000);

  void write(StrategyRowSet rows, {bool exists = true}) {
    pass();
    states.add(ServerState(states.length, rows, exists: exists));
  }

  void read(String? page) {
    pass();
    final point = stamps.at(now);
    facts.add(ReadFact(page, now, point, run, tick: tickOf(point)));
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
        read(page);
        if (random.nextInt(4) == 0) reconnect();
        restorePage(before);
        if (random.nextBool()) teammateWrites(page);
        read(page);
        read(null);
    }
  }
}

const families = 6;

final class Reference {
  Reference(ServerState first, this.held)
    : listed = livePagesOf(first.rows),
      content = {
        for (final page in first.rows.pages)
          page.publicId: itemsOf(first.rows, page.publicId),
      },
      pageTakenAt = {for (final page in first.rows.pages) page.publicId: 0},
      pagesFreshSinceSession = livePagesOf(first.rows);

  Set<String> listed;
  final Map<String, Items> content;
  bool gone = false;
  int? listTakenAt = 0;
  final Map<String, int> pageTakenAt;
  int? listOwedFrom;
  int run = 0;
  Generation? held;
  bool listFreshSinceSession = true;
  final Set<String> pagesFreshSinceSession;

  static const anyResultOfThisSession = -1;

  static Set<String> livePagesOf(StrategyRows rows) => {
    for (final page in rows.pages)
      if (page is LivePage) page.publicId,
  };

  static Items itemsOf(StrategyRows rows, String page) => {
    for (final row in rows.elementsOn(page))
      row.publicId: revisionOfRowForTest(row),
  };

  bool get listOwed => listOwedFrom != null;

  void newSession() {
    listTakenAt = null;
    pageTakenAt.clear();
    if (listOwed) listOwedFrom = anyResultOfThisSession;
    listFreshSinceSession = false;
    pagesFreshSinceSession.clear();
  }

  bool admits(Generation generation) {
    if (held case final now? when generation.isBefore(now)) return false;
    if (held case final now? when now.isBefore(generation)) newSession();
    held = generation;
    return true;
  }

  void apply(Fact fact) {
    switch (fact) {
      case RestartFact(:final run, :final generation):
        this.run = run;
        held = generation;
        newSession();
      case ReconnectFact(:final generation):
        if (held case final now? when !now.isBefore(generation)) return;
        newSession();
        held = generation;
      case ReadFact():
        if (fact.run != run || !admits(fact.point.generation)) return;
        switch (fact.base) {
          case HeaderRead():
            _listTaken(fact);
          case StrategyGone():
            _strategyGoneTaken(fact);
          case PageRead(:final page):
            _pageRead(fact, page.publicId);
          case PageGone(:final pagePublicId):
            _pageGone(fact, pagePublicId);
        }
    }
  }

  bool _olderThanListTakenOrOwed(int at) =>
      at < (listTakenAt ?? anyResultOfThisSession) ||
      at < (listOwedFrom ?? anyResultOfThisSession);

  bool _olderThanPageTaken(String page, int at) =>
      at < (pageTakenAt[page] ?? anyResultOfThisSession);

  void _listTaken(ReadFact read) {
    if (_olderThanListTakenOrOwed(read.tick)) return;
    listTakenAt = read.tick;
    listOwedFrom = null;
    listed = livePagesOf(read.state.rows);
    content.removeWhere((page, _) => !listed.contains(page));
    listFreshSinceSession = true;
  }

  void _strategyGoneTaken(ReadFact read) {
    if (_olderThanListTakenOrOwed(read.tick)) return;
    listTakenAt = read.tick;
    listOwedFrom = null;
    gone = true;
  }

  void _pageRead(ReadFact read, String page) {
    if (_olderThanPageTaken(page, read.tick)) return;
    if (!listed.contains(page)) {
      listOwedFrom ??= read.tick;
      return;
    }
    pageTakenAt[page] = read.tick;
    content[page] = itemsOf(read.state.rows, page);
    pagesFreshSinceSession.add(page);
  }

  void _pageGone(ReadFact read, String page) {
    if (_olderThanPageTaken(page, read.tick)) return;
    pageTakenAt[page] = read.tick;
    listed = {...listed}..remove(page);
    content.remove(page);
    pagesFreshSinceSession.add(page);
  }
}

Iterable<List<Fact>> orders(List<Fact> facts) sync* {
  final used = List.filled(facts.length, false);
  final chosen = <Fact>[];
  bool allowed(int index) {
    for (var other = 0; other < facts.length; other++) {
      if (used[other] || other == index) continue;
      if (facts[other] is RestartFact && facts[index].run >= facts[other].run) {
        return false;
      }
      if (facts[index] is RestartFact &&
          facts[other] is ReconnectFact &&
          facts[other].run < facts[index].run) {
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
  bool lists(ReadFact read, String page) => switch (read.base) {
    HeaderRead(:final pages) => pages.any(
      (row) => row is LivePage && row.publicId == page,
    ),
    _ => false,
  };
  for (var i = 0; i < reads.length; i++) {
    for (var j = i + 1; j < reads.length; j++) {
      final (first, late) = (reads[i], reads[j]);
      if (first.run != late.run || late.state.index >= first.state.index) {
        continue;
      }
      switch ((first.base, late.base)) {
        case (PageRead(:final page), HeaderRead())
            when !lists(late, page.publicId):
          count('an older list leaving a page out after a newer read of it');
        case (HeaderRead(), PageGone(:final pagePublicId))
            when lists(first, pagePublicId):
          count('an older page-gone after a newer list showing the page');
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
            .any((read) => read.point.generation.isBefore(generation))) {
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
        step(BaseArrived(base, session: labelsFrom[run]!, point: point));
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
  if (owes != want.listOwed) {
    return 'the page list is ${shown.list}, the reference '
        '${want.listOwed ? 'owes a list at or after ${want.listOwedFrom}' : 'owes nothing'}';
  }
  for (final page in {...shown.content.keys, ...want.content.keys}) {
    final held = shown.content.containsKey(page)
        ? <String, int?>{
            for (final MapEntry(:key, :value) in shown.rows.entries)
              if (key case ElementTarget(
                :final elementPublicId,
              ) when value.page == page)
                elementPublicId: value.revision,
          }
        : null;
    final wanted = want.content[page];
    final same =
        (held == null && wanted == null) ||
        (held != null &&
            wanted != null &&
            held.length == wanted.length &&
            held.entries.every((entry) => wanted[entry.key] == entry.value));
    if (!same) {
      return 'page $page holds $held, the reference ${wanted ?? 'nothing'} '
          'from ${want.pageTakenAt[page]}';
    }
  }
  for (final page in {
    ...listed,
    ...want.listed,
    ...shown.fresh.pagesSinceTouch,
    ...want.pagesFreshSinceSession,
  }) {
    final listFresh = shown.fresh.listFreshFor(page);
    if (listFresh != want.listFreshSinceSession) {
      return 'the page list is ${listFresh ? '' : 'not '}fresh for $page, '
          'the reference says ${want.listFreshSinceSession ? '' : 'not '}fresh';
    }
    final pageFresh = shown.fresh.pageFreshFor(page);
    final wantPageFresh = want.pagesFreshSinceSession.contains(page);
    if (pageFresh != wantPageFresh) {
      return 'page $page is ${pageFresh ? '' : 'not '}fresh, the reference '
          'says ${wantPageFresh ? '' : 'not '}fresh';
    }
  }
  return null;
}

void main() {
  final seeds =
      int.tryParse(Platform.environment['ARRIVAL_ORDER_SEEDS'] ?? '') ??
      80 * families;
  final one = int.tryParse(Platform.environment['ARRIVAL_ORDER_SEED'] ?? '');
  final family = int.tryParse(
    Platform.environment['ARRIVAL_ORDER_FAMILY'] ?? '',
  );
  test('reads delivered in every order end where a model of the server says: '
      'per-subject order and sessions, the newest list decides which pages '
      'exist without touching any page\'s own order, a page read the list '
      'does not show owes the list, and a page gone not older than its page '
      'removes it', () {
    var checked = 0;
    for (final seed
        in one == null
            ? [
                for (var s = 1; s <= seeds; s++)
                  if (family == null || s % families == family) s,
              ]
            : [one]) {
      final scenario = Scenario(seed)..build();
      for (final order in orders(scenario.facts)) {
        checked++;
        countCases(order);
        final want = Reference(
          scenario.states.first,
          scenario.start.session.generation,
        );
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
    if (one != null || family != null) return;
    expect(checked, greaterThan(seeds * 20));
    for (final MapEntry(key: what, value: least) in floors.entries) {
      expect(cases[what] ?? 0, greaterThanOrEqualTo(least), reason: what);
    }
  });
}

const floors = {
  'a late older read after a newer one': 25000,
  'a newer page-gone before a delayed older live page read': 2000,
  'a newer strategy-gone before a delayed older live list': 770,
  'a read from before a restart delivered after it': 1100,
  'a stamp from a later connection before its reconnect event': 7000,
  'a read from an earlier connection after a reconnect event': 6500,
  'orders with a page gone': 14000,
  'orders with the strategy gone': 1500,
  'orders with two reads of one snapshot': 10500,
  'an older list leaving a page out after a newer read of it': 4300,
  'an older page-gone after a newer list showing the page': 5000,
};
