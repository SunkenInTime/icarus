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

sealed class Ask {
  const Ask();
}

final class NotAsked extends Ask {
  const NotAsked();
}

final class AskedAtStart extends Ask {
  const AskedAtStart();
}

final class AskedAfter extends Ask {
  const AskedAfter(this.answer);

  final AnswerFact answer;
}

final class ReadFact extends Fact {
  ReadFact(
    this.page,
    this.state,
    this.point,
    this.run, {
    required this.tick,
    this.asked = const NotAsked(),
  });

  final String? page;
  final ServerState state;
  final ResultPoint point;
  final int run;
  final int tick;
  final Ask asked;

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
      '${point.snapshot} run $run${switch (asked) {
        NotAsked() => '',
        AskedAtStart() => ', asked at the start',
        AskedAfter(:final answer) => ', asked after the ${answer.work.op.opId} '
            'answer',
      }}';
}

final class OwnWork {
  const OwnWork(
    this.op,
    this.attempt, {
    required this.page,
    required this.changesList,
  });

  final StrategyOp op;
  final int attempt;
  final String page;
  final bool changesList;
}

final class AnswerFact extends Fact {
  AnswerFact(this.work, this.answer, this.point, {required this.tick});

  final OwnWork work;
  final OpAnswer answer;
  final ResultPoint point;
  final int tick;

  bool get refused => answer is RejectedAnswer;

  @override
  String toString() =>
      '${work.op.opId} ${refused ? 'refused' : 'applied'} at '
      '${point.client}/${point.connection}/${point.snapshot}';
}

const reorder = PageReorderOp(
  opId: 'reorder',
  pagePublicId: 'page-b',
  sortIndex: 0,
  expectedStrategyRevision: 1,
);

const rename = PagePatchOp(
  opId: 'rename',
  pagePublicId: 'page-a',
  expectedPageRevision: 1,
  name: 'Mine',
);

final move = movePatch('move', x: 40);

List<StrategyOp> queuedIn(int family) => switch (family) {
  6 => [reorder, rename],
  7 || 8 || 9 => [move],
  _ => const [],
};

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
    final queued = queuedIn(seed % families);
    if (queued.isNotEmpty) {
      client.must(reconnected());
      client.read(initialRows());
      queued.forEach(client.edit);
      final first = queued.first;
      work = OwnWork(
        first,
        client.claim([first.opId]),
        page: first == reorder ? 'page-b' : 'page-a',
        changesList: first == reorder,
      );
    }
    start = client.queue;
    lastStamp = lastPoint;
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
  OwnWork? work;
  late ResultPoint lastStamp;
  int tick = 0;
  bool readHere = false;

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

  void read(String? page, {Ask asked = const NotAsked()}) {
    pass();
    _readAt(page, stamps.at(now), asked);
  }

  void readAtHeldPoint(String page, Ask asked) {
    pass();
    _readAt(page, stamps.answered, asked);
  }

  void _readAt(String? page, ResultPoint point, Ask asked) {
    readHere = true;
    facts.add(
      ReadFact(page, now, point, run, tick: tickOf(point), asked: asked),
    );
  }

  void lands(StrategyOp op) => write(withOp(now.rows, op));

  AnswerFact answer({required bool atHeldPoint, bool refused = false}) {
    final work = this.work!;
    if (atHeldPoint && !readHere) fail('no read holds a point to answer at');
    pass();
    final point = atHeldPoint ? stamps.answered : stamps.at(now);
    final row = switch (checkTargetOf(work.op)) {
      StrategyTarget() => now.rows.strategy,
      ElementTarget(:final elementPublicId) => now.rows.element(
        elementPublicId,
      )!,
      final other => fail('no checked row for $other'),
    };
    final fact = AnswerFact(
      work,
      refused
          ? RejectedAnswer(
              work.op.opId,
              RejectionReason.rowReplaced,
              const NoServerCopy(),
            )
          : AppliedAnswer(
              work.op.opId,
              revision: revisionOfRowForTest(row)!,
              life: createdAtOf(row)!,
            ),
      point,
      tick: tickOf(point),
    );
    facts.add(fact);
    return fact;
  }

  void teammateRenames(String page) => write(
    withOp(
      now.rows,
      onVisible(
        now.rows,
        PagePatchOp(
          opId: 't${states.length}',
          pagePublicId: page,
          expectedPageRevision: 1,
          name: 'Theirs',
        ),
      ),
    ),
  );

  void reconnectOnce() {
    pass();
    facts.add(ReconnectFact(stamps.reconnect(), run));
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
      case 5:
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
      case 6:
        lands(reorder);
        read(null);
        if (random.nextInt(3) == 0) read('page-b');
        teammateRenames('page-a');
        if (random.nextInt(3) == 0) read(null);
        answer(atHeldPoint: readHere && random.nextInt(4) == 0);
        if (random.nextBool()) read(null);
        if (random.nextInt(3) == 0) read('page-a');
      case 7:
        if (random.nextInt(4) != 0) reconnectOnce();
        read('page-a', asked: const AskedAtStart());
        if (random.nextBool()) teammateWrites('page-a');
        final refusal = answer(atHeldPoint: false, refused: true);
        switch (random.nextInt(4)) {
          case 0:
            read('page-a', asked: AskedAfter(refusal));
          case 1:
            reconnectOnce();
            read('page-a');
          case _:
            break;
        }
      case 8:
        lands(move);
        if (random.nextInt(3) == 0) read(null);
        read('page-a');
        answer(atHeldPoint: random.nextInt(3) != 0);
        if (random.nextBool()) read('page-a');
        if (random.nextInt(3) == 0) read(null);
      case _:
        if (random.nextInt(3) == 0) read(null);
        read('page-a');
        final refusal = answer(atHeldPoint: true, refused: true);
        readAtHeldPoint('page-a', AskedAfter(refusal));
        if (random.nextBool()) read('page-a', asked: AskedAfter(refusal));
    }
  }
}

