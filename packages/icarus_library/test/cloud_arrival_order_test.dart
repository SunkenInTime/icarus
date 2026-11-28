import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/stamp_source.dart';
import 'package:test/test.dart';

import 'cloud_server.dart' show withoutPage;
import 'cloud_support.dart';

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

final class OwnWork {
  const OwnWork(this.op, this.attempt, {required this.page});

  final StrategyOp op;
  final int attempt;
  final String page;

  bool get changesList => op is PageReorderOp;

  String get wrote => switch (op) {
    ElementPatchOp(:final elementPublicId) => elementPublicId,
    _ => strategyRow,
  };
}

const strategyRow = 'the strategy';

const ownReorder = PageReorderOp(
  opId: 'reorder',
  pagePublicId: 'page-b',
  sortIndex: 0,
  expectedStrategyRevision: 1,
);

final class AnswerFact extends Fact {
  AnswerFact(this.work, this.revision, this.point, {required this.tick});

  final OwnWork work;
  final int revision;
  final ResultPoint point;
  final int tick;

  @override
  int get run => 0;

  OpAnswer get answer => AppliedAnswer(
    work.op.opId,
    revision: revision,
    life: work.changesList ? createdAtOf(initialRows().strategy)! : fixtureLife,
  );

  @override
  String toString() =>
      '${work.op.opId} answered at ${point.client}/${point.connection}/'
      '${point.snapshot}, time ${point.serverTime}';
}

