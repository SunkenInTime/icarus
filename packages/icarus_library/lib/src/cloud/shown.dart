import 'package:collection/collection.dart';

import '../rows.dart';
import '../strategy_rows.dart';
import 'events.dart';
import 'op_facts.dart';
import 'pending.dart';
import 'version.dart';

bool shownTakesChecked =
    const bool.fromEnvironment('ICARUS_DRIVE') ||
    !const bool.fromEnvironment('dart.vm.product');

bool shownTakesReuse = true;

final class ShownWork {
  int contentRowsDigested = 0;

  void reset() {
    contentRowsDigested = 0;
  }
}

final shownWork = ShownWork();

final class TakesDiffer extends StateError {
  TakesDiffer(String page)
    : differingPage = page,
      super(
        'page $page taken with digests of this run differs from the same '
        'result taken from scratch',
      );

  TakesDiffer.group(String? page)
    : differingPage = null,
      super(
        'the stored results of ${page ?? 'the page list'} kept from before '
        'differ from encoding them again',
      );

  final String? differingPage;
}

final class ShownRow {
  const ShownRow({
    required this.page,
    required this.revision,
    required this.digest,
    this.life,
    this.digestedThisRun = false,
  });

  final String page;
  final int? revision;
  final int? life;
  final String digest;
  final bool digestedThisRun;

  bool holdsDigestOf(Row row, String page) =>
      digestedThisRun &&
      revision != null &&
      this.page == page &&
      revision == revisionOfRow(row) &&
      life == createdAtOf(row);

  Version? get version => switch (revision) {
    final revision? => Version(revision, life: life),
    null => null,
  };

  @override
  bool operator ==(Object other) =>
      other is ShownRow &&
      other.page == page &&
      other.revision == revision &&
      other.life == life &&
      other.digest == digest;

  @override
  int get hashCode => Object.hash(page, revision, life, digest);
}

final class Seen {
  const Seen(this.at, {this.gone = false});

  final Arrival? at;
  final bool gone;

  bool reaches(AfterAnswer? mark) =>
      mark == null || (at != null && mark.reachedBy(at!));

  @override
  bool operator ==(Object other) =>
      other is Seen && other.at == at && other.gone == gone;

  @override
  int get hashCode => Object.hash(at, gone);
}

final class Freshness {
  Freshness._({
    required this.listRead,
    required Set<String> listed,
    required Map<String, Seen> pagesRead,
    required this.listMark,
    required Map<String, AfterAnswer> listMarks,
    required this.allPagesMark,
    required Map<String, AfterAnswer> pageMarks,
  }) : listed = Set.unmodifiable(listed),
       pagesRead = Map.unmodifiable(pagesRead),
       listMarks = Map.unmodifiable(listMarks),
       pageMarks = Map.unmodifiable(pageMarks);

  static final none = Freshness._(
    listRead: null,
    listed: const {},
    pagesRead: const {},
    listMark: null,
    listMarks: const {},
    allPagesMark: null,
    pageMarks: const {},
  );

  final Seen? listRead;
  final Set<String> listed;
  final Map<String, Seen> pagesRead;
  final AfterAnswer? listMark;
  final Map<String, AfterAnswer> listMarks;
  final AfterAnswer? allPagesMark;
  final Map<String, AfterAnswer> pageMarks;

  Freshness _copy({
    Seen? listRead,
    bool forgetReads = false,
    Set<String>? listed,
    Map<String, Seen>? pagesRead,
    AfterAnswer? listMark,
    Map<String, AfterAnswer>? listMarks,
    AfterAnswer? allPagesMark,
    Map<String, AfterAnswer>? pageMarks,
  }) => Freshness._(
    listRead: forgetReads ? null : listRead ?? this.listRead,
    listed: listed ?? this.listed,
    pagesRead: pagesRead ?? this.pagesRead,
    listMark: listMark ?? this.listMark,
    listMarks: listMarks ?? this.listMarks,
    allPagesMark: allPagesMark ?? this.allPagesMark,
    pageMarks: pageMarks ?? this.pageMarks,
  );

  Freshness afterList(Iterable<String> live, Arrival? arrival) =>
      _copy(listRead: Seen(arrival), listed: {...live});

  Freshness afterPage(
    String page, {
    required bool gone,
    required Arrival? arrival,
  }) => _copy(pagesRead: {...pagesRead, page: Seen(arrival, gone: gone)});

  Freshness touched(
    Iterable<String> pages, {
    required bool list,
    required AfterAnswer mark,
  }) => list
      ? _copy(listMark: mark.and(listMark), allPagesMark: mark.and(allPagesMark))
      : _copy(
          listMarks: {
            ...listMarks,
            for (final page in pages) page: mark.and(listMarks[page]),
          },
          pageMarks: {
            ...pageMarks,
            for (final page in pages) page: mark.and(pageMarks[page]),
          },
        );

  Freshness get inNewSession =>
      _copy(forgetReads: true, listed: const {}, pagesRead: const {});

  bool get listSinceTouch => listRead?.reaches(listMark) ?? false;

  bool listFreshFor(String page) =>
      listSinceTouch && listRead!.reaches(listMarks[page]);

  bool pageFreshFor(String page) => switch (pagesRead[page]) {
    final seen? => seen.reaches(allPagesMark) && seen.reaches(pageMarks[page]),
    null => false,
  };

  bool goneByResult(String page) => pagesRead[page]?.gone ?? false;

  Set<String> get subjects => {
    ...listed,
    ...pagesRead.keys,
    ...listMarks.keys,
    ...pageMarks.keys,
  };

  bool freshFor(String page) =>
      listFreshFor(page) && (pageFreshFor(page) || !listed.contains(page));

  bool disagreeOn(String page) =>
      listFreshFor(page) &&
      pageFreshFor(page) &&
      listed.contains(page) == goneByResult(page);

