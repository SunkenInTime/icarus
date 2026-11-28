import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus_library/icarus_library.dart';

final class ServerRows {
  StrategyRow? strategy;
  final pages = <String, PageRow>{};
  final settings = <String, PageSettingsRow>{};
  final elements = <String, Map<String, ElementRow>>{};
  final lineupGroups = <String, Map<String, LineupGroupRow>>{};

  void header(HeaderRead read) {
    strategy = read.strategy;
    final listed = {for (final page in read.pages) page.publicId};
    for (final id in [...pages.keys]) {
      if (!listed.contains(id)) {
        pages.remove(id);
        settings.remove(id);
        elements.remove(id);
        lineupGroups.remove(id);
      }
    }
    for (final page in read.pages) {
      pages[page.publicId] = page;
    }
    final withSettings = {for (final row in read.settings) row.pagePublicId};
    for (final id in listed) {
      if (!withSettings.contains(id)) settings.remove(id);
    }
    for (final row in read.settings) {
      settings[row.pagePublicId] = row;
    }
  }

  void page(PageRead read) {
    final pageId = read.page.publicId;
    pages[pageId] = read.page;
    elements[pageId] = _placed(elements, pageId, read.elements);
    lineupGroups[pageId] = _placed(lineupGroups, pageId, read.lineupGroups);
  }

  static Map<String, T> _placed<T extends Row>(
    Map<String, Map<String, T>> held,
    String pageId,
    List<T> rows,
  ) {
    final placed = <String, T>{};
    for (final row in rows) {
      final id = _idOf(row);
      final version = _versionOf(row);
      final newerElsewhere = held.entries.any(
        (entry) =>
            entry.key != pageId &&
            version != null &&
            switch (_versionOf(entry.value[id] ?? row)) {
              final elsewhere? => elsewhere > version,
              null => false,
            },
      );
      if (newerElsewhere) continue;
      for (final MapEntry(:key, :value) in held.entries) {
        if (key != pageId) value.remove(id);
      }
      placed[id] = row;
    }
    return placed;
  }
}

Version? _versionOf(Row row) => switch (row) {
      LiveElement() ||
      DeletedElement() ||
      LiveLineupGroup() ||
      DeletedLineupGroup() =>
        versionOfRow(row),
      _ => null,
    };

String _idOf(Row row) => switch (row) {
      ElementRow(:final publicId) => publicId,
      LineupGroupRow(:final publicId) => publicId,
      _ => throw StateError('not a page row: $row'),
    };

Future<List<String>> differencesFromServer(
  LibraryStore other,
  String strategyId,
  ServerRows expected, {
  required Account? account,
  required Set<String>? pages,
}) async {
  final Reading<StrategyContent> read = await other.readStrategy(strategyId);
  final StrategyContent content;
  switch (read) {
    case Found(:final value):
      content = value;
    case NotFound():
      return const ['the store does not hold the strategy'];
    case InUnreadableStrategy(
        listing: UnreadableStrategyListing(
          refused: StoredRowsDisagree(:final reason),
        ),
      ):
      return ['the store refuses the strategy: $reason'];
    case InUnreadableStrategy():
      return const ['the store lists the strategy as unreadable'];
    case NotRead(:final failure):
      return [
        'reading the strategy back: '
            '${storageFailureWords(failure, StoreStep.read)}',
      ];
  }
  final owner = switch (content.sync) {
    CloudStrategy(:final owner) => OwnedBy(owner),
    CloudHeld(:final owner) => owner,
    LocalStrategy() => null,
  };
  final shownPages = [for (final page in content.pages) page.publicId];
  final sentPages = [
    for (final page in _ordered(expected.pages.values)) page.publicId,
  ];
  final compared = pages ?? expected.elements.keys.toSet();
  return [
    if (account case final served? when owner != OwnedBy(served))
      'account: the store holds the work for '
          '${owner ?? 'nobody, as a strategy kept here'}, the server '
          'was read as ${served.subject}',
    if (expected.strategy case final row? when content.strategy != row)
      'strategy row: ${_rowWords(content.strategy, row)}',
    if (shownPages.join(',') != sentPages.join(','))
      'page list: the store holds ${shownPages.join(', ')}, the server '
          'sent ${sentPages.join(', ')}',
    for (final page in content.pages)
      if (expected.pages[page.publicId] case final sent? when sent != page)
        'page row ${page.publicId}: ${_rowWords(page, sent)}',
    ..._rowDifferences('page settings', content.settings, expected.settings),
    for (final row in content.unplaced) 'unplaced: ${row.ref}',
    for (final name in content.foreignNames)
      'a name this build does not know: ${name.area}/${name.name}',
    for (final pageId in compared)
      ...await _pageDifferences(other, strategyId, pageId, expected),
  ];
}

