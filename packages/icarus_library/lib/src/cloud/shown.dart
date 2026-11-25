import 'package:collection/collection.dart';

import '../rows.dart';
import '../strategy_rows.dart';
import 'events.dart';
import 'op_facts.dart';
import 'pending.dart';
import 'version.dart';

final class ShownRow {
  const ShownRow({
    required this.page,
    required this.revision,
    required this.digest,
    this.life,
  });

  final String page;
  final int? revision;
  final int? life;
  final String digest;

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

final class Freshness {
  Freshness._({
    required this.listSinceTouch,
    required Set<String> listed,
    required Set<String> touchedSinceList,
    required Set<String> pagesSinceTouch,
    required Set<String> goneByResult,
  }) : listed = Set.unmodifiable(listed),
       goneByResult = Set.unmodifiable(goneByResult),
       touchedSinceList = Set.unmodifiable(touchedSinceList),
       pagesSinceTouch = Set.unmodifiable(pagesSinceTouch);

  static final none = Freshness._(
    listSinceTouch: false,
    listed: const {},
    touchedSinceList: const {},
    pagesSinceTouch: const {},
    goneByResult: const {},
  );

  final bool listSinceTouch;
  final Set<String> goneByResult;
  final Set<String> listed;
  final Set<String> touchedSinceList;
  final Set<String> pagesSinceTouch;

  Freshness afterList(Iterable<String> live) {
    final listedNow = {...live};
    return Freshness._(
      listSinceTouch: true,
      listed: listedNow,
      touchedSinceList: const {},
      pagesSinceTouch: pagesSinceTouch,
      goneByResult: goneByResult,
    );
  }

  Freshness afterPage(String page, {required bool gone}) => Freshness._(
    listSinceTouch: listSinceTouch,
    listed: listed,
    touchedSinceList: touchedSinceList,
    pagesSinceTouch: {...pagesSinceTouch, page},
    goneByResult: gone
        ? {...goneByResult, page}
        : ({...goneByResult}..remove(page)),
  );

  Freshness touched(Iterable<String> pages, {required bool list}) =>
      Freshness._(
        listSinceTouch: listSinceTouch && !list,
        listed: listed,
        touchedSinceList: {...touchedSinceList, ...pages},
        pagesSinceTouch: list
            ? const {}
            : ({...pagesSinceTouch}..removeAll(pages)),
        goneByResult: goneByResult,
      );

  bool listFreshFor(String page) =>
      listSinceTouch && !touchedSinceList.contains(page);

  bool pageFreshFor(String page) => pagesSinceTouch.contains(page);

  bool freshFor(String page) =>
      listFreshFor(page) && (pageFreshFor(page) || !listed.contains(page));

  bool disagreeOn(String page) =>
      listFreshFor(page) &&
      pageFreshFor(page) &&
      listed.contains(page) == goneByResult.contains(page);

  @override
  bool operator ==(Object other) =>
      other is Freshness &&
      other.listSinceTouch == listSinceTouch &&
      const SetEquality<String>().equals(other.listed, listed) &&
      const SetEquality<String>().equals(
        other.touchedSinceList,
        touchedSinceList,
      ) &&
      const SetEquality<String>().equals(
        other.pagesSinceTouch,
        pagesSinceTouch,
      ) &&
      const SetEquality<String>().equals(other.goneByResult, goneByResult);

  @override
  int get hashCode => Object.hash(listSinceTouch, listed.length);
}

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
  const ReadOwed({this.unlessLife});

  final int? unlessLife;

  @override
  bool operator ==(Object other) =>
      other is ReadOwed && other.unlessLife == unlessLife;

  @override
  int get hashCode => Object.hash(ReadOwed, unlessLife);

  @override
  String toString() => unlessLife == null
      ? 'owed'
      : 'owed by a list of a life after $unlessLife';
}

final class ReadRefused extends ReadState {
  const ReadRefused(this.problem, {this.unlessLife});

  final String problem;
  final int? unlessLife;

  @override
  bool operator ==(Object other) =>
      other is ReadRefused &&
      other.problem == problem &&
      other.unlessLife == unlessLife;

  @override
  int get hashCode => Object.hash(ReadRefused, problem, unlessLife);