  @override
  bool operator ==(Object other) =>
      other is Freshness &&
      other.listRead == listRead &&
      const SetEquality<String>().equals(other.listed, listed) &&
      const MapEquality<String, Seen>().equals(other.pagesRead, pagesRead) &&
      other.listMark == listMark &&
      const MapEquality<String, AfterAnswer>().equals(
        other.listMarks,
        listMarks,
      ) &&
      other.allPagesMark == allPagesMark &&
      const MapEquality<String, AfterAnswer>().equals(
        other.pageMarks,
        pageMarks,
      );

  @override
  int get hashCode => Object.hash(listRead, listed.length, listMark);
}

final class ResultOrder {
  const ResultOrder({
    required this.session,
    required this.client,
    required this.snapshot,
  });

  static const beforeAnyResult = ResultOrder(
    session: 0,
    client: 0,
    snapshot: 0,
  );

  final int session;
  final int client;
  final int snapshot;

  bool isBefore(ResultOrder other) =>
      session < other.session ||
      (session == other.session &&
          (client < other.client ||
              (client == other.client && snapshot < other.snapshot)));

  @override
  bool operator ==(Object other) =>
      other is ResultOrder &&
      other.session == session &&
      other.client == client &&
      other.snapshot == snapshot;

  @override
  int get hashCode => Object.hash(session, client, snapshot);

  @override
  String toString() => 'session $session, client $client, snapshot $snapshot';
}

final class Arrival {
  const Arrival({
    required this.order,
    required this.point,
    this.requestedAt,
    this.requestedIn,
  });

  final ResultOrder order;
  final ResultPoint point;
  final int? requestedAt;
  final int? requestedIn;

  bool requestedAtOrAfter(int session, int step) =>
      requestedIn == session && (requestedAt ?? -1) >= step;

  @override
  bool operator ==(Object other) =>
      other is Arrival &&
      other.order == order &&
      other.point == point &&
      other.requestedAt == requestedAt &&
      other.requestedIn == requestedIn;

  @override
  int get hashCode => Object.hash(order, point, requestedAt, requestedIn);
}

sealed class Evidence {
  const Evidence();

  bool shownBy(ArrivedBase base);
}

final class RowAtLeast extends Evidence {
  const RowAtLeast(this.target, {required this.life, required this.revision});

  final Target target;
  final int? life;
  final int revision;

