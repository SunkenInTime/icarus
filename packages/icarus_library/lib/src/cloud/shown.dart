import 'package:collection/collection.dart';

import '../rows.dart';
import '../strategy_rows.dart';
import 'events.dart';
import 'op_facts.dart';
import 'pending.dart';

final class ShownRow {
  const ShownRow({
    required this.page,
    required this.revision,
    required this.digest,
  });

  final String page;
  final int? revision;
  final String digest;

  @override
  bool operator ==(Object other) =>
      other is ShownRow &&
      other.page == page &&
      other.revision == revision &&
      other.digest == digest;

  @override
  int get hashCode => Object.hash(page, revision, digest);
}

final class Shown {
  Shown({
    required this.strategyRevision,
    required Map<String, ShownRow> pages,
    required Map<String, ShownRow> settings,
    required Map<String, Map<SeenPart, String>> content,
    required Map<Target, ShownRow> rows,
    this.headerThisSession = false,
    Set<String> pagesThisSession = const {},
    Set<String> goneThisSession = const {},
    Map<Target, int> highest = const {},
  }) : pagesThisSession = Set.unmodifiable(pagesThisSession),
       goneThisSession = Set.unmodifiable(goneThisSession),
       highest = Map.unmodifiable(highest),
       pages = Map.unmodifiable(pages),
       settings = Map.unmodifiable(settings),
       content = Map.unmodifiable(content),
       rows = Map.unmodifiable(rows);

  static final nothing = Shown(
    strategyRevision: null,
    pages: const {},
    settings: const {},
    content: const {},
    rows: const {},
  );

  factory Shown.of(StrategyRowSet rows, {required Iterable<String> readPages}) {
    final read = {...readPages};
    return Shown(
      headerThisSession: true,
      pagesThisSession: read,
      strategyRevision: revisionOfRow(rows.strategy),
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
        const StrategyTarget(): ?revisionOfRow(rows.strategy),
        for (final page in rows.pages)
          if (page is! TrashedPage)
            PageTarget(page.publicId): ?revisionOfRow(page),
        for (final row in rows.settings)
          SettingsTarget(row.pagePublicId): ?revisionOfRow(row),
        for (final page in read) ...{
          for (final row in rows.elementsOn(page))
            ElementTarget(row.publicId): ?revisionOfRow(row),
          for (final row in rows.lineupGroupsOn(page))
            LineupTarget(row.publicId): ?revisionOfRow(row),
        },
      },
    );
  }

  final int? strategyRevision;
  final bool headerThisSession;
  final Set<String> pagesThisSession;
  final Set<String> goneThisSession;
  final Map<Target, int> highest;
  final Map<String, ShownRow> pages;
  final Map<String, ShownRow> settings;
  final Map<String, Map<SeenPart, String>> content;
  final Map<Target, ShownRow> rows;

  static ShownRow _rowOf(Row row, Object page) => ShownRow(
    page: switch (page) {
      final String id => id,
      PageRow(:final publicId) => publicId,
      _ => '',
    },
    revision: revisionOfRow(row),
    digest: rowDigest(row),
  );

  Shown take(ArrivedBase result) => switch (result) {
    HeaderRead(:final strategy, :final pages, :final settings) => Shown(
      headerThisSession: true,
      pagesThisSession: pagesThisSession,
      goneThisSession: {
        for (final page in goneThisSession)
          if (!pages.any((row) => row.publicId == page && row is! TrashedPage))
            page,
      },
      highest: _raised(highest, {
        const StrategyTarget(): ?revisionOfRow(strategy),
        for (final page in pages)
          if (page is! TrashedPage)
            PageTarget(page.publicId): ?revisionOfRow(page),
        for (final row in settings)
          SettingsTarget(row.pagePublicId): ?revisionOfRow(row),
      }),
      strategyRevision: revisionOfRow(strategy),
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
    PageGone(:final pagePublicId) => Shown(
      headerThisSession: headerThisSession,
      pagesThisSession: {...pagesThisSession}..remove(pagePublicId),
      goneThisSession: {...goneThisSession, pagePublicId},
      highest: highest,
      strategyRevision: strategyRevision,
      pages: {...pages}..remove(pagePublicId),
      settings: {...settings}..remove(pagePublicId),
      content: {...content}..remove(pagePublicId),
      rows: {
        for (final MapEntry(:key, :value) in rows.entries)
          if (value.page != pagePublicId) key: value,
      },
    ),
    StrategyGone() => this,
  };

  static Map<Target, int> _raised(
    Map<Target, int> highest,
    Map<Target, int> seen,
  ) => {
    ...highest,
    for (final MapEntry(:key, :value) in seen.entries)
      if (value > (highest[key] ?? 0)) key: value,
  };

  Shown withGone(String page) => Shown(
    headerThisSession: headerThisSession,
    pagesThisSession: pagesThisSession,
    goneThisSession: {...goneThisSession, page},
    highest: highest,
    strategyRevision: strategyRevision,
    pages: pages,
    settings: settings,
    content: content,
    rows: rows,
  );

  Shown inNewSession() => Shown(
    highest: highest,
    strategyRevision: strategyRevision,
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
      if (shown.revision case final revision?
          when revision > (raised[target] ?? 0)) {
        raised[target] = revision;
      }
      final elsewhere = next[target];
      if (elsewhere != null &&
          (elsewhere.revision ?? 0) > (shown.revision ?? 0)) {
        continue;
      }
      next[target] = shown;
    }
    return Shown(
      headerThisSession: headerThisSession,
      pagesThisSession: {...pagesThisSession, page},
      goneThisSession: {...goneThisSession}..remove(page),
      highest: raised,
      strategyRevision: strategyRevision,
      pages: switch ((pageRow, pages[page]?.revision)) {
        (TrashedPage(), _) => {...pages}..remove(page),
        (_, final known?) when (revisionOfRow(pageRow) ?? 0) < known => pages,
        _ => {...pages, page: _rowOf(pageRow, pageRow)},
      },
      settings: settings,
      content: {...content, page: liveContentOn(found, page)},
      rows: next,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Shown &&
      other.strategyRevision == strategyRevision &&
      other.headerThisSession == headerThisSession &&
      const SetEquality<String>().equals(
        other.goneThisSession,
        goneThisSession,
      ) &&
      const SetEquality<String>().equals(
        other.pagesThisSession,
        pagesThisSession,
      ) &&
      sameMap(other.pages, pages) &&
      sameMap(other.settings, settings) &&
      const DeepCollectionEquality().equals(other.content, content) &&
      sameMap(other.rows, rows) &&
      sameMap(other.highest, highest);

  @override
  int get hashCode =>
      Object.hash(strategyRevision, pages.length, content.length, rows.length);
}