  @override
  String toString() => unlessLife == null
      ? 'refused: $problem'
      : 'refused: $problem, owed by a list of a life after $unlessLife';
}

bool isDebt(ReadState state) => state is ReadOwed || state is ReadRefused;

final class Shown {
  Shown({
    required this.strategy,
    required Map<String, ShownRow> pages,
    required Map<String, ShownRow> settings,
    required Map<String, Map<SeenPart, String>> content,
    required Map<Target, ShownRow> rows,
    this.list = const NotReadThisSession(),
    Map<String, ReadState> pageReads = const {},
    Set<String> goneThisSession = const {},
    Map<Target, Version> highest = const {},
    Freshness? fresh,
  }) : fresh = fresh ?? Freshness.none,
       pageReads = Map.unmodifiable({
         for (final MapEntry(:key, :value) in pageReads.entries)
           if (value is! NotReadThisSession) key: value,
       }),
       goneThisSession = Set.unmodifiable(goneThisSession),
       highest = Map.unmodifiable(highest),
       pages = Map.unmodifiable(pages),
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
        if (page is! TrashedPage) page.publicId,
    ]);
    for (final page in read) {
      fresh = fresh.afterPage(page, gone: false);
    }
    return Shown(
      fresh: fresh,
      list: const ReadThisSession(),
      pageReads: {for (final page in read) page: const ReadThisSession()},
      strategy: _strategyRow(rows.strategy, rows.pages),
      pages: {
        for (final page in rows.pages)
          if (page is! TrashedPage) page.publicId: _rowOf(page, page),
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
          if (page is! TrashedPage)
            PageTarget(page.publicId): ?versionOfRow(page),
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
  final Map<String, ShownRow> settings;
  final Map<String, Map<SeenPart, String>> content;
  final Map<Target, ShownRow> rows;

  bool get headerThisSession => list is ReadThisSession;

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
  );

  Shown _with({
    Freshness? fresh,
    ReadState? list,
    Map<String, ReadState>? pageReads,
    Set<String>? goneThisSession,
    Map<Target, Version>? highest,
    Map<String, ShownRow>? pages,
    Map<String, ShownRow>? settings,
    Map<String, Map<SeenPart, String>>? content,
    Map<Target, ShownRow>? rows,
  }) => Shown(
    fresh: fresh ?? this.fresh,
    list: list ?? this.list,
    pageReads: pageReads ?? this.pageReads,
    goneThisSession: goneThisSession ?? this.goneThisSession,
    highest: highest ?? this.highest,
    strategy: strategy,
    pages: pages ?? this.pages,
    settings: settings ?? this.settings,
    content: content ?? this.content,
    rows: rows ?? this.rows,
  );

  Shown take(ArrivedBase result) => switch (result) {
    HeaderRead(:final strategy, :final pages, :final settings) => Shown(
      fresh: fresh.afterList([
        for (final page in pages)
          if (page is! TrashedPage) page.publicId,
      ]),
      list: switch ((list, createdAtOf(strategy))) {
        (
          ReadOwed(:final unlessLife?) || ReadRefused(:final unlessLife?),
          final listed,
        )
            when listed == null || listed <= unlessLife =>
          list,
        _ => const ReadThisSession(),
      },
      pageReads: pageReads,
      goneThisSession: {
        for (final page in goneThisSession)
          if (!pages.any((row) => row.publicId == page && row is! TrashedPage))
            page,
      },
      highest: _raised(highest, {
        const StrategyTarget(): ?versionOfRow(strategy),
        for (final page in pages)
          if (page is! TrashedPage)
            PageTarget(page.publicId): ?versionOfRow(page),
        for (final row in settings)
          SettingsTarget(row.pagePublicId): ?versionOfRow(row),
      }),
      strategy: _strategyRow(strategy, pages),
      pages: {
        for (final page in pages)
          if (page is! TrashedPage) page.publicId: _rowOf(page, page),
      },
      settings: {
        for (final row in settings)
          row.pagePublicId: _rowOf(row, row.pagePublicId),
      },
      content: {
        for (final MapEntry(:key, :value) in content.entries)
          if (pages.any((page) => page.publicId == key && page is! TrashedPage))
            key: value,
      },
      rows: {
        for (final MapEntry(:key, :value) in rows.entries)
          if (pages.any(
            (page) => page.publicId == value.page && page is! TrashedPage,
          ))
            key: value,
      },
    ),
    PageRead(:final page, :final elements, :final lineupGroups) => _withPage(
      page,
      [...elements, ...lineupGroups],
    ),
    PageGone(:final pagePublicId) => _with(
      fresh: fresh.afterPage(pagePublicId, gone: true),
      pageReads: {...pageReads}..remove(pagePublicId),
      goneThisSession: {...goneThisSession, pagePublicId},
      pages: {...pages}..remove(pagePublicId),
      settings: {...settings}..remove(pagePublicId),
      content: {...content}..remove(pagePublicId),
      rows: {
        for (final MapEntry(:key, :value) in rows.entries)
          if (value.page != pagePublicId) key: value,
      },
    ),
    StrategyGone() => _with(
      list: const ReadThisSession(),
      pageReads: {
        for (final MapEntry(:key, :value) in pageReads.entries)
          if (!isDebt(value)) key: value,
      },
    ),
  };

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

  Shown touched(Iterable<String> pages, {required bool list}) =>
      _with(fresh: fresh.touched(pages, list: list));

  Shown owingList() => _with(list: const ReadOwed());

  Shown owingListPast(int? life) => _with(list: ReadOwed(unlessLife: life));

  Shown owingPage(String page) =>
      _with(pageReads: {...pageReads, page: const ReadOwed()});

  Shown listRefused(String problem) => _with(
    list: ReadRefused(
      problem,
      unlessLife: switch (list) {
        ReadOwed(:final unlessLife) ||
        ReadRefused(:final unlessLife) => unlessLife,
        NotReadThisSession() || ReadThisSession() => null,
      },
    ),
  );

  Shown pageRefused(String page, String problem) =>
      _with(pageReads: {...pageReads, page: ReadRefused(problem)});

  Shown inNewSession() => Shown(
    list: list.inNewSession,
    pageReads: {
      for (final MapEntry(:key, :value) in pageReads.entries)
        key: value.inNewSession,
    },
    highest: highest,
    strategy: strategy,
    pages: pages,
    settings: settings,
    content: content,
    rows: rows,
  );

  Shown _withPage(PageRow pageRow, List<Row> found) {
    final page = pageRow.publicId;
    final next = {
      for (final MapEntry(:key, :value) in rows.entries)
        if (value.page != page) key: value,
    };
    final raised = {...highest};
    for (final row in found) {
      final target = switch (row) {
        ElementRow(:final publicId) => ElementTarget(publicId) as Target,
        LineupGroupRow(:final publicId) => LineupTarget(publicId),
        _ => throw StateError('only page content is read with a page'),
      };
      final shown = _rowOf(row, page);
      if (shown.version case final version?
          when raised[target] == null || version > raised[target]!) {
        raised[target] = version;
      }
      final elsewhere = next[target];
      if (elsewhere != null && _outranks(elsewhere.version, shown.version)) {
        continue;
      }
      next[target] = shown;
    }
    return _with(
      fresh: fresh.afterPage(page, gone: pageRow is TrashedPage),
      pageReads: {...pageReads, page: const ReadThisSession()},
      goneThisSession: {...goneThisSession}..remove(page),
      highest: raised,
      pages: switch ((pageRow, pages[page]?.version)) {
        (TrashedPage(), _) => {...pages}..remove(page),
        (_, final known?) when _outranks(known, versionOfRow(pageRow)) => pages,
        _ => {...pages, page: _rowOf(pageRow, pageRow)},
      },
      content: pageRow is TrashedPage
          ? ({...content}..remove(page))
          : {...content, page: liveContentOn(found, page)},
      rows: next,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Shown &&
      other.strategy == strategy &&
      other.fresh == fresh &&
      other.list == list &&
      const MapEquality<String, ReadState>().equals(
        other.pageReads,
        pageReads,
      ) &&
      const SetEquality<String>().equals(
        other.goneThisSession,
        goneThisSession,
      ) &&
      sameMap(other.pages, pages) &&
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