final class Scenario {
  Scenario(this.seed) : random = Random(seed) {
    final client = Client();
    work = switch (familyOf(seed)) {
      6 || 8 => () {
        final op = movePatch('own', elementId: 'e1', x: 77);
        client.edit(op);
        return OwnWork(op, client.claim(['own']), page: 'page-a');
      }(),
      7 => () {
        client.edit(ownReorder);
        return OwnWork(ownReorder, client.claim(['reorder']), page: 'page-b');
      }(),
      _ => null,
    };
    start = client.queue;
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
  late final OwnWork? work;

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

  void teammateMovesItem(String from, String to) {
    final live = [
      for (final row in now.rows.elementsOn(from))
        if (row is LiveElement) row,
    ];
    if (live.isEmpty) return teammateWrites(to);
    final target = live[random.nextInt(live.length)];
    write(
      withOp(
        now.rows,
        movePatch(
          't${states.length}',
          elementId: target.publicId,
          expected: target.revision,
          pageId: to,
          x: 1.0 + random.nextInt(500),
        ),
      ),
    );
  }

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

  void ownLands() {
    final op = switch (work!.op) {
      ElementPatchOp() => movePatch(
        'own',
        elementId: 'e1',
        x: 77,
        expected: revisionOfRowForTest(now.rows.element('e1')!)!,
      ),
      final other => other,
    };
    write(withOp(now.rows, op));
  }

  void answer({required bool atHeldPoint}) {
    pass();
    final point = atHeldPoint ? stamps.answered : stamps.at(now);
    final row = switch (work!.wrote) {
      strategyRow => now.rows.strategy,
      final id => now.rows.element(id)!,
    };
    facts.add(
      AnswerFact(work!, revisionOfRowForTest(row)!, point, tick: tickOf(point)),
    );
  }

  void buildOwn() {
    final page = work!.page;
    switch (familyOf(seed)) {
      case 6:
        read(page);
        ownLands();
        answer(atHeldPoint: random.nextInt(3) == 0);
        if (random.nextBool()) teammateWrites(page);
        read(page);
        if (random.nextBool()) read(null);
        read(page);
      case 7:
        read(random.nextBool() ? null : 'page-a');
        ownLands();
        answer(atHeldPoint: random.nextInt(3) == 0);
        if (random.nextBool()) reconnect();
        read(null);
        read(random.nextBool() ? 'page-a' : 'page-b');
      case _:
        read(page);
        ownLands();
        answer(atHeldPoint: random.nextBool());
        if (random.nextBool()) teammateWrites(page);
        reconnect();
        read(page);
        random.nextBool() ? read(page) : read(null);
    }
  }

  void build() {
    if (work != null) return buildOwn();
    final page = pickPage();
    switch (familyOf(seed)) {
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
      case 9:
        final other = livePages.firstWhere((other) => other != page);
        read(page);
        read(other);
        teammateMovesItem(page, other);
        read(other);
        if (random.nextBool()) read(page);
        if (random.nextBool()) teammateMovesItem(other, page);
        read(page);
        if (random.nextBool()) read(other);
      case 5:
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

const families = 10;

const seedsPerFamily = 80;

int familyOf(int seed) => seed > seedsPerFamily * (families - 1)
    ? families - 1
    : seed % (families - 1);

final class Mark {
  const Mark(this.tick, this.time, this.wrote);

  final int tick;
  final int? time;
  final Map<String, int>? wrote;

  bool reachedBy(ReadFact? read) =>
      read != null &&
      read.tick >= tick &&
      switch ((time, read.point.serverTime)) {
        (null, _) => true,
        (_, null) => false,
        (final answered?, final shown?) => shown >= answered,
      };

  Mark and(Mark? other) => switch (other) {
    null => this,
    final other => Mark(
      max(tick, other.tick),
      switch ((time, other.time)) {
        (final a?, final b?) => max(a, b),
        (final a, final b) => a ?? b,
      },
      switch ((wrote, other.wrote)) {
        (final mine?, final theirs?) => {
          ...mine,
          for (final MapEntry(:key, :value) in theirs.entries)
            key: max(value, mine[key] ?? value),
        },
        _ => null,
      },
    ),
  };
}

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
  final removedAt = <String, (int, int?)>{};
  bool gone = false;
  int? listTakenAt = 0;
  final Map<String, int> pageTakenAt;
  int? listOwedFrom;
  int run = 0;
  Generation? held;
  bool listFreshSinceSession = true;
  final Set<String> pagesFreshSinceSession;
  final Set<String> goneByResult = {};
  ReadFact? listRead;
  final pageSeen = <String, ReadFact>{};
  int? heldStrategy;
  final highest = <String, int>{};
  Mark? listMark;
  Mark? allPages;
  final pageMarks = <String, Mark>{};
  final listFor = <String, Mark>{};
  final rowMarks = <String, Mark>{};

  String? rowPage(String id) => [
    for (final MapEntry(:key, :value) in content.entries)
      if (value.containsKey(id)) key,
  ].firstOrNull;

  bool allHeld(Map<String, int>? wrote, bool Function(String, int) holds) =>
      wrote?.entries.every((entry) => holds(entry.key, entry.value)) ?? false;

  bool listHolds(Map<String, int>? wrote) => allHeld(
    wrote,
    (id, revision) => id == strategyRow && (heldStrategy ?? -1) >= revision,
  );

  bool listReaches(Mark? mark) =>
      mark == null || mark.reachedBy(listRead) || listHolds(mark.wrote);

  bool pageHolds(String page, Map<String, int>? wrote) => allHeld(
    wrote,
    (id, revision) =>
        id != strategyRow && (content[page]?[id] ?? -1) >= revision,
  );

  bool pageReaches(String page, Mark? mark) =>
      mark == null ||
      mark.reachedBy(pageSeen[page]) ||
      pageHolds(page, mark.wrote);

  bool rowHolds(Map<String, int>? wrote) => allHeld(
    wrote,
    (id, revision) =>
        id != strategyRow &&
        (switch (rowPage(id)) {
              final page? => (content[page]![id] ?? -1) >= revision,
              null => false,
            } ||
            (highest[id] ?? -1) >= revision),
  );

  bool rowSettled(String id, Mark mark) =>
      rowHolds(mark.wrote) ||
      switch (rowPage(id)) {
        final page? => mark.reachedBy(pageSeen[page]),
        null => false,
      };

  bool listCurrentFor(String page) =>
      listFreshSinceSession &&
      !listOwed &&
      listReaches(listMark) &&
      listReaches(listFor[page]);

  bool pageCurrentNow(String page) =>
      pageCurrent(page) &&
      pageReaches(page, pageMarks[page]) &&
      (allPages?.reachedBy(pageSeen[page]) ?? true) &&
      rowMarks.entries.every(
        (entry) =>
            rowPage(entry.key) != page ||
            entry.value.reachedBy(pageSeen[page]) ||
            rowHolds(entry.value.wrote),
      );

  void _answer(AnswerFact fact) {
    if (!admits(fact.point.generation)) return;
    final work = fact.work;
    final mark = Mark(fact.tick, fact.point.serverTime, {
      work.wrote: fact.revision,
    });
    final pages = {
      work.page,
      if (work.wrote != strategyRow) ?rowPage(work.wrote),
    };
    if (work.changesList) {
      if (!listReaches(mark)) listMark = mark.and(listMark);
      allPages = mark.and(allPages);
    }
    for (final page in pages) {
      if (!(pageSeen.containsKey(page) && pageReaches(page, mark))) {
        pageMarks[page] = mark.and(pageMarks[page]);
      }
      if (!listReaches(mark)) listFor[page] = mark.and(listFor[page]);
    }
    if (work.wrote != strategyRow && !rowSettled(work.wrote, mark)) {
      rowMarks[work.wrote] = mark.and(rowMarks[work.wrote]);
    }
  }

  void _listSettles(ReadFact read) {
    listRead = read;
    if (read.base case HeaderRead(:final strategy)) {
      heldStrategy = revisionOfRowForTest(strategy);
    }
    if (listReaches(listMark)) listMark = null;
    listFor.removeWhere((_, mark) => listReaches(mark));
  }

  void _pageSettles(ReadFact read, String page) {
    pageSeen[page] = read;
    if (read.base case PageRead(:final elements)) {
      for (final row in elements) {
        final revision = revisionOfRowForTest(row) ?? -1;
        if (revision > (highest[row.publicId] ?? -1)) {
          highest[row.publicId] = revision;
        }
      }
    }
    if (pageMarks[page] case final mark? when pageReaches(page, mark)) {
      pageMarks.remove(page);
    }
    rowMarks.removeWhere(rowSettled);
    if (allPages case final mark?
        when listed.every((live) => mark.reachedBy(pageSeen[live]))) {
      allPages = null;
    }
  }

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
    goneByResult.clear();
    listRead = null;
    pageSeen.clear();
    removedAt.clear();
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
      case AnswerFact():
        _answer(fact);
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

  bool _listNewerThan(int at) => listTakenAt != null && at < listTakenAt!;

  void _listTaken(ReadFact read) {
    if (_olderThanListTakenOrOwed(read.tick)) return;
    listTakenAt = read.tick;
    listOwedFrom = null;
    final claimed = livePagesOf(read.state.rows);
    for (final page in {...listed, ...claimed}) {
      final own = pageTakenAt[page];
      final agrees = claimed.contains(page) == listed.contains(page);
      if (agrees || own == null || own < read.tick) {
        if (!claimed.contains(page)) {
          listed = {...listed}..remove(page);
          _removeContent(page, read.tick);
        } else {
          listed = {...listed, page};
        }
      } else if (!claimed.contains(page)) {
        count(
          'an older list leaving a page out after a newer read of it, kept',
        );
      }
    }
    listFreshSinceSession = true;
    _listSettles(read);
  }

  void _strategyGoneTaken(ReadFact read) {
    if (_olderThanListTakenOrOwed(read.tick)) return;
    listTakenAt = read.tick;
    listOwedFrom = null;
    gone = true;
    _listSettles(read);
  }

  void _pageRead(ReadFact read, String page) {
    if (_olderThanPageTaken(page, read.tick)) return;
    if (!listed.contains(page)) {
      if (listTakenAt == null || listTakenAt! < read.tick) {
        _oweListFrom(read.tick);
      }
      return;
    }
    pageTakenAt[page] = read.tick;
    _takeContent(page, itemsOf(read.state.rows, page), read.tick);
    pagesFreshSinceSession.add(page);
    goneByResult.remove(page);
    _pageSettles(read, page);
  }

  void _oweListFrom(int tick) {
    final owed = listOwedFrom;
    if (owed == null || owed < tick) listOwedFrom = tick;
  }

  void _pageGone(ReadFact read, String page) {
    if (_olderThanPageTaken(page, read.tick)) return;
    if (_listNewerThan(read.tick)) return;
    if (listTakenAt == read.tick && listed.contains(page)) return;
    if (listed.contains(page)) {
      count('a live page read not found, owing the list');
      _oweListFrom(read.tick);
    }
    pageTakenAt[page] = read.tick;
    listed = {...listed}..remove(page);
    _removeContent(page, read.tick);
    pagesFreshSinceSession.add(page);
    goneByResult.add(page);
    _pageSettles(read, page);
  }

  void _removeContent(String page, int tick) {
    for (final MapEntry(:key, :value) in (content.remove(page) ?? {}).entries) {
      removedAt[key] = (tick, value);
    }
  }

  void _takeContent(String page, Items read, int tick) {
    final held = content[page] ?? const <String, int?>{};
    final next = <String, int?>{};
    for (final MapEntry(key: id, value: revision) in read.entries) {
      if (removedAt[id] case (
        final at,
        final last,
      ) when tick < at && (revision ?? -1) <= (last ?? -1)) {
        continue;
      }
      final elsewhere = rowPage(id);
      if (elsewhere != null &&
          elsewhere != page &&
          (content[elsewhere]![id] ?? -1) > (revision ?? -1)) {
        continue;
      }
      if (elsewhere != null && elsewhere != page) {
        content[elsewhere] = {...content[elsewhere]!}..remove(id);
      }
      next[id] = revision;
      removedAt.remove(id);
    }
    for (final MapEntry(:key, :value) in held.entries) {
      if (!read.containsKey(key)) removedAt[key] = (tick, value);
    }
    content[page] = next;
  }

  bool pageCurrent(String page) =>
      pagesFreshSinceSession.contains(page) &&
      !(goneByResult.contains(page) && listed.contains(page));
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
      case AnswerFact(:final tick, :final point):
        final reads = order.skip(at + 1).whereType<ReadFact>();
        if (reads.any((read) => read.tick < tick)) {
          count('a read older than our answer delivered after it');
        }
        if (reads.any(
          (read) =>
              point.generation.isBefore(read.point.generation) &&
              (read.point.serverTime ?? 0) < (point.serverTime ?? 0),
        )) {
          count(
            'a read on a later connection with a server time below our answer',
          );
        }
        if (order
            .take(at)
            .whereType<ReadFact>()
            .any((read) => read.tick == tick)) {
          count('an answer at the point of a read delivered before it');
        }
    }
  }
  if (reads.any((read) => read.base is PageGone)) {
    count('orders with a page gone');
  }
  final itemPages = <String, Set<String>>{};
  for (final read in reads) {
    if (read.base case PageRead(:final page, :final elements)) {
      for (final row in elements) {
        (itemPages[row.publicId] ??= {}).add(page.publicId);
      }
    }
  }
  if (itemPages.values.any((pages) => pages.length > 1)) {
    count('orders with an item read on two pages');
  }
  if (reads.any((read) => read.base is StrategyGone)) {
    count('orders with the strategy gone');
  }
  final points = <ResultPoint>{};
  if (reads.any((read) => !points.add(read.point))) {
    count('orders with two reads of one snapshot');
  }
}

final class Delivery {
  Delivery(this.queue) : labelsFrom = {0: queue.session.labelsFrom};

