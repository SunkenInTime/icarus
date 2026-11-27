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
  int marksLooked = 0;

  void reset() {
    contentRowsDigested = 0;
    marksLooked = 0;
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

typedef Wrote = ({Target target, Version version});

final class AnswerMark {
  AnswerMark({required this.order, this.serverTime, Wrote? wrote})
    : wrote = switch (wrote) {
        (:final target, :final version) => Map.unmodifiable({target: version}),
        null => null,
      };

  AnswerMark._(this.order, this.serverTime, Map<Target, Version>? wrote)
    : wrote = wrote == null ? null : Map.unmodifiable(wrote);

  final ResultOrder order;
  final int? serverTime;
  final Map<Target, Version>? wrote;

  bool reachedBy(Arrival? arrival) =>
      arrival != null &&
      !arrival.order.isBefore(order) &&
      switch ((serverTime, arrival.point.serverTime)) {
        (null, _) => true,
        (_, null) => false,
        (final answered?, final shown?) => shown >= answered,
      };

  bool onlyItsTimeAhead(Arrival? arrival) =>
      arrival != null && !arrival.order.isBefore(order) && !reachedBy(arrival);

  bool shownWhere(bool Function(Target target, Version version) holds) =>
      wrote?.entries.every((entry) => holds(entry.key, entry.value)) ?? false;

  AnswerMark and(AnswerMark? other) => switch (other) {
    null => this,
    final other => AnswerMark._(
      order.isBefore(other.order) ? other.order : order,
      _later(serverTime, other.serverTime),
      switch ((wrote, other.wrote)) {
        (final mine?, final theirs?) => {
          ...mine,
          for (final MapEntry(:key, :value) in theirs.entries)
            if (mine[key] == null || value > mine[key]!) key: value,
        },
        _ => null,
      },
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is AnswerMark &&
      other.order == order &&
      other.serverTime == serverTime &&
      switch ((other.wrote, wrote)) {
        (final a?, final b?) => const MapEquality<Target, Version>().equals(
          a,
          b,
        ),
        (final a, final b) => a == b,
      };

  @override
  int get hashCode => Object.hash(order, serverTime, wrote?.length);

  @override
  String toString() =>
      'our answer at $order and time $serverTime'
      '${switch (wrote) {
        final wrote? => ', which wrote ${[for (final MapEntry(:key, :value) in wrote.entries) '$key at $value'].join(', ')}',
        null => '',
      }}';
}

final class Marks {
  Marks({
    this.list,
    this.allPages,
    Map<String, AnswerMark> pages = const {},
    Map<String, AnswerMark> listFor = const {},
    Map<Target, AnswerMark> rows = const {},
    Map<Target, String> placed = const {},
    Map<String, Set<Target>> rowsOn = const {},
  }) : pages = Map.unmodifiable(pages),
       listFor = Map.unmodifiable(listFor),
       rows = Map.unmodifiable(rows),
       placed = Map.unmodifiable(placed),
       rowsOn = Map.unmodifiable(rowsOn);

  static final none = Marks();

  final AnswerMark? list;
  final AnswerMark? allPages;
  final Map<String, AnswerMark> pages;
  final Map<String, AnswerMark> listFor;
  final Map<Target, AnswerMark> rows;
  final Map<Target, String> placed;
  final Map<String, Set<Target>> rowsOn;

  bool get isEmpty =>
      list == null &&
      allPages == null &&
      pages.isEmpty &&
      listFor.isEmpty &&
      rows.isEmpty;

  Marks _with({
    AnswerMark? Function()? list,
    AnswerMark? Function()? allPages,
    Map<String, AnswerMark>? pages,
    Map<String, AnswerMark>? listFor,
  }) => Marks(
    list: list == null ? this.list : list(),
    allPages: allPages == null ? this.allPages : allPages(),
    pages: pages ?? this.pages,
    listFor: listFor ?? this.listFor,
    rows: rows,
    placed: placed,
    rowsOn: rowsOn,
  );

  Marks _rowsAt(
    Map<Target, AnswerMark> rows,
    Iterable<Target> moved,
    String? Function(Target target) pageOf,
  ) {
    final placed = {...this.placed};
    final rowsOn = {...this.rowsOn};
    for (final target in moved) {
      final was = placed[target];
      final now = rows.containsKey(target) ? pageOf(target) : null;
      if (was == now) continue;
      if (was != null) {
        final left = {...rowsOn[was]!}..remove(target);
        left.isEmpty ? rowsOn.remove(was) : rowsOn[was] = left;
        placed.remove(target);
      }
      if (now != null) {
        placed[target] = now;
        rowsOn[now] = {...?rowsOn[now], target};
      }
    }
    return Marks(
      list: list,
      allPages: allPages,
      pages: pages,
      listFor: listFor,
      rows: rows,
      placed: placed,
      rowsOn: rowsOn,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Marks &&
      other.list == list &&
      other.allPages == allPages &&
      const MapEquality<String, AnswerMark>().equals(other.pages, pages) &&
      const MapEquality<String, AnswerMark>().equals(other.listFor, listFor) &&
      const MapEquality<Target, AnswerMark>().equals(other.rows, rows);

  @override
  int get hashCode => Object.hash(list, allPages, pages.length, rows.length);
}

final class Seen {
  const Seen(this.at, {this.gone = false});

  final Arrival? at;
  final bool gone;

  @override
  bool operator ==(Object other) =>
      other is Seen && other.at == at && other.gone == gone;

  @override
  int get hashCode => Object.hash(at, gone);
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
  const Arrival({required this.order, required this.point});

  final ResultOrder order;
  final ResultPoint point;

  @override
  bool operator ==(Object other) =>
      other is Arrival && other.order == order && other.point == point;

  @override
  int get hashCode => Object.hash(order, point);
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
    this.visibleAt = false,
    this.evidence,
  });

  final int session;
  final ResultPoint point;
  final bool visibleAt;
  final Evidence? evidence;

  @override
  bool paidBy(Arrival arrival, ArrivedBase? base) =>
      (base != null && (evidence?.shownBy(base) ?? false)) ||
      arrival.order.session > session ||
      (arrival.order.session == session &&
          (point.generation.isBefore(arrival.point.generation) ||
              (visibleAt &&
                  arrival.point.generation == point.generation &&
                  arrival.point.snapshot >= point.snapshot)));

  @override
  bool operator ==(Object other) =>
      other is AfterRefusal &&
      other.session == session &&
      other.point == point &&
      other.visibleAt == visibleAt &&
      other.evidence == evidence;

  @override
  int get hashCode =>
      Object.hash(AfterRefusal, session, point, visibleAt, evidence);

  @override
  String toString() =>
      'content, a later connection, client or session'
      '${visibleAt ? ', or a result at or after snapshot ${point.snapshot} '
                'of the same connection' : ''}';
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
  ResultAtOrAfter? atOrAfter;
  AfterAnswer? answer;
  final rest = <PaidBy>{};
  for (final debt in [
    for (final debt in [held, added])
      if (debt case AllOf(:final each)) ...each else debt,
  ]) {
    switch (debt) {
      case ResultAtOrAfter(:final order):
        if (atOrAfter == null || atOrAfter.order.isBefore(order)) {
          atOrAfter = debt;
        }
      case AfterAnswer():
        answer = debt.and(answer);
      case AfterRefusal() || AllOf():
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

PaidBy refusedOver(PaidBy owed, Arrival refused) {
  final each = switch (owed) {
    AllOf(:final each) => each,
    final one => {one},
  };
  final orders = each.whereType<ResultAtOrAfter>();
  if (orders.isEmpty) return owed;
  final kept = [
    for (final debt in each)
      if (debt is! ResultAtOrAfter) debt,
  ];
  final order = switch (orders.where((debt) => !debt.paidBy(refused, null))) {
    final unpaid when unpaid.isNotEmpty => unpaid.reduce(
      (a, b) => a.order.isBefore(b.order) ? b : a,
    ),
    _ => ResultAtOrAfter(refused.order),
  };
  return kept.fold<PaidBy>(order, both);
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
      'owed by a list of a later life than $refused, or of another life from '
          'a later connection or session',
    (_, final named?) => 'owed by a list of life $named or later',
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
      'refused: $problem, owed by a list of a later life than $refused, or of '
          'another life from a later connection or session',
    (_, final named?) =>
      'refused: $problem, owed by a list of life $named or later',
  };
}

int? namedLifeOf(ReadState state) => switch (state) {
  ReadOwed(:final namedLife) || ReadRefused(:final namedLife) => namedLife,
  NotReadThisSession() || ReadThisSession() => null,
};

bool isDebt(ReadState state) => state is ReadOwed || state is ReadRefused;

bool _isTrashed(PageRow page) => lifeOfRow(page) == Life.gone;

enum PageExistence {
  live,
  trashed,
  absent;

  static PageExistence of(PageRow? row) => switch (row) {
    null => absent,
    final row when _isTrashed(row) => trashed,
    _ => live,
  };
}

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
  Taken(
    this.shown,
    Iterable<RowDecision> decisions, {
    Set<String> differing = const {},
  }) : decisions = List.unmodifiable(decisions),
       differing = Set.unmodifiable(differing);

  final Shown shown;
  final List<RowDecision> decisions;
  final Set<String> differing;

  @override
  bool operator ==(Object other) =>
      other is Taken &&
      other.shown == shown &&
      const ListEquality<RowDecision>().equals(other.decisions, decisions) &&
      const SetEquality<String>().equals(other.differing, differing);

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
    Marks? marks,
    this.listSeen,
    Map<String, Seen> pagesSeen = const {},
    this.listTaken,
    Map<String, ResultOrder> pagesTaken = const {},
    this.listRefusedAt,
    Map<String, ResultOrder> pagesRefusedAt = const {},
    this.fence,
  }) : marks = marks ?? Marks.none,
       pagesSeen = Map.unmodifiable(pagesSeen),
       pagesTaken = Map.unmodifiable(pagesTaken),
       pagesRefusedAt = Map.unmodifiable(pagesRefusedAt),
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
    return Shown(
      listSeen: const Seen(null),
      pagesSeen: {for (final page in read) page: const Seen(null)},
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

  factory Shown.ofStoredRows(
    StrategyRowSet rows, {
    Iterable<String> owing = const [],
  }) {
    final holding = {
      for (final row in rows.elements) row.pagePublicId,
      for (final row in rows.lineupGroups) row.pagePublicId,
    };
    final stored = Shown.of(rows, readPages: holding).inNewSession();
    return stored._with(
      list: const ReadOwed(since: ResultAtOrAfter.anyResult),
      pageReads: {
        for (final page in owing)
          page: const ReadOwed(since: ResultAtOrAfter.anyResult),
      },
      content: {
        for (final MapEntry(:key, :value) in stored.content.entries)
          if (stored.pages.containsKey(key)) key: value,
      },
    );
  }

  final ShownRow? strategy;
  final Marks marks;
  final Seen? listSeen;
  final Map<String, Seen> pagesSeen;
  final ReadState list;
  final Map<String, ReadState> pageReads;
  final ResultOrder? listTaken;
  final Map<String, ResultOrder> pagesTaken;
  final ResultOrder? listRefusedAt;
  final Map<String, ResultOrder> pagesRefusedAt;
  final ResultOrder? fence;

  PaidBy? owedBy(ArrivedBase result) => switch (switch (result) {
    HeaderRead() || StrategyGone() => list,
    PageRead(:final page) => pageRead(page.publicId),
    PageGone(:final pagePublicId) => pageRead(pagePublicId),
  }) {
    ReadOwed(:final since) || ReadRefused(:final since) => since,
    NotReadThisSession() || ReadThisSession() => null,
  };

  Shown fencedAt(ResultOrder fence) => Shown(
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
    marks: marks,
    listSeen: listSeen,
    pagesSeen: pagesSeen,
    listTaken: listTaken,
    pagesTaken: pagesTaken,
    listRefusedAt: listRefusedAt,
    pagesRefusedAt: pagesRefusedAt,
    fence: fence,
  );

  ResultOrder? takenFor(ArrivedBase result) => switch (result) {
    HeaderRead() || StrategyGone() => listTaken,
    PageRead(:final page) => pagesTaken[page.publicId],
    PageGone(:final pagePublicId) => pagesTaken[pagePublicId],
  };

  ResultOrder? contentTakenOf(String? page) =>
      page == null ? listTaken : pagesTaken[page];

  ResultOrder? refusedAtOf(String? page) =>
      page == null ? listRefusedAt : pagesRefusedAt[page];

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

  bool goneByResult(String page) => pagesSeen[page]?.gone ?? false;

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
    Marks? marks,
    Seen? listSeen,
    Map<String, Seen>? pagesSeen,
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
    ResultOrder? listTaken,
    Map<String, ResultOrder>? pagesTaken,
    ResultOrder? listRefusedAt,
    Map<String, ResultOrder>? pagesRefusedAt,
    ShownRow? strategy,
  }) => Shown(
    listTaken: listTaken ?? this.listTaken,
    pagesTaken: pagesTaken ?? this.pagesTaken,
    listRefusedAt: listRefusedAt ?? this.listRefusedAt,
    pagesRefusedAt: pagesRefusedAt ?? this.pagesRefusedAt,
    fence: fence,
    marks: marks ?? this.marks,
    listSeen: listSeen ?? this.listSeen,
    pagesSeen: pagesSeen ?? this.pagesSeen,
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

  PageExistence existenceOf(String page) => pages.containsKey(page)
      ? PageExistence.live
      : trashed.containsKey(page)
      ? PageExistence.trashed
      : PageExistence.absent;

  bool listIsNewerThan(Arrival? arrival) => switch ((listTaken, arrival)) {
    (final list?, final arrival?) => arrival.order.isBefore(list),
    _ => false,
  };

  Map<Target, Removed> _removedOn(
    bool Function(String page) gone,
    ResultOrder? started,
  ) => {
    ...tombstones,
    if (started != null)
      for (final MapEntry(:key, :value) in rows.entries)
        if (gone(value.page)) key: Removed(started, held: value.version),
  };

  Taken taken(ArrivedBase result, {required Arrival? arrival}) {
    final taken = _taken(result, arrival: arrival);
    final found = switch (result) {
      PageRead(:final elements, :final lineupGroups) => [
        for (final row in elements)
          if (marks.rows.containsKey(ElementTarget(row.publicId)))
            ElementTarget(row.publicId) as Target,
        for (final row in lineupGroups)
          if (marks.rows.containsKey(LineupTarget(row.publicId)))
            LineupTarget(row.publicId),
      ],
      _ => const <Target>[],
    };
    final placed = taken.shown._rowMarksPlaced(switch (result) {
      HeaderRead() => marks.rows.keys,
      StrategyGone() => const <Target>[],
      PageRead(:final page) => {...?marks.rowsOn[page.publicId], ...found},
      PageGone(:final pagePublicId) => {...?marks.rowsOn[pagePublicId]},
    });
    final settled = switch (result) {
      HeaderRead() || StrategyGone() => placed._settledByList(),
      PageRead(:final page) => placed._settledByPage(page.publicId, found),
      PageGone(:final pagePublicId) => placed._settledByPage(
        pagePublicId,
        const [],
      ),
    };
    return identical(settled, taken.shown)
        ? taken
        : Taken(settled, taken.decisions, differing: taken.differing);
  }

  Taken _taken(
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
        pagesTaken: {...pagesTaken, pagePublicId: ?arrival?.order},
        pagesSeen: {...pagesSeen, pagePublicId: Seen(arrival, gone: true)},
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
        listTaken: arrival?.order,
        listSeen: Seen(arrival),
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
    final listedRows = {for (final page in listed) page.publicId: page};
    final differing = <String>{};
    bool listDecides(String page) {
      final own = pagesTaken[page];
      if (arrival == null || own == null || own.isBefore(arrival.order)) {
        return true;
      }
      if (PageExistence.of(listedRows[page]) == existenceOf(page)) return true;
      if (own == arrival.order) differing.add(page);
      return false;
    }

    final decides = {
      for (final page in {...knownPages, ...listedRows.keys})
        page: listDecides(page),
    };
    final removed = {
      for (final page in knownPages)
        if (!listedRows.containsKey(page) && decides[page]!) page,
    };
    final decisions = <RowDecision>[
      for (final page in removed) PageLeft(page),
      RowTaken(strategyRow),
    ];
    final nextPages = <String, ShownRow>{
      for (final MapEntry(:key, :value) in pages.entries)
        if (!decides[key]!) key: value,
    };
    final nextTrashed = <String, ShownRow>{
      for (final MapEntry(:key, :value) in trashed.entries)
        if (!decides[key]!) key: value,
    };
    final takenPages = <String>{};
    for (final page in listed) {
      final id = page.publicId;
      final heldLive = pages[id];
      final held = heldLive ?? trashed[id];
      if (!decides[id]!) {
        if (held != null) decisions.add(RowKept(page, KeptBecause.heldIsNewer));
        continue;
      }
      if (replaces(held, page)) {
        takenPages.add(id);
        decisions.add(RowTaken(page));
        (_isTrashed(page) ? nextTrashed : nextPages)[id] = _rowOf(page, page);
      } else {
        decisions.add(RowKept(page, KeptBecause.heldIsNewer));
        (heldLive != null ? nextPages : nextTrashed)[id] = held!;
      }
    }
    final remaining = {...nextPages.keys, ...nextTrashed.keys};
    final withSettings = {for (final row in settings) row.pagePublicId};
    final takenSettings = [
      for (final row in settings)
        if (remaining.contains(row.pagePublicId) &&
            replaces(this.settings[row.pagePublicId], row))
          row,
    ];
    final settingsTaken = {for (final row in takenSettings) row.pagePublicId};
    decisions.addAll([
      for (final page in listedRows.keys)
        if (remaining.contains(page) && !withSettings.contains(page))
          SettingsLeft(page),
      for (final row in settings)
        if (remaining.contains(row.pagePublicId))
          settingsTaken.contains(row.pagePublicId)
              ? RowTaken(row)
              : RowKept(row, KeptBecause.heldIsNewer),
    ]);
    final live = nextPages.keys.toSet();
    return Taken(
      Shown(
        fence: fence,
        listTaken: arrival?.order ?? listTaken,
        pagesTaken: pagesTaken,
        listRefusedAt: listRefusedAt,
        pagesRefusedAt: pagesRefusedAt,
        marks: marks,
        listSeen: Seen(arrival),
        pagesSeen: pagesSeen,
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
            if (!_isTrashed(page) && takenPages.contains(page.publicId))
              PageTarget(page.publicId): ?versionOfRow(page),
          for (final row in takenSettings)
            SettingsTarget(row.pagePublicId): ?versionOfRow(row),
        }),
        strategy: _strategyRow(strategyRow, listed),
        pages: nextPages,
        trashed: nextTrashed,
        tombstones: _removedOn(removed.contains, arrival?.order),
        settings: {
          for (final MapEntry(:key, :value) in this.settings.entries)
            if (remaining.contains(key) &&
                (!listedRows.containsKey(key) || withSettings.contains(key)))
              key: value,
          for (final row in takenSettings)
            row.pagePublicId: _rowOf(row, row.pagePublicId),
        },
        content: {
          for (final MapEntry(:key, :value) in content.entries)
            if (live.contains(key)) key: value,
        },
        rows: {
          for (final MapEntry(:key, :value) in rows.entries)
            if (remaining.contains(value.page)) key: value,
        },
      ),
      decisions,
      differing: differing,
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

  Shown marked(
    AnswerMark mark, {
    required Iterable<String> pages,
    required bool list,
    required bool allPages,
    Target? row,
  }) {
    final next = marks._with(
      list: list && !_listReaches(mark, counted: false)
          ? () => mark.and(marks.list)
          : null,
      allPages: allPages ? () => mark.and(marks.allPages) : null,
      pages: {
        ...marks.pages,
        for (final page in pages)
          if (!_pageSettled(page, mark)) page: mark.and(marks.pages[page]),
      },
      listFor: {
        ...marks.listFor,
        for (final page in pages)
          if (!_listReaches(mark, counted: false))
            page: mark.and(marks.listFor[page]),
      },
    );
    return _with(
      marks: switch (row) {
        final row? when !_rowSettled(row, mark) => next._rowsAt(
          {...next.rows, row: mark.and(next.rows[row])},
          [row],
          (target) => rows[target]?.page,
        ),
        _ => next,
      },
    );
  }

  bool get listCurrent => _listCurrent(counted: true);

  bool get listCurrentUncounted => _listCurrent(counted: false);

  bool _listCurrent({required bool counted}) =>
      headerThisSession && _listReaches(marks.list, counted: counted);

  bool listCurrentFor(String page) =>
      listCurrent && _listReaches(marks.listFor[page], counted: true);

  bool pageCurrent(String page) =>
      pageResultCurrent(page) &&
      !(pagesSeen[page]!.gone && pages.containsKey(page));

  bool pageResultCurrent(String page) {
    final seen = pagesSeen[page];
    if (seen == null || isDebt(pageRead(page))) return false;
    if (!_pageReaches(page, seen, marks.pages[page], counted: true) ||
        !_pageReaches(page, seen, marks.allPages, counted: true)) {
      return false;
    }
    for (final target in marks.rowsOn[page] ?? const <Target>{}) {
      shownWork.marksLooked++;
      if (!_rowReached(marks.rows[target]!, seen)) return false;
    }
    return true;
  }

  bool waitsOnClock(String? page) {
    final (seen, waiting) = switch (page) {
      null when headerThisSession => (
        listSeen,
        [
          for (final mark in [?marks.list, ...marks.listFor.values])
            if (!_listReaches(mark, counted: false)) mark,
        ],
      ),
      final page? when pagesSeen[page] != null && !isDebt(pageRead(page)) => (
        pagesSeen[page],
        [
          for (final mark in [?marks.pages[page], ?marks.allPages])
            if (!_pageReaches(page, pagesSeen[page]!, mark, counted: false))
              mark,
          for (final target in marks.rowsOn[page] ?? const <Target>{})
            if (!_rowReached(marks.rows[target]!, pagesSeen[page]!))
              marks.rows[target]!,
        ],
      ),
      _ => (null, const <AnswerMark>[]),
    };
    return waiting.isNotEmpty &&
        waiting.every((mark) => mark.onlyItsTimeAhead(seen?.at));
  }

  bool _listReaches(AnswerMark? mark, {required bool counted}) {
    if (mark == null) return true;
    if (counted) shownWork.marksLooked++;
    return mark.reachedBy(listSeen?.at) || mark.shownWhere(_listHolds);
  }

  bool _listHolds(Target target, Version version) => switch (target) {
    StrategyTarget() => _atLeast(strategy?.version, version),
    PageTarget(:final pagePublicId) => _atLeast(
      (pages[pagePublicId] ?? trashed[pagePublicId])?.version,
      version,
    ),
    SettingsTarget(:final pagePublicId) => _atLeast(
      settings[pagePublicId]?.version,
      version,
    ),
    ElementTarget() || LineupTarget() => false,
  };

  bool _pageReaches(
    String page,
    Seen seen,
    AnswerMark? mark, {
    required bool counted,
  }) {
    if (mark == null) return true;
    if (counted) shownWork.marksLooked++;
    return mark.reachedBy(seen.at) ||
        mark.shownWhere(
          (target, version) => switch (rows[target]) {
            final row? when row.page == page => _atLeast(row.version, version),
            _ => false,
          },
        );
  }

  bool _rowReached(AnswerMark mark, Seen seen) =>
      mark.reachedBy(seen.at) || mark.shownWhere(_holds);

  bool _holds(Target target, Version version) =>
      _atLeast(rows[target]?.version, version) ||
      _atLeast(highest[target], version);

  static bool _atLeast(Version? held, Version wanted) =>
      held != null && held >= wanted;

  bool _pageSettled(String page, AnswerMark mark) => switch (pagesSeen[page]) {
    final seen? => _pageReaches(page, seen, mark, counted: false),
    null => false,
  };

  bool _rowSettled(Target row, AnswerMark mark) =>
      mark.shownWhere(_holds) ||
      switch (rows[row]) {
        ShownRow(:final page) => switch (pagesSeen[page]) {
          final seen? => mark.reachedBy(seen.at),
          null => false,
        },
        null => false,
      };

  Shown _settledByList() {
    if (marks.isEmpty) return this;
    final next = marks._with(
      list: _listReaches(marks.list, counted: false) ? () => null : null,
      listFor: {
        for (final MapEntry(:key, :value) in marks.listFor.entries)
          if (!_listReaches(value, counted: false)) key: value,
      },
    );
    return next == marks ? this : _with(marks: next);
  }

  Shown _rowMarksPlaced(Iterable<Target> moved) {
    if (marks.rows.isEmpty) return this;
    final next = marks._rowsAt(
      marks.rows,
      moved,
      (target) => rows[target]?.page,
    );
    return _with(marks: next);
  }

  Shown _settledByPage(String page, Iterable<Target> found) {
    if (marks.isEmpty) return this;
    final allPages = marks.allPages;
    final next = marks._with(
      allPages:
          allPages != null &&
              pages.keys.every(
                (page) => switch (pagesSeen[page]) {
                  final seen? => _pageReaches(
                    page,
                    seen,
                    allPages,
                    counted: false,
                  ),
                  null => false,
                },
              )
          ? () => null
          : null,
      pages: switch (marks.pages[page]) {
        final mark? when _pageSettled(page, mark) => {
          ...marks.pages,
        }..remove(page),
        _ => null,
      },
    );
    final settled = {
      for (final target in {...?marks.rowsOn[page], ...found})
        if (marks.rows[target] case final mark? when _rowSettled(target, mark))
          target,
    };
    if (settled.isEmpty) return next == marks ? this : _with(marks: next);
    return _with(
      marks: next._rowsAt(
        {
          for (final MapEntry(:key, :value) in next.rows.entries)
            if (!settled.contains(key)) key: value,
        },
        settled,
        (target) => null,
      ),
    );
  }

  Shown owingList(PaidBy since) =>
      _with(list: _owed(list, since, unlessLife: _refusedLifeOf(list)));

  Shown owingListAlso(PaidBy since) => switch (list) {
    ReadRefused(
      :final problem,
      :final unlessLife,
      :final namedLife,
      since: final held,
    ) =>
      _with(
        list: ReadRefused(
          problem,
          unlessLife: unlessLife,
          namedLife: namedLife,
          since: both(held, since),
        ),
      ),
    _ => owingList(since),
  };

  Shown owingListPast(int? life, PaidBy since, {int? named}) => _with(
    list: _owed(
      list,
      since,
      unlessLife: life ?? _refusedLifeOf(list),
      namedLife: _later(namedLifeOf(list), named),
    ),
  );

  Shown owingPage(String page, PaidBy since) =>
      _with(pageReads: {...pageReads, page: _owed(pageRead(page), since)});

  static ReadOwed _owed(
    ReadState held,
    PaidBy since, {
    int? unlessLife,
    int? namedLife,
  }) => ReadOwed(
    unlessLife: unlessLife,
    namedLife: namedLife ?? namedLifeOf(held),
    since: oweAlso(held, since),
  );

  static int? _refusedLifeOf(ReadState state) => switch (state) {
    ReadOwed(:final unlessLife) || ReadRefused(:final unlessLife) => unlessLife,
    NotReadThisSession() || ReadThisSession() => null,
  };

  Shown listRefused(String problem, PaidBy since, {required ResultOrder at}) =>
      _with(
        listRefusedAt: at,
        list: ReadRefused(
          problem,
          unlessLife: switch (list) {
            ReadOwed(:final unlessLife) ||
            ReadRefused(:final unlessLife) => unlessLife,
            NotReadThisSession() || ReadThisSession() => null,
          },
          namedLife: namedLifeOf(list),
          since: since,
        ),
      );

  Shown pageRefused(
    String page,
    String problem,
    PaidBy since, {
    required ResultOrder at,
  }) => _with(
    pagesRefusedAt: {...pagesRefusedAt, page: at},
    pageReads: {
      ...pageReads,
      page: ReadRefused(problem, since: since),
    },
  );

  bool sameContentAs(Shown other) =>
      other.strategy == strategy &&
      sameMap(other.pages, pages) &&
      sameMap(other.trashed, trashed) &&
      sameMap(other.settings, settings) &&
      const DeepCollectionEquality().equals(other.content, content) &&
      sameMap(other.rows, rows);

  Shown paidAgain(Shown again) => _with(
    list: again.list,
    pageReads: again.pageReads,
    marks: again.marks,
    listSeen: again.listSeen,
    pagesSeen: again.pagesSeen,
  );

  Shown withoutMarks() => _with(marks: Marks.none);

  Shown inNewSession() => Shown(
    marks: marks,
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
    final pageTaken = !listIsNewerThan(arrival) && replaces(heldPage, pageRow);
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
        pagesTaken: {...pagesTaken, page: ?arrival?.order},
        pagesSeen: {
          ...pagesSeen,
          page: Seen(arrival, gone: trashedNow),
        },
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
      other.marks == marks &&
      other.listSeen == listSeen &&
      const MapEquality<String, Seen>().equals(other.pagesSeen, pagesSeen) &&
      other.list == list &&
      other.listTaken == listTaken &&
      other.listRefusedAt == listRefusedAt &&
      other.fence == fence &&
      const MapEquality<String, ResultOrder>().equals(
        other.pagesTaken,
        pagesTaken,
      ) &&
      const MapEquality<String, ResultOrder>().equals(
        other.pagesRefusedAt,
        pagesRefusedAt,
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