  @override
  bool shownBy(ArrivedBase base) {
    final row = rowIn(base, target);
    if (row == null) return false;
    final (shownLife, shownRevision) = (createdAtOf(row), revisionOfRow(row));
    if (shownRevision == null) return false;
    return switch ((life, shownLife)) {
      (final wanted?, final shown?) when shown != wanted => shown > wanted,
      (final _?, null) => false,
      _ => shownRevision >= revision,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is RowAtLeast &&
      other.target == target &&
      other.life == life &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(RowAtLeast, target, life, revision);
}

final class StrategyLifeAtLeast extends Evidence {
  const StrategyLifeAtLeast(this.life);

  final int life;

  @override
  bool shownBy(ArrivedBase base) => switch (base) {
    HeaderRead(:final strategy) => (createdAtOf(strategy) ?? 0) >= life,
    _ => false,
  };

  @override
  bool operator ==(Object other) =>
      other is StrategyLifeAtLeast && other.life == life;

  @override
  int get hashCode => Object.hash(StrategyLifeAtLeast, life);
}

Row? rowIn(ArrivedBase base, Target target) => switch ((base, target)) {
  (HeaderRead(:final strategy), StrategyTarget()) => strategy,
  (HeaderRead(:final pages), PageTarget(:final pagePublicId)) =>
    pages.where((page) => page.publicId == pagePublicId).firstOrNull,
  (HeaderRead(:final settings), SettingsTarget(:final pagePublicId)) =>
    settings.where((row) => row.pagePublicId == pagePublicId).firstOrNull,
  (PageRead(:final elements), ElementTarget(:final elementPublicId)) =>
    elements.where((row) => row.publicId == elementPublicId).firstOrNull,
  (PageRead(:final lineupGroups), LineupTarget(:final lineupPublicId)) =>
    lineupGroups.where((row) => row.publicId == lineupPublicId).firstOrNull,
  _ => null,
};

sealed class PaidBy {
  const PaidBy();

  bool paidBy(Arrival arrival, ArrivedBase? base);
}

final class ResultAtOrAfter extends PaidBy {
  const ResultAtOrAfter(this.order);

  static const anyResult = ResultAtOrAfter(ResultOrder.beforeAnyResult);

  final ResultOrder order;

  @override
  bool paidBy(Arrival arrival, ArrivedBase? base) =>
      !arrival.order.isBefore(order);

  @override
  bool operator ==(Object other) =>
      other is ResultAtOrAfter && other.order == order;

  @override
  int get hashCode => Object.hash(ResultAtOrAfter, order);

  @override
  String toString() => 'a result at or after $order';
}

final class AfterRefusal extends PaidBy {
  const AfterRefusal({
    required this.session,
    required this.point,
    required this.step,
    this.evidence,
  });

  final int session;
  final ResultPoint point;
  final int step;
  final Evidence? evidence;

  @override
  bool paidBy(Arrival arrival, ArrivedBase? base) =>
      (base != null && (evidence?.shownBy(base) ?? false)) ||
      arrival.order.session > session ||
      (arrival.order.session == session &&
          (point.generation.isBefore(arrival.point.generation) ||
              arrival.requestedAtOrAfter(session, step)));

  @override
  bool operator ==(Object other) =>
      other is AfterRefusal &&
      other.session == session &&
      other.point == point &&
      other.step == step &&
      other.evidence == evidence;

  @override
  int get hashCode => Object.hash(AfterRefusal, session, point, step, evidence);

  @override
  String toString() =>
      'content, a later connection, client or session, or a read requested '
      'after step $step of session $session';
}

final class AfterAnswer extends PaidBy {
  const AfterAnswer(this.order, {this.serverTime});

  final ResultOrder order;
  final int? serverTime;

  bool reachedBy(Arrival arrival) =>
      !arrival.order.isBefore(order) &&
      switch ((serverTime, arrival.point.serverTime)) {
        (null, _) => true,
        (_, null) => false,
        (final answered?, final shown?) => shown >= answered,
      };

  AfterAnswer and(AfterAnswer? other) => switch (other) {
    null => this,
    final other => AfterAnswer(
      order.isBefore(other.order) ? other.order : order,
      serverTime: switch ((serverTime, other.serverTime)) {
        (final mine?, final theirs?) => mine > theirs ? mine : theirs,
        (final mine, final theirs) => mine ?? theirs,
      },
    ),
  };

  @override
  bool paidBy(Arrival arrival, ArrivedBase? base) => reachedBy(arrival);

  @override
  bool operator ==(Object other) =>
      other is AfterAnswer &&
      other.order == order &&
      other.serverTime == serverTime;

  @override
  int get hashCode => Object.hash(AfterAnswer, order, serverTime);

  @override
  String toString() => 'a result at or after $order and time $serverTime';
}

final class AllOf extends PaidBy {
  AllOf._(Iterable<PaidBy> each) : each = Set.unmodifiable(each);

  final Set<PaidBy> each;

  @override
  bool paidBy(Arrival arrival, ArrivedBase? base) =>
      each.every((debt) => debt.paidBy(arrival, base));

  @override
  bool operator ==(Object other) =>
      other is AllOf && const SetEquality<PaidBy>().equals(other.each, each);

  @override
  int get hashCode => Object.hash(AllOf, Object.hashAllUnordered(each));

  @override
  String toString() => 'all of ${each.join('; ')}';
}

PaidBy both(PaidBy held, PaidBy added) {
  final each = [
    for (final debt in [held, added])
      if (debt case AllOf(each: final inner)) ...inner else debt,
  ];
  ResultAtOrAfter? atOrAfter;
  AfterAnswer? answer;
  final rest = <PaidBy>{};
  for (final debt in each) {
    switch (debt) {
      case ResultAtOrAfter(:final order):
        atOrAfter = switch (atOrAfter) {
          ResultAtOrAfter(order: final mine) when !mine.isBefore(order) =>
            atOrAfter,
          _ => debt,
        };
      case AfterAnswer():
        answer = debt.and(answer);
      case AllOf() || AfterRefusal():
        rest.add(debt);
    }
  }
  final combined = {
    if (atOrAfter != ResultAtOrAfter.anyResult) ?atOrAfter,
    ?answer,
    ...rest,
  };
  if (combined.isEmpty) return ResultAtOrAfter.anyResult;
  return combined.length == 1 ? combined.single : AllOf._(combined);
}

PaidBy oweAlso(ReadState state, PaidBy added) => switch (state) {
  ReadOwed(:final since) || ReadRefused(:final since) => both(since, added),
  NotReadThisSession() || ReadThisSession() => added,
};

int? _later(int? held, int? added) => switch ((held, added)) {
  (final a?, final b?) => a > b ? a : b,
  (final a, final b) => a ?? b,
};

bool paidBy(ReadState state, Arrival? arrival, ArrivedBase base) =>
    switch (state) {
      ReadOwed(:final since) || ReadRefused(:final since) =>
        arrival != null && since.paidBy(arrival, base),
      NotReadThisSession() || ReadThisSession() => true,
    };

sealed class ReadState {
  const ReadState();

  ReadState get inNewSession => this;
}

final class NotReadThisSession extends ReadState {
  const NotReadThisSession();

  @override
  bool operator ==(Object other) => other is NotReadThisSession;

  @override
  int get hashCode => (NotReadThisSession).hashCode;

  @override
  String toString() => 'not read this session';
}

final class ReadThisSession extends ReadState {
  const ReadThisSession();

  @override
  ReadState get inNewSession => const NotReadThisSession();

  @override
  bool operator ==(Object other) => other is ReadThisSession;

  @override
  int get hashCode => (ReadThisSession).hashCode;

  @override
  String toString() => 'read this session';
}

final class ReadOwed extends ReadState {
  const ReadOwed({this.unlessLife, this.namedLife, required this.since});

  final int? unlessLife;
  final int? namedLife;
  final PaidBy since;

  @override
  bool operator ==(Object other) =>
      other is ReadOwed &&
      other.unlessLife == unlessLife &&
      other.namedLife == namedLife &&
      other.since == since;

  @override
  int get hashCode => Object.hash(ReadOwed, unlessLife, namedLife, since);

  @override
  String toString() => switch ((unlessLife, namedLife)) {
    (null, _) => 'owed',
    (final refused?, null) =>
      'owed by a list of another life than $refused, paid by $since',
    (_, final named?) =>
      'owed by a list of life $named or later, paid by $since',
  };
}

final class ReadRefused extends ReadState {
  const ReadRefused(
    this.problem, {
    this.unlessLife,
    this.namedLife,
    required this.since,
  });

  final String problem;
  final int? unlessLife;
  final int? namedLife;
  final PaidBy since;

  @override
  bool operator ==(Object other) =>
      other is ReadRefused &&
      other.problem == problem &&
      other.unlessLife == unlessLife &&
      other.namedLife == namedLife &&
      other.since == since;

  @override
  int get hashCode =>
      Object.hash(ReadRefused, problem, unlessLife, namedLife, since);

  @override
  String toString() => switch ((unlessLife, namedLife)) {
    (null, _) => 'refused: $problem',
    (final refused?, null) =>
      'refused: $problem, owed by a list of another life than $refused, '
          'paid by $since',
    (_, final named?) =>
      'refused: $problem, owed by a list of life $named or later, paid by '
          '$since',
  };
}

int? _refusedLifeOf(ReadState state) => switch (state) {
  ReadOwed(:final unlessLife) || ReadRefused(:final unlessLife) => unlessLife,
  NotReadThisSession() || ReadThisSession() => null,
};

int? namedLifeOf(ReadState state) => switch (state) {
  ReadOwed(:final namedLife) || ReadRefused(:final namedLife) => namedLife,
  NotReadThisSession() || ReadThisSession() => null,
};

bool isDebt(ReadState state) => state is ReadOwed || state is ReadRefused;

bool _isTrashed(PageRow page) => lifeOfRow(page) == Life.gone;

bool replaces(ShownRow? held, Row incoming) =>
    held == null || !_outranks(held.version, versionOfRow(incoming));

enum KeptBecause { heldIsNewer, leftByANewerResult }

final class Removed {
  const Removed(this.order, {required this.held});

  final ResultOrder order;
  final Version? held;

  bool keepsOut(Row row, ResultOrder? started) =>
      started != null &&
      started.isBefore(order) &&
      switch ((versionOfRow(row), held)) {
        (final incoming?, final held?) => !(incoming > held),
        (null, _) => true,
        (_?, null) => false,
      };

  @override
  bool operator ==(Object other) =>
      other is Removed && other.order == order && other.held == held;

  @override
  int get hashCode => Object.hash(order, held);

  @override
  String toString() => 'removed at $order, last held at $held';
}

enum PageSays { live, trashed, gone }

enum PageDecider { list, page, disagree }

PageDecider pageDecider({
  required Arrival? list,
  required PageSays listSays,
  required Arrival? page,
  required PageSays? pageSays,
}) => switch ((list, page, pageSays)) {
  (_, null, _) || (_, _, null) => PageDecider.list,
  (null, _, _) => PageDecider.page,
  (final list?, final page?, final says?) when list.order == page.order =>
    says == listSays ? PageDecider.page : PageDecider.disagree,
  (final list?, final page?, _) =>
    list.order.isBefore(page.order) ? PageDecider.page : PageDecider.list,
};

PageSays pageSaysOf(PageRow row) =>
    _isTrashed(row) ? PageSays.trashed : PageSays.live;

sealed class RowDecision {
  const RowDecision();
}

final class RowTaken extends RowDecision {
  const RowTaken(this.row);

  final Row row;

  @override
  bool operator ==(Object other) =>
      other is RowTaken && other.row.key == row.key && other.row == row;

  @override
  int get hashCode => Object.hash(RowTaken, row.key);

  @override
  String toString() => 'taken ${row.key}';
}

final class RowKept extends RowDecision {
  const RowKept(this.row, this.because);

  final Row row;
  final KeptBecause because;

  @override
  bool operator ==(Object other) =>
      other is RowKept && other.row.key == row.key && other.because == because;

  @override
  int get hashCode => Object.hash(RowKept, row.key, because);

  @override
  String toString() => 'kept ${row.key}: ${because.name}';
}

final class RowUnchanged extends RowDecision {
  const RowUnchanged(this.row);

  final Row row;

  @override
  bool operator ==(Object other) =>
      other is RowUnchanged && other.row.key == row.key && other.row == row;

  @override
  int get hashCode => Object.hash(RowUnchanged, row.key);

  @override
  String toString() => 'unchanged ${row.key}';
}

final class ItemLeft extends RowDecision {
  const ItemLeft(this.target, {required this.page});

  final Target target;
  final String page;

  @override
  bool operator ==(Object other) =>
      other is ItemLeft && other.target == target && other.page == page;

  @override
  int get hashCode => Object.hash(ItemLeft, target, page);

  @override
  String toString() => '$target left page $page';
}

final class PageLeft extends RowDecision {
  const PageLeft(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is PageLeft && other.page == page;

  @override
  int get hashCode => Object.hash(PageLeft, page);

  @override
  String toString() => 'page $page left';
}

final class SettingsLeft extends RowDecision {
  const SettingsLeft(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is SettingsLeft && other.page == page;

  @override
  int get hashCode => Object.hash(SettingsLeft, page);

  @override
  String toString() => 'settings of $page left';
}

final class UnreadableLeft extends RowDecision {
  UnreadableLeft(this.page, Iterable<Row> carried)
    : carried = List.unmodifiable(carried);

  final String page;
  final List<Row> carried;

  @override
  bool operator ==(Object other) =>
      other is UnreadableLeft &&
      other.page == page &&
      const SetEquality<RowKey>().equals(
        {for (final row in other.carried) row.key},
        {for (final row in carried) row.key},
      );

  @override
  int get hashCode => Object.hash(UnreadableLeft, page, carried.length);

  @override
  String toString() => 'unreadable rows of $page that the result left out left';
}

final class Taken {
  Taken(this.shown, Iterable<RowDecision> decisions)
    : decisions = List.unmodifiable(decisions);

  final Shown shown;
  final List<RowDecision> decisions;

  @override
  bool operator ==(Object other) =>
      other is Taken &&
      other.shown == shown &&
      const ListEquality<RowDecision>().equals(other.decisions, decisions);

  @override
  int get hashCode => Object.hash(shown, decisions.length);
}

final class Shown {
  Shown({
    required this.strategy,
    required Map<String, ShownRow> pages,
    required Map<String, ShownRow> settings,
    required Map<String, Map<SeenPart, String>> content,
    required Map<Target, ShownRow> rows,
    Map<String, ShownRow> trashed = const {},
    Map<Target, Removed> tombstones = const {},
    this.list = const NotReadThisSession(),
    Map<String, ReadState> pageReads = const {},
    Set<String> goneThisSession = const {},
    Map<Target, Version> highest = const {},
    Freshness? fresh,
    this.listTaken,
    Map<String, Arrival> pagesTaken = const {},
    Map<String, PageSays> listSaid = const {},
    Map<String, PageSays> pageSaid = const {},
    this.fence,
  }) : fresh = fresh ?? Freshness.none,
       pagesTaken = Map.unmodifiable(pagesTaken),
       listSaid = Map.unmodifiable(listSaid),
       pageSaid = Map.unmodifiable(pageSaid),
       pageReads = Map.unmodifiable({
         for (final MapEntry(:key, :value) in pageReads.entries)
           if (value is! NotReadThisSession) key: value,
       }),
       goneThisSession = Set.unmodifiable(goneThisSession),
       highest = Map.unmodifiable(highest),
       pages = Map.unmodifiable(pages),
       trashed = Map.unmodifiable(trashed),
       tombstones = Map.unmodifiable(tombstones),
       settings = Map.unmodifiable(settings),
       content = Map.unmodifiable(content),
       rows = Map.unmodifiable(rows);

  static final nothing = Shown(
    strategy: null,
    pages: const {},
    settings: const {},
    content: const {},
    rows: const {},
  );

  factory Shown.of(StrategyRowSet rows, {required Iterable<String> readPages}) {
    final read = {...readPages};
    var fresh = Freshness.none.afterList([
      for (final page in rows.pages)
        if (!_isTrashed(page)) page.publicId,
    ], null);
    for (final page in read) {
      fresh = fresh.afterPage(page, gone: false, arrival: null);
    }
    return Shown(
      fresh: fresh,
      list: const ReadThisSession(),
      pageReads: {for (final page in read) page: const ReadThisSession()},
      strategy: _strategyRow(rows.strategy, rows.pages),
      pages: {
        for (final page in rows.pages)
          if (!_isTrashed(page)) page.publicId: _rowOf(page, page),
      },
      trashed: {
        for (final page in rows.pages)
          if (_isTrashed(page)) page.publicId: _rowOf(page, page),
      },
      settings: {
        for (final row in rows.settings)
          row.pagePublicId: _rowOf(row, row.pagePublicId),
      },
      content: {
        for (final page in read)
          page: liveContentOn([
            ...rows.elementsOn(page),
            ...rows.lineupGroupsOn(page),
          ], page),
      },
      rows: {
        for (final page in read) ...{
          for (final row in rows.elementsOn(page))
            ElementTarget(row.publicId): _rowOf(row, page),
          for (final row in rows.lineupGroupsOn(page))
            LineupTarget(row.publicId): _rowOf(row, page),
        },
      },
      highest: {
        const StrategyTarget(): ?versionOfRow(rows.strategy),
        for (final page in rows.pages)
          if (!_isTrashed(page)) PageTarget(page.publicId): ?versionOfRow(page),
        for (final row in rows.settings)
          SettingsTarget(row.pagePublicId): ?versionOfRow(row),
        for (final page in read) ...{
          for (final row in rows.elementsOn(page))
            ElementTarget(row.publicId): ?versionOfRow(row),
          for (final row in rows.lineupGroupsOn(page))
            LineupTarget(row.publicId): ?versionOfRow(row),
        },
      },
    );
  }

  final ShownRow? strategy;
  final Freshness fresh;
  final ReadState list;
  final Map<String, ReadState> pageReads;
  final Arrival? listTaken;
  final Map<String, Arrival> pagesTaken;
  final Map<String, PageSays> listSaid;
  final Map<String, PageSays> pageSaid;

  PageDecider decidesPage(String page, Arrival arrival, PageSays says) =>
      pageDecider(
        list: listTaken,
        listSays: listSaid[page] ?? PageSays.gone,
        page: arrival,
        pageSays: says,
      );

  Set<String> disagreeingPages(HeaderRead result, Arrival? arrival) => {
    for (final page in {...knownPages, ...pageSaid.keys})
      if (pageDecider(
            list: arrival,
            listSays: _listSays(result, page),
            page: pagesTaken[page],
            pageSays: pageSaid[page],
          ) ==
          PageDecider.disagree)
        page,
  };

  static PageSays _listSays(HeaderRead result, String page) =>
      switch (result.pages.where((row) => row.publicId == page).firstOrNull) {
        final row? => pageSaysOf(row),
        null => PageSays.gone,
      };
  final ResultOrder? fence;

  PaidBy? owedBy(ArrivedBase result) => switch (switch (result) {
    HeaderRead() || StrategyGone() => list,
    PageRead(:final page) => pageRead(page.publicId),
    PageGone(:final pagePublicId) => pageRead(pagePublicId),
  }) {
    ReadOwed(:final since) || ReadRefused(:final since) => since,
    NotReadThisSession() || ReadThisSession() => null,
  };

  Shown fencedAt(ResultOrder fence, {required Shown after}) => Shown(
    strategy: strategy,
    pages: pages,
    trashed: trashed,
    tombstones: tombstones,
    settings: settings,
    content: content,
    rows: rows,
    list: list,
    pageReads: pageReads,
    goneThisSession: goneThisSession,
    highest: highest,
    fresh: fresh,
    listTaken: listTaken ?? after.listTaken,
    pagesTaken: {...after.pagesTaken, ...pagesTaken},
    listSaid: listTaken == null ? after.listSaid : listSaid,
    pageSaid: {...after.pageSaid, ...pageSaid},
    fence: fence,
  );

  Arrival? takenFor(ArrivedBase result) => takenOf(switch (result) {
    HeaderRead() || StrategyGone() => null,
    PageRead(:final page) => page.publicId,
    PageGone(:final pagePublicId) => pagePublicId,
  });

  Arrival? takenOf(String? page) => page == null ? listTaken : pagesTaken[page];

  int? get strategyRevision => strategy?.revision;

  static ShownRow _strategyRow(StrategyRow row, Iterable<PageRow> pages) =>
      ShownRow(
        page: '',
        revision: revisionOfRow(row),
        life: createdAtOf(row),
        digest: strategyDigest(row, pages),
      );
  final Set<String> goneThisSession;
  final Map<Target, Version> highest;
  final Map<String, ShownRow> pages;
  final Map<String, ShownRow> trashed;
  final Map<Target, Removed> tombstones;
  final Map<String, ShownRow> settings;
  final Map<String, Map<SeenPart, String>> content;
  final Map<Target, ShownRow> rows;

  bool get headerThisSession => list is ReadThisSession;

  bool get listCurrent => headerThisSession && fresh.listSinceTouch;

  bool listCurrentFor(String page) =>
      headerThisSession && fresh.listFreshFor(page);

  bool pageCurrent(String page) =>
      pageReadThisSession(page) && fresh.pageFreshFor(page);

  bool pageReadThisSession(String page) => pageReads[page] is ReadThisSession;

  ReadState pageRead(String page) =>
      pageReads[page] ?? const NotReadThisSession();

  Set<String> get pagesToRead => {
    for (final page in pages.keys)
      if (!content.containsKey(page) || pageRead(page) is ReadOwed) page,
  };

  static ShownRow _rowOf(Row row, Object page) => ShownRow(
    page: switch (page) {
      final String id => id,
      PageRow(:final publicId) => publicId,
      _ => '',
    },
    revision: revisionOfRow(row),
    life: createdAtOf(row),
    digest: rowDigest(row),
    digestedThisRun: true,
  );

  static ShownRow _digested(Row row, String page) {
    shownWork.contentRowsDigested++;
    return _rowOf(row, page);
  }

  Shown withTrashedPages(Iterable<PageRow> held) => _with(
    trashed: {
      for (final page in held)
        if (_isTrashed(page)) page.publicId: _rowOf(page, page),
    },
  );

  Shown _with({
    Freshness? fresh,
    ReadState? list,
    Map<String, ReadState>? pageReads,
    Set<String>? goneThisSession,
    Map<Target, Version>? highest,
    Map<String, ShownRow>? pages,
    Map<String, ShownRow>? trashed,
    Map<Target, Removed>? tombstones,
    Map<String, ShownRow>? settings,
    Map<String, Map<SeenPart, String>>? content,
    Map<Target, ShownRow>? rows,
    Arrival? listTaken,
    Map<String, Arrival>? pagesTaken,
    Map<String, PageSays>? listSaid,
    Map<String, PageSays>? pageSaid,
    ShownRow? strategy,
  }) => Shown(
    listTaken: listTaken ?? this.listTaken,
    pagesTaken: pagesTaken ?? this.pagesTaken,
    listSaid: listSaid ?? this.listSaid,
    pageSaid: pageSaid ?? this.pageSaid,
    fence: fence,
    fresh: fresh ?? this.fresh,
    list: list ?? this.list,
    pageReads: pageReads ?? this.pageReads,
    goneThisSession: goneThisSession ?? this.goneThisSession,
    highest: highest ?? this.highest,
    strategy: strategy ?? this.strategy,
    pages: pages ?? this.pages,
    trashed: trashed ?? this.trashed,
    tombstones: tombstones ?? this.tombstones,
    settings: settings ?? this.settings,
    content: content ?? this.content,
    rows: rows ?? this.rows,
  );

  Set<String> get knownPages => {...pages.keys, ...trashed.keys};

  Map<Target, Removed> _removedOn(
    bool Function(String page) gone,
    ResultOrder? started,
  ) => {
    ...tombstones,
    if (started != null)
      for (final MapEntry(:key, :value) in rows.entries)
        if (gone(value.page)) key: Removed(started, held: value.version),
  };

  Taken taken(
    ArrivedBase result, {
    required Arrival? arrival,
  }) => switch (result) {
    HeaderRead() => _withList(result, arrival),
    PageRead(:final page, :final elements, :final lineupGroups) => _checkedTake(
      page.publicId,
      (reuse) => _withPage(
        page,
        [...elements, ...lineupGroups],
        paid: paidBy(pageRead(page.publicId), arrival, result),
        arrival: arrival,
        reuse: reuse,
      ),
    ),
    PageGone(:final pagePublicId) => Taken(
      _with(
        pagesTaken: {...pagesTaken, pagePublicId: ?arrival},
        pageSaid: {
          ...pageSaid,
          if (arrival != null) pagePublicId: PageSays.gone,
        },
        fresh: fresh.afterPage(pagePublicId, gone: true, arrival: arrival),
        pageReads: {...pageReads}..remove(pagePublicId),
        goneThisSession: {...goneThisSession, pagePublicId},
        pages: {...pages}..remove(pagePublicId),
        trashed: {...trashed}..remove(pagePublicId),
        settings: {...settings}..remove(pagePublicId),
        content: {...content}..remove(pagePublicId),
        tombstones: _removedOn((page) => page == pagePublicId, arrival?.order),
        rows: {
          for (final MapEntry(:key, :value) in rows.entries)
            if (value.page != pagePublicId) key: value,
        },
      ),
      [PageLeft(pagePublicId)],
    ),
    StrategyGone() => Taken(
      _with(
        listTaken: arrival,
        listSaid: const {},
        list: paidBy(list, arrival, result) ? const ReadThisSession() : list,
        pageReads: {
          for (final MapEntry(:key, :value) in pageReads.entries)
            if (!isDebt(value) || !paidBy(value, arrival, result)) key: value,
        },
      ),
      const [],
    ),
  };

  Taken _withList(HeaderRead result, Arrival? arrival) {
    final HeaderRead(strategy: strategyRow, pages: listed, :settings) = result;
    final listedIds = {for (final page in listed) page.publicId};
    final pageDecides = {
      for (final page in {...knownPages, ...listedIds, ...pageSaid.keys})
        if (arrival != null &&
            pageDecider(
                  list: arrival,
                  listSays: _listSays(result, page),
                  page: pagesTaken[page],
                  pageSays: pageSaid[page],
                ) !=
                PageDecider.list)
          page,
    };
    final readLater = {
      for (final page in pageDecides)
        if (pages.containsKey(page) || trashed.containsKey(page)) page,
    };
    final listDecides = listedIds.difference(pageDecides);
    final kept = {...listDecides, ...readLater};
    final decisions = <RowDecision>[
      for (final page in knownPages)
        if (!kept.contains(page)) PageLeft(page),
      RowTaken(strategyRow),
    ];
    final nextPages = <String, ShownRow>{
      for (final page in readLater) page: ?pages[page],
    };
    final nextTrashed = <String, ShownRow>{
      for (final page in readLater) page: ?trashed[page],
    };
    for (final page in listed) {
      final id = page.publicId;
      if (pageDecides.contains(id)) {
        decisions.add(RowKept(page, KeptBecause.leftByANewerResult));
        continue;
      }
      final heldLive = pages[id];
      final held = heldLive ?? trashed[id];
      if (replaces(held, page)) {
        decisions.add(RowTaken(page));
        (_isTrashed(page) ? nextTrashed : nextPages)[id] = _rowOf(page, page);
      } else {
        decisions.add(RowKept(page, KeptBecause.heldIsNewer));
        (heldLive != null ? nextPages : nextTrashed)[id] = held!;
      }
    }
    final withSettings = {
      for (final row in settings) row.pagePublicId,
      ...readLater,
    };
    decisions.addAll([
      for (final page in listDecides)
        if (!withSettings.contains(page)) SettingsLeft(page),
      for (final row in settings)
        if (pageDecides.contains(row.pagePublicId))
          RowKept(row, KeptBecause.leftByANewerResult)
        else
          RowTaken(row),
    ]);
    final live = nextPages.keys.toSet();
    return Taken(
      Shown(
        fence: fence,
        listTaken: arrival ?? listTaken,
        pagesTaken: {
          for (final MapEntry(:key, :value) in pagesTaken.entries)
            if (kept.contains(key) || pageDecides.contains(key)) key: value,
        },
        listSaid: {for (final page in listed) page.publicId: pageSaysOf(page)},
        pageSaid: {
          for (final MapEntry(:key, :value) in pageSaid.entries)
            if (kept.contains(key) || pageDecides.contains(key)) key: value,
        },
        fresh: fresh.afterList(live.difference(readLater), arrival),
        list: switch ((list, createdAtOf(strategyRow))) {
          (final owed, _) when !paidBy(owed, arrival, result) => owed,
          (
            ReadOwed(namedLife: final named?) ||
                ReadRefused(namedLife: final named?),
            final listedLife,
          )
              when listedLife == null || listedLife < named =>
            list,
          (
            ReadOwed(unlessLife: final unlessLife?, namedLife: null) ||
                ReadRefused(unlessLife: final unlessLife?, namedLife: null),
            final listedLife,
          )
              when listedLife == null || listedLife <= unlessLife =>
            list,
          _ => const ReadThisSession(),
        },
        pageReads: pageReads,
        goneThisSession: {
          for (final page in goneThisSession)
            if (!live.contains(page)) page,
        },
        highest: _raised(highest, {
          const StrategyTarget(): ?versionOfRow(strategyRow),
          for (final page in listed)
            if (!_isTrashed(page))
              PageTarget(page.publicId): ?versionOfRow(page),
          for (final row in settings)
            SettingsTarget(row.pagePublicId): ?versionOfRow(row),
        }),
        strategy: _strategyRow(strategyRow, listed),
        pages: nextPages,
        trashed: nextTrashed,
        tombstones: _removedOn((page) => !kept.contains(page), arrival?.order),
        settings: {
          for (final page in readLater) page: ?this.settings[page],
          for (final row in settings)
            if (!pageDecides.contains(row.pagePublicId))
              row.pagePublicId: _rowOf(row, row.pagePublicId),
        },
        content: {
          for (final MapEntry(:key, :value) in content.entries)
            if (live.contains(key)) key: value,
        },
        rows: {
          for (final MapEntry(:key, :value) in rows.entries)
            if (kept.contains(value.page)) key: value,
        },
      ),
      decisions,
    );
  }

  static Map<Target, Version> _raised(
    Map<Target, Version> highest,
    Map<Target, Version> seen,
  ) => {
    ...highest,
    for (final MapEntry(:key, :value) in seen.entries)
      if (highest[key] == null || value > highest[key]!) key: value,
  };

  Shown withGone(String page) =>
      _with(goneThisSession: {...goneThisSession, page});

  Shown touched(
    Iterable<String> pages, {
    required bool list,
    required AfterAnswer mark,
  }) => _with(
    fresh: fresh.touched(pages, list: list, mark: mark),
  );

  Shown owingList(PaidBy since) => owingListPast(null, since);

  Shown owingListPast(int? life, PaidBy since, {int? named}) => _with(
    list: switch (list) {
      ReadRefused(:final problem) => ReadRefused(
        problem,
        unlessLife: _later(_refusedLifeOf(list), life),
        namedLife: _later(namedLifeOf(list), named),
        since: oweAlso(list, since),
      ),
      _ => ReadOwed(
        unlessLife: _later(_refusedLifeOf(list), life),
        namedLife: _later(namedLifeOf(list), named),
        since: oweAlso(list, since),
      ),
    },
  );

  Shown owingPage(String page, PaidBy since) => _with(
    pageReads: {
      ...pageReads,
      page: switch (pageRead(page)) {
        ReadRefused(:final problem) && final held => ReadRefused(
          problem,
          since: oweAlso(held, since),
        ),
        final held => ReadOwed(since: oweAlso(held, since)),
      },
    },
  );

  Shown listRefused(String problem, PaidBy since, {required Arrival at}) =>
      _with(
        listTaken: at,
        list: ReadRefused(
          problem,
          unlessLife: _refusedLifeOf(list),
          namedLife: namedLifeOf(list),
          since: since,
        ),
      );

  Shown pageRefused(
    String page,
    String problem,
    PaidBy since, {
    required Arrival at,
  }) => _with(
    pagesTaken: {...pagesTaken, page: at},
    pageReads: {
      ...pageReads,
      page: ReadRefused(problem, since: since),
    },
  );

  Shown paidAgain(ArrivedBase result, Arrival arrival) {
    final again = taken(result, arrival: arrival).shown;
    return _with(
      list: again.list,
      pageReads: again.pageReads,
      fresh: again.fresh,
    );
  }

  Shown asStored() => inNewSession()._with(fresh: Freshness.none);

  Shown inNewSession() => Shown(
    fresh: fresh.inNewSession,
    list: list.inNewSession,
    pageReads: {
      for (final MapEntry(:key, :value) in pageReads.entries)
        key: value.inNewSession,
    },
    highest: highest,
    strategy: strategy,
    pages: pages,
    trashed: trashed,
    settings: settings,
    content: content,
    rows: rows,
  );

  static Taken _checkedTake(String page, Taken Function(bool reuse) take) {
    final taken = take(shownTakesReuse);
    if (shownTakesChecked && take(false) != taken) throw TakesDiffer(page);
    return taken;
  }

  Taken _withPage(
    PageRow pageRow,
    List<Row> found, {
    required bool paid,
    required Arrival? arrival,
    required bool reuse,
  }) {
    final page = pageRow.publicId;
    final heldLive = pages[page];
    final heldPage = heldLive ?? trashed[page];
    final pageTaken = replaces(heldPage, pageRow);
    final decisions = <RowDecision>[
      pageTaken ? RowTaken(pageRow) : RowKept(pageRow, KeptBecause.heldIsNewer),
    ];
    final trashedNow = pageTaken
        ? _isTrashed(pageRow)
        : heldLive == null && heldPage != null;
    final next = {...rows};
    final nextTombstones = {...tombstones};
    final raised = {...highest};
    final carried = <Target>{};
    final liveNow = <Target, bool>{};
    for (final row in found) {
      final target = switch (row) {
        ElementRow(:final publicId) => ElementTarget(publicId) as Target,
        LineupGroupRow(:final publicId) => LineupTarget(publicId),
        _ => throw StateError('only page content is read with a page'),
      };
      carried.add(target);
      if (tombstones[target]?.keepsOut(row, arrival?.order) ?? false) {
        decisions.add(RowKept(row, KeptBecause.leftByANewerResult));
        continue;
      }
      final held = rows[target];
      final shown = switch (held) {
        final held? when reuse && held.holdsDigestOf(row, page) => held,
        _ => _digested(row, page),
      };
      if (shown.version case final version?
          when raised[target] == null || version > raised[target]!) {
        raised[target] = version;
      }
      if (!replaces(held, row)) {
        decisions.add(RowKept(row, KeptBecause.heldIsNewer));
        continue;
      }
      decisions.addAll([
        if (held != null && held.page != page)
          ItemLeft(target, page: held.page),
        held == shown ? RowUnchanged(row) : RowTaken(row),
      ]);
      next[target] = shown;
      liveNow[target] = lifeOfRow(row) == Life.live;
      nextTombstones.remove(target);
    }
    for (final MapEntry(:key, :value) in rows.entries) {
      if (value.page != page) continue;
      if (carried.contains(key)) continue;
      next.remove(key);
      decisions.add(ItemLeft(key, page: page));
      if (arrival != null) {
        nextTombstones[key] = Removed(arrival.order, held: value.version);
      }
    }
    decisions.add(UnreadableLeft(page, found));
    final before = content[page] ?? const <SeenPart, String>{};
    final live = <SeenPart, String>{
      for (final MapEntry(:key, :value) in next.entries)
        if (value.page == page)
          if (_partOf(key) case final part?)
            if (liveNow[key] ?? before.containsKey(part)) part: value.digest,
    };
    return Taken(
      _with(
        pagesTaken: {...pagesTaken, page: ?arrival},
        pageSaid: {...pageSaid, if (arrival != null) page: pageSaysOf(pageRow)},
        fresh: fresh.afterPage(page, gone: trashedNow, arrival: arrival),
        pageReads: {
          ...pageReads,
          page: paid ? const ReadThisSession() : pageRead(page),
        },
        goneThisSession: {...goneThisSession}..remove(page),
        highest: raised,
        pages: switch ((pageTaken, trashedNow)) {
          (true, true) => {...pages}..remove(page),
          (true, false) => {...pages, page: _rowOf(pageRow, pageRow)},
          (false, _) => pages,
        },
        trashed: switch ((pageTaken, trashedNow)) {
          (true, true) => {...trashed, page: _rowOf(pageRow, pageRow)},
          (true, false) => {...trashed}..remove(page),
          (false, _) => trashed,
        },
        tombstones: nextTombstones,
        content: trashedNow
            ? ({...content}..remove(page))
            : {...content, page: live},
        rows: next,
      ),
      decisions,
    );
  }

  static SeenPart? _partOf(Target target) => switch (target) {
    ElementTarget(:final elementPublicId) => SeenElement(elementPublicId),
    LineupTarget(:final lineupPublicId) => SeenLineupGroup(lineupPublicId),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is Shown &&
      other.strategy == strategy &&
      other.fresh == fresh &&
      other.list == list &&
      other.listTaken == listTaken &&
      other.fence == fence &&
      const MapEquality<String, Arrival>().equals(
        other.pagesTaken,
        pagesTaken,
      ) &&
      const MapEquality<String, ReadState>().equals(
        other.pageReads,
        pageReads,
      ) &&
      const SetEquality<String>().equals(
        other.goneThisSession,
        goneThisSession,
      ) &&
      sameMap(other.pages, pages) &&
      sameMap(other.trashed, trashed) &&
      sameMap(other.tombstones, tombstones) &&
      sameMap(other.settings, settings) &&
      const DeepCollectionEquality().equals(other.content, content) &&
      sameMap(other.rows, rows) &&
      sameMap(other.highest, highest);

  @override
  int get hashCode =>
      Object.hash(strategy, pages.length, content.length, rows.length);
}

bool _outranks(Version? a, Version? b) => switch ((a, b)) {
  (final a?, final b?) => a > b,
  (_?, null) => true,
  (null, _) => false,
};