  CloudQueue queue;
  final Map<int, int> labelsFrom;

  void _step(QueueEvent event) {
    queue = transition(queue, event, now: now).queue;
  }

  void deliver(Fact fact) {
    switch (fact) {
      case RestartFact(:final run, :final generation):
        _step(const AppRestarted(build: build));
        _step(ConnectionReturned(generation));
        labelsFrom[run] = queue.session.labelsFrom;
      case ReconnectFact(:final generation):
        _step(ConnectionReturned(generation));
      case ReadFact(:final base, :final point, :final run):
        _step(BaseArrived(base, session: labelsFrom[run]!, point: point));
      case AnswerFact(:final work, :final answer, :final point):
        _step(OpAnswered(work.attempt, answer, point: point));
    }
  }
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
    ...shown.pagesSeen.keys,
    ...want.pagesFreshSinceSession,
  }) {
    final listFresh = shown.listCurrentFor(page);
    final wantListFresh = want.listCurrentFor(page);
    if (listFresh != wantListFresh) {
      return 'the page list is ${listFresh ? '' : 'not '}current for $page, '
          'the reference says ${wantListFresh ? '' : 'not '}current';
    }
    final pageFresh = shown.pageCurrent(page);
    final wantPageFresh = want.pageCurrentNow(page);
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
      seedsPerFamily * families;
  final one = int.tryParse(Platform.environment['ARRIVAL_ORDER_SEED'] ?? '');
  final family = int.tryParse(
    Platform.environment['ARRIVAL_ORDER_FAMILY'] ?? '',
  );
  test('after every read and own answer delivered, in every order, the queue '
      'holds what a model of the server says: per-subject order and sessions; '
      'whether the page list and each page are current, by the marks our '
      'answers leave and what each result shows; which pages '
      'exist is decided by the newest claim about that page, whatever kind of '
      'result made it, so a list leaves alone a page whose own result is '
      'newer and a page result older than the list changes nothing about '
      'existence; a page read newer than a list that does not show it owes '
      'the list', () {
    var checked = 0;
    for (final seed
        in one == null
            ? [
                for (var s = 1; s <= seeds; s++)
                  if (family == null || familyOf(s) == family) s,
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
        final delivery = Delivery(scenario.start);
        for (final (at, fact) in order.indexed) {
          want.apply(fact);
          delivery.deliver(fact);
          if (disagreement(delivery.queue, want) case final problem?) {
            fail(
              'seed $seed, after event ${at + 1}: $problem\n'
              'states: ${[for (final state in scenario.states) '${state.index}${state.exists ? '' : ' (deleted)'}'].join(', ')}\n'
              'order:\n  ${order.join('\n  ')}',
            );
          }
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
  'an older list leaving a page out after a newer read of it, kept': 400,
  'a read older than our answer delivered after it': 6000,
  'a read on a later connection with a server time below our answer': 3400,
  'an answer at the point of a read delivered before it': 4500,
  'orders with an item read on two pages': 15000,
};