const families = 10;

final class Reference {
  Reference(ServerState first, this.held)
    : listAt = 0,
      listed = livePagesOf(first.rows),
      pages = {
        for (final page in first.rows.pages)
          page.publicId: (at: 0, items: itemsOf(first.rows, page.publicId)),
      },
      pagesThisSession = livePagesOf(first.rows),
      readFirst = livePagesOf(first.rows);

  int listAt;
  Set<String> listed;
  bool gone = false;
  int? owedSince;
  final Map<String, ({int at, Items? items})> pages;
  int run = 0;
  Generation? held;
  int session = 0;
  bool listThisSession = true;
  final Set<String> pagesThisSession;
  ReadFact? listTaken;
  final pageTaken = <String, ReadFact>{};
  bool listReadFirst = true;
  final Set<String> readFirst;
  final debts = <String, ({int session, AnswerFact refusal})>{};
  final landed = <String>{};

  static Set<String> livePagesOf(StrategyRows rows) => {
    for (final page in rows.pages)
      if (page is LivePage) page.publicId,
  };

  static Items itemsOf(StrategyRows rows, String page) => {
    for (final row in rows.elementsOn(page))
      row.publicId: revisionOfRowForTest(row),
  };

  static bool before(Generation a, Generation b) =>
      a.client < b.client ||
      (a.client == b.client && a.connection < b.connection);

  static bool reaches(ReadFact read, AnswerFact answer) =>
      read.tick >= answer.tick &&
      switch ((answer.point.serverTime, read.point.serverTime)) {
        (null, _) => true,
        (_, null) => false,
        (final answered?, final shown?) => shown >= answered,
      };

  final answers = <AnswerFact>[];

  static bool readsPast(
    ReadFact? read,
    Iterable<AnswerFact> answers, {
    required bool readFirst,
  }) => switch (read) {
    final read? => answers.every((answer) => reaches(read, answer)),
    null => readFirst && answers.isEmpty,
  };

  bool listCurrent() =>
      listThisSession &&
      owedSince == null &&
      readsPast(
        listTaken,
        answers.where((a) => a.work.changesList),
        readFirst: listReadFirst,
      );

  bool listCurrentFor(String page) =>
      listCurrent() &&
      readsPast(
        listTaken,
        answers.where((a) => a.work.page == page),
        readFirst: listReadFirst,
      );