Future<List<String>> _pageDifferences(
  LibraryStore other,
  String strategyId,
  String pageId,
  ServerRows expected,
) async {
  final sentPage = expected.pages[pageId];
  switch (await other.readPage(strategyId, pageId)) {
    case Found(value: final shown):
      if (sentPage == null) {
        return ['page $pageId: the store holds it, the server dropped it'];
      }
      return [
        for (final difference in pageDifferences(
          shown: shown,
          page: sentPage,
          settings: expected.settings[pageId],
          elements: expected.elements[pageId] ?? const {},
          lineupGroups: expected.lineupGroups[pageId] ?? const {},
        ))
          'page $pageId: $difference',
      ];
    case NotFound():
      return [
        if (sentPage != null) 'page $pageId: missing from the store',
      ];
    case InUnreadableStrategy(
        listing: UnreadableStrategyListing(
          refused: StoredRowsDisagree(:final reason),
        ),
      ):
      return ['the store refuses the strategy: $reason'];
    case InUnreadableStrategy():
      return const ['the store lists the strategy as unreadable'];
    case NotRead(:final failure):
      return [
        'reading page $pageId back: '
            '${storageFailureWords(failure, StoreStep.read)}',
      ];
  }
}

List<PageRow> _ordered(Iterable<PageRow> pages) => [...pages]..sort(
    (a, b) => switch ((_sortOf(a), _sortOf(b))) {
      (final x, final y) when x != y => x.compareTo(y),
      _ => a.publicId.compareTo(b.publicId),
    },
  );

int _sortOf(PageRow page) => switch (page) {
      ReadablePageRow(:final sortIndex) => sortIndex,
      UnreadablePage(:final sortIndex) => sortIndex ?? 1 << 31,
    };

List<String> pageDifferences({
  required PageContent shown,
  required PageRow page,
  required PageSettingsRow? settings,
  required Map<String, ElementRow> elements,
  required Map<String, LineupGroupRow> lineupGroups,
}) =>
    [
      if (shown.page != page) 'page row: ${_rowWords(shown.page, page)}',
      switch ((shown.settings, settings)) {
        (SettingsStored(:final row), final sent?) when row == sent => null,
        (NoSettingsStored(), null) => null,
        (SettingsStored(:final row), final sent) =>
          'page settings: ${_rowWords(row, sent)}',
        (NoSettingsStored(), final sent) =>
          'page settings: ${_rowWords(null, sent)}',
      },
      ..._rowDifferences(
        'item',
        {for (final row in shown.elements) row.publicId: row},
        elements,
      ),
      ..._rowDifferences(
        'lineup group',
        {for (final row in shown.lineupGroups) row.publicId: row},
        lineupGroups,
      ),
      for (final row in shown.unknownKinds)
        'a kind this build skips: ${row.key}',
      for (final row in shown.unplaced) 'unplaced: ${row.ref}',
      for (final name in shown.foreignNames)
        'a name this build does not know: ${name.area}/${name.name}',
    ].nonNulls.toList();

Iterable<String> _rowDifferences<T extends Object>(
  String kind,
  Map<String, T> shown,
  Map<String, T> server,
) sync* {
  for (final MapEntry(:key, :value) in server.entries) {
    switch (shown[key]) {
      case null:
        yield '$kind $key: missing from the store';
      case final row when row != value:
        yield '$kind $key: ${_rowWords(row, value)}';
      case _:
        break;
    }
  }
  for (final key in shown.keys) {
    if (!server.containsKey(key)) yield '$kind $key: only in the store';
  }
}

String _rowWords(Object? store, Object? server) =>
    'the store holds ${_brief(store)}, the server sent ${_brief(server)}';

String _brief(Object? row) => switch (row) {
      LiveElement(:final revision) => 'live at revision $revision',
      DeletedElement(:final revision) => 'deleted at revision $revision',
      LivePage(:final revision, :final name, :final sortIndex) =>
        '"$name" at place $sortIndex, revision $revision',
      ReadablePageSettings(:final revision) => 'revision $revision',
      LiveLineupGroup(:final revision) => 'live at revision $revision',
      DeletedLineupGroup(:final revision) => 'deleted at revision $revision',
      ReadableStrategy(:final revision, :final name) =>
        '"$name" at revision $revision',
      null => 'nothing',
      _ => '${row.runtimeType}',
    };