  bool pageCurrent(String page) =>
      pagesThisSession.contains(page) &&
      readsPast(
        pageTaken[page],
        answers.where((a) => a.work.changesList || a.work.page == page),
        readFirst: readFirst.contains(page),
      );

  void newSession() {
    session++;
    listAt = -1;
    pages.updateAll((_, held) => (at: -1, items: held.items));
    if (owedSince != null) owedSince = -1;
    listThisSession = false;
    pagesThisSession.clear();
    listTaken = null;
    pageTaken.clear();
    listReadFirst = false;
    readFirst.clear();
  }

  bool admits(Generation generation) {
    if (held case final now? when before(generation, now)) return false;
    if (held case final now? when before(now, generation)) newSession();
    held = generation;
    return true;
  }

  void apply(Fact fact) {
    switch (fact) {
      case RestartFact(:final run, :final generation):
        this.run = run;
        held = generation;
        newSession();
        answers.clear();
      case ReconnectFact(:final generation):
        if (held case final now? when !before(now, generation)) return;
        newSession();
        held = generation;
      case ReadFact():
        _read(fact);
      case AnswerFact():
        _answer(fact);
    }
  }

  void _answer(AnswerFact answer) {
    if (!admits(answer.point.generation)) return;
    final page = answer.work.page;
    answers.add(answer);
    if (answer.refused) {
      debts[page] = (session: session, refusal: answer);
      pagesThisSession.remove(page);
    } else {
      landed.add(answer.work.op.opId);
    }
  }

  bool pays(ReadFact read, String page) => switch (debts[page]) {
    null => true,
    final debt =>
      session > debt.session ||
          before(debt.refusal.point.generation, read.point.generation) ||
          switch (read.asked) {
            AskedAfter(:final answer) => answer == debt.refusal,
            _ => false,
          },
  };

  void _pageTaken(ReadFact read, String page, {required bool live}) {
    if (live) {
      pagesThisSession.add(page);
    } else {
      pagesThisSession.remove(page);
    }
    debts.remove(page);
    pageTaken[page] = read;
  }

  void _read(ReadFact read) {
    if (read.run != run) return;
    if (!admits(read.point.generation)) return;
    final at = read.tick;
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
        listThisSession = true;
        listTaken = read;
      case StrategyGone():
        if (owedSince case final owed? when at < owed) return;
        if (at <= listAt) return;
        listAt = at;
        owedSince = null;
        gone = true;
        listThisSession = true;
        listTaken = read;
      case PageRead(:final page):
        final id = page.publicId;
        if (pages[id] case final held? when at < held.at) return;
        if (pages[id] case final held? when at == held.at) {
          if (pays(read, id) && debts.containsKey(id)) {
            debts.remove(id);
            pagesThisSession.add(id);
          }
          pageTaken[id] = read;
          return;
        }
        if (!pays(read, id)) return;
        if (!listed.contains(id)) {
          if (at < listAt) return;
          owedSince = max(owedSince ?? at, at);
          return;
        }
        pages[id] = (at: at, items: itemsOf(read.state.rows, id));
        _pageTaken(read, id, live: true);
      case PageGone(:final pagePublicId):
        if (pages[pagePublicId] case final held? when at <= held.at) return;
        if (!pays(read, pagePublicId)) return;
        if (listed.contains(pagePublicId) && at < listAt) return;
        pages[pagePublicId] = (at: at, items: null);
        listed = {...listed}..remove(pagePublicId);
        _pageTaken(read, pagePublicId, live: false);
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
    AnswerFact() => 0,
  };
  bool allowed(int index) {
    if (facts[index] case ReadFact(
      asked: AskedAfter(:final answer),
    ) when !used[facts.indexOf(answer)]) {
      return false;
    }
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

void countCases(List<Fact> order, Generation? started) {
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
            .any(
              (read) => Reference.before(read.point.generation, generation),
            )) {
          count('a read from an earlier connection after a reconnect event');
        }
      case ReadFact() || AnswerFact():
        break;
    }
  }
  countOwnWork(order, started);
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

void countOwnWork(List<Fact> order, Generation? started) {
  for (final (at, fact) in order.indexed) {
    if (fact is! AnswerFact) continue;
    final before = order.take(at).toList();
    final after = order.skip(at + 1).toList();
    if (fact.work.changesList &&
        after.whereType<ReadFact>().any(
          (read) => read.page == null && read.tick < fact.tick,
        )) {
      count('a list older than our answer delivered after it');
    }
    if (fact.refused &&
        !before.any((other) => other is ReconnectFact) &&
        started != null &&
        Reference.before(started, fact.point.generation) &&
        after.whereType<ReadFact>().any(
          (read) =>
              read.asked is AskedAtStart &&
              read.point.generation == fact.point.generation &&
              read.tick < fact.tick,
        )) {
      count(
        'a read asked in one session delivered after a refusal opened '
        'the next',
      );
    }
    if (!fact.refused &&
        before.whereType<ReadFact>().any(
          (read) => read.page == fact.work.page && read.tick == fact.tick,
        )) {
      count('an answer at the point of a page result delivered before it');
    }
    if (fact.refused &&
        before.whereType<ReadFact>().any(
          (read) => read.page == fact.work.page && read.tick == fact.tick,
        ) &&
        after.whereType<ReadFact>().any(
          (read) => read.asked is AskedAfter && read.tick == fact.tick,
        )) {
      count('a repeat at the point of a taken result after a refusal there');
    }
  }
}

CloudQueue deliver(CloudQueue start, List<Fact> order) {
  var queue = start;
  final labelsFrom = <int, int>{0: start.session.labelsFrom};
  final askedAfter = <AnswerFact, (int, int)>{};
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
      case AnswerFact(:final work, :final answer, :final point):
        step(OpAnswered(work.attempt, answer, point: point));
        askedAfter[fact] = (queue.session.number, queue.session.sequence);
      case ReadFact(:final base, :final point, :final run, :final asked):
        final (session, requestedAt) = switch (asked) {
          NotAsked() => (labelsFrom[run]!, null),
          AskedAtStart() => (start.session.number, start.session.sequence),
          AskedAfter(:final answer) => askedAfter[answer]!,
        };
        step(
          BaseArrived(
            base,
            session: session,
            point: point,
            requestedAt: requestedAt,
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
          '${wanted ?? 'nothing'} from ${want.pages[page]?.at}';
    }
  }
  if (shown.listCurrent != want.listCurrent()) {
    return 'the page list is ${shown.listCurrent ? '' : 'not '}current, the '
        'reference says ${want.listCurrent() ? '' : 'not '}current';
  }
  for (final page in {...listed, ...want.listed, ...want.debts.keys}) {
    if (shown.listCurrentFor(page) != want.listCurrentFor(page)) {
      return 'the page list is ${shown.listCurrentFor(page) ? '' : 'not '}'
          'current for $page, the reference says '
          '${want.listCurrentFor(page) ? '' : 'not '}current';
    }
    if (shown.pageCurrent(page) != want.pageCurrent(page)) {
      return 'page $page is ${shown.pageCurrent(page) ? '' : 'not '}current, '
          'the reference says ${want.pageCurrent(page) ? '' : 'not '}current';
    }
    if (isDebt(shown.pageRead(page)) != want.debts.containsKey(page)) {
      return 'page $page is ${shown.pageRead(page)}, the reference '
          '${want.debts.containsKey(page) ? 'owes a read after the refusal' : 'owes nothing'}';
    }
  }
  if (entryViews(queue, now)['rename'] case final view?) {
    final waits = view.holds.any((hold) => hold is AwaitingResult);
    final shouldWait =
        want.landed.contains('reorder') && !want.listCurrentFor('page-a');
    if (waits != shouldWait) {
      return 'the rename ${waits ? 'waits' : 'does not wait'} for a result '
          '(${view.state}, ${view.holds}), the reference says it '
          '${shouldWait ? 'waits' : 'does not'}';
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
  test('reads delivered in every order end where a model of the server says, '
      'whatever their stamps', () {
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
        countCases(order, scenario.start.session.generation);
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
    if (one != null || family != null) return;
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
  'an older list leaving a page out after a newer read of it': 850,
  'an older page-gone after a newer list showing the page': 700,
  'a list older than our answer delivered after it': 1800,
  'a read asked in one session delivered after a refusal opened the next': 300,
  'an answer at the point of a page result delivered before it': 350,
  'a repeat at the point of a taken result after a refusal there': 120,
};
