import 'dart:async';

import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus_library/icarus_library.dart';

typedef ResultTag = ({int? connection, int account});

bool _newer(ResultTag a, ResultTag b) =>
    a.connection! > b.connection! ||
    (a.connection == b.connection && a.account > b.account);

enum SkipReason {
  receivedOffline('received while the app counted itself offline'),
  endedConnection('read on a connection that has since ended'),
  earlierAccount('read under an account that has since changed'),
  strategyClosed('the strategy was closed before it was processed'),
  endedSession('the queue answered that its session had ended');

  const SkipReason(this.words);

  final String words;
}

sealed class Verdict {
  const Verdict();
}

final class NotProcessed extends Verdict {
  const NotProcessed();
}

final class ComparedEqual extends Verdict {
  const ComparedEqual();
}

final class ComparedDifferent extends Verdict {
  const ComparedDifferent(this.differences);

  final List<String> differences;
}

final class Skipped extends Verdict {
  const Skipped(this.reason);

  final SkipReason reason;
}

final class NotRecorded extends Verdict {
  const NotRecorded(this.why);

  final String why;
}

final class LedgerEntry {
  LedgerEntry(this.strategyId, this.what);

  final String strategyId;
  final String what;
  Verdict verdict = const NotProcessed();
}

sealed class CloudShadowReport {
  const CloudShadowReport();
}

final class ShadowSessionOpened extends CloudShadowReport {
  const ShadowSessionOpened(this.strategyId, this.session, this.because);

  final String strategyId;
  final int session;
  final String because;
}

final class ShadowConnectionLost extends CloudShadowReport {
  const ShadowConnectionLost(this.strategyId);

  final String strategyId;
}

final class ShadowReadFailed extends CloudShadowReport {
  const ShadowReadFailed(this.strategyId, this.error);

  final String strategyId;
  final String error;
}

final class ShadowStopped extends CloudShadowReport {
  const ShadowStopped(this.reason);

  final String reason;
}

final class _Expected {
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
      final revision = _revisionOf(row);
      final newerElsewhere = held.entries.any(
        (entry) =>
            entry.key != pageId &&
            revision != null &&
            (_revisionOf(entry.value[id] ?? row) ?? -1) > revision,
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

int? _revisionOf(Row row) => switch (row) {
      LiveElement(:final revision) ||
      DeletedElement(:final revision) ||
      LiveLineupGroup(:final revision) ||
      DeletedLineupGroup(:final revision) =>
        revision,
      _ => null,
    };

String _idOf(Row row) => switch (row) {
      ElementRow(:final publicId) => publicId,
      LineupGroupRow(:final publicId) => publicId,
      _ => throw StateError('not a page row: $row'),
    };

final class CloudShadow {
  CloudShadow(
    this.store, {
    required this.build,
    required this.canRead,
    required Future<void> Function() breathe,
  }) : _breathe = breathe;

  final LibraryStore store;
  final String build;
  final CanRead canRead;
  final Future<void> Function() _breathe;

  final reports = <CloudShadowReport>[];
  final ledger = <LedgerEntry>[];
  String? stopped;

  Future<void> _tail = Future<void>.value();
  final _openedThisRun = <String>{};
  String? _strategyId;
  bool _inStore = false;
  ResultTag? _bound;
  String? _openPage;
  var _expected = _Expected();
  final _waiting =
      <({LedgerEntry entry, RemotePageSnapshot page, ResultTag tag})>[];

  Future<void> get idle => _tail;

  void _then(Future<void> Function() work) {
    _tail = _tail.then((_) async {
      if (stopped != null) return;
      await _breathe();
      try {
        await work();
      } catch (error) {
        stop('$error');
      }
    });
  }

  void stop(String reason) {
    if (stopped != null) return;
    stopped = reason;
    reports.add(ShadowStopped(reason));
  }

  void connectionLost() => _then(() async {
        final strategyId = _strategyId;
        if (strategyId == null || !_inStore) return;
        if (await _record(strategyId, null, [const ConnectionLost()]) != null) {
          reports.add(ShadowConnectionLost(strategyId));
        }
      });

  void strategyClosed() => _then(() async {
        for (final waiting in _waiting) {
          waiting.entry.verdict = const Skipped(SkipReason.strategyClosed);
        }
        _strategyId = null;
        _reset();
      });

  void _reset() {
    _inStore = false;
    _bound = null;
    _openPage = null;
    _expected = _Expected();
    _waiting.clear();
  }

  void pageList(String strategyId, RemotePageList list, ResultTag tag) {
    final entry = LedgerEntry(strategyId, 'the page list');
    ledger.add(entry);
    _then(() async {
      if (!_admit(entry, tag)) return;
      final HeaderRead header;
      switch (pageListRead(list)) {
        case RowsRead(:final value):
          header = value;
        case RowsUnreadable(:final problem):
          entry.verdict =
              NotRecorded('the server rows could not be read: $problem');
          return;
      }
      if (!_inStore) {
        await _start(entry, header, tag);
        if (!_inStore) return;
        final waiting = [..._waiting];
        _waiting.clear();
        for (final page in waiting) {
          await _pageNow(page.entry, page.page, page.tag);
        }
        return;
      }
      if (!await _bindFor(entry, tag)) return;
      if (await _arrive(entry, header)) {
        _expected.header(header);
        await _compare(entry);
      }
    });
  }

  void page(String strategyId, RemotePageSnapshot snapshot, ResultTag tag) {
    final entry = LedgerEntry(strategyId, 'page ${snapshot.page.publicId}');
    ledger.add(entry);
    _then(() async {
      if (!_admit(entry, tag)) return;
      if (!_inStore) {
        _waiting.add((entry: entry, page: snapshot, tag: tag));
        return;
      }
      await _pageNow(entry, snapshot, tag);
    });
  }

  bool _admit(LedgerEntry entry, ResultTag tag) {
    if (tag.connection == null) {
      entry.verdict = const Skipped(SkipReason.receivedOffline);
      return false;
    }
    if (_strategyId != entry.strategyId) {
      _strategyId = entry.strategyId;
      _reset();
    }
    return true;
  }

  Future<void> _pageNow(
    LedgerEntry entry,
    RemotePageSnapshot snapshot,
    ResultTag tag,
  ) async {
    if (!await _bindFor(entry, tag)) return;
    final PageRead read;
    switch (pageRead(snapshot, canRead)) {
      case RowsRead(:final value):
        read = value;
      case RowsUnreadable(:final problem):
        entry.verdict =
            NotRecorded('the server rows could not be read: $problem');
        return;
    }
    if (await _arrive(entry, read)) {
      _expected.page(read);
      _openPage = read.page.publicId;
      await _compare(entry);
    }
  }

  Future<bool> _bindFor(LedgerEntry entry, ResultTag tag) async {
    final bound = _bound;
    if (bound == tag) return true;
    if (bound != null && !_newer(tag, bound)) {
      entry.verdict = Skipped(
        tag.connection! < bound.connection!
            ? SkipReason.endedConnection
            : SkipReason.earlierAccount,
      );
      return false;
    }
    final (because, event) = bound == null || tag.connection != bound.connection
        ? ('the connection came back', const ConnectionReturned())
        : ('the account changed', const AccountChanged());
    return _open(entry, tag, because, [event]);
  }

  Future<bool> _open(
    LedgerEntry entry,
    ResultTag tag,
    String because,
    List<QueueEvent> events,
  ) async {
    _bound = null;
    if (await _record(entry.strategyId, entry, events) == null) return false;
    final session = await _sessionOf(entry);
    if (session == null) return false;
    _bound = tag;
    reports.add(ShadowSessionOpened(entry.strategyId, session, because));
    return true;
  }

  Future<void> _start(
    LedgerEntry entry,
    HeaderRead header,
    ResultTag tag,
  ) async {
    final strategyId = entry.strategyId;
    final StrategySummary? listed;
    switch (store.library) {
      case LibraryOpen(:final list):
        listed = list.strategies
            .where((summary) => summary.publicId == strategyId)
            .firstOrNull;
      case LibraryShut(:final failure):
        entry.verdict = NotRecorded(
          'the store is shut: ${storageFailureWords(failure, StoreStep.read)}',
        );
        return;
    }
    switch (listed?.sync) {
      case null:
        _openedThisRun.add(strategyId);
        switch (await store.addCloudStrategy(header, const [])) {
          case Saved():
            final session = await _sessionOf(entry);
            if (session == null) return;
            _bound = tag;
            _inStore = true;
            reports.add(
              ShadowSessionOpened(
                  strategyId, session, 'the strategy was added'),
            );
            _expected.header(header);
            await _compare(entry);
          case NothingToSave():
            entry.verdict = const NotRecorded('the store saved nothing');
          case Refused(:final reason):
            entry.verdict = NotRecorded(
              'the store refused it: ${reason.runtimeType} $reason',
            );
          case NotSaved(:final failure):
            entry.verdict = NotRecorded(
              storageFailureWords(failure, StoreStep.refusedSave),
            );
          case SaveInDoubt(:final failure):
            entry.verdict = NotRecorded(
              storageFailureWords(failure, StoreStep.saveInDoubt),
            );
        }
      case KeptHere():
        entry.verdict = const NotRecorded(
          'the store holds this id as a strategy kept on this device',
        );
      case KeptInCloud() || CloudUnverified():
        final restarted = _openedThisRun.add(strategyId);
        if (!await _open(
          entry,
          tag,
          restarted ? 'the app started' : 'the strategy was opened again',
          [
            if (restarted) AppRestarted(build: build),
            const ConnectionReturned(),
          ],
        )) {
          return;
        }
        _inStore = true;
        if (await _arrive(entry, header)) {
          _expected.header(header);
          await _compare(entry);
        }
    }
  }

  Future<bool> _arrive(LedgerEntry entry, ArrivedBase base) async {
    final session = await _sessionOf(entry);
    if (session == null) return false;
    final recorded = await _record(entry.strategyId, entry, [
      BaseArrived(base, session: session),
    ]);
    if (recorded == null) return false;
    for (final outcome in recorded.outcomes) {
      switch (outcome) {
        case ReportNotApplicable(why: FromAnEndedSession()):
          entry.verdict = const Skipped(SkipReason.endedSession);
          return false;
        case ReportNotApplicable(:final why):
          entry.verdict = NotRecorded('the queue did not apply it: $why');
          return false;
        case ReportApplied() || EditsGoThroughCommit():
          break;
      }
    }
    return true;
  }

  Future<Recorded?> _record(
    String strategyId,
    LedgerEntry? entry,
    List<QueueEvent> events,
  ) async {
    void failed(String why) {
      if (entry != null) {
        entry.verdict = NotRecorded(why);
      } else {
        stop(why);
      }
    }

    switch (await store.record(strategyId, events)) {
      case Saved(:final value):
        return value;
      case NothingToSave():
        failed('the store saved nothing');
      case Refused(:final reason):
        failed('the store refused it: ${reason.runtimeType} $reason');
      case NotSaved(:final failure):
        failed(storageFailureWords(failure, StoreStep.refusedSave));
      case SaveInDoubt(:final failure):
        failed(storageFailureWords(failure, StoreStep.saveInDoubt));
    }
    return null;
  }

  Future<int?> _sessionOf(LedgerEntry entry) async {
    switch (await store.readStrategy(entry.strategyId)) {
      case Found(value: StrategyContent(sync: CloudStrategy(:final queue))):
        return queue.session.number;
      case Found():
        entry.verdict = const NotRecorded('the store holds no cloud queue');
      case NotFound():
        entry.verdict = const NotRecorded('the store does not hold it');
      case InUnreadableStrategy():
        entry.verdict = const NotRecorded('the store lists it as unreadable');
      case NotRead(:final failure):
        entry.verdict =
            NotRecorded(storageFailureWords(failure, StoreStep.read));
    }
    return null;
  }

  Future<void> _compare(LedgerEntry entry) async {
    final differences = await differencesIn(store);
    entry.verdict = differences.isEmpty
        ? const ComparedEqual()
        : ComparedDifferent(differences);
  }

  Future<List<String>> differencesIn(LibraryStore other) async {
    final strategyId = _strategyId;
    if (strategyId == null || !_inStore) return const [];
    return [
      ...await _strategyDifferences(other, strategyId),
      if (_openPage case final pageId?)
        ...await _pageDifferences(other, strategyId, pageId),
    ];
  }

  Future<List<String>> _strategyDifferences(
    LibraryStore other,
    String strategyId,
  ) async {
    final expected = _expected;
    switch (await other.readStrategy(strategyId)) {
      case Found(value: final content):
        final shownPages = [for (final page in content.pages) page.publicId];
        final sentPages = [
          for (final page in _ordered(expected.pages.values)) page.publicId,
        ];
        return [
          if (expected.strategy case final row? when content.strategy != row)
            'strategy row: ${_rowWords(content.strategy, row)}',
          if (shownPages.join(',') != sentPages.join(','))
            'page list: the store holds ${shownPages.join(', ')}, the server '
                'sent ${sentPages.join(', ')}',
          for (final page in content.pages)
            if (expected.pages[page.publicId] case final sent?
                when sent != page)
              'page row ${page.publicId}: ${_rowWords(page, sent)}',
          ..._differences(
            'page settings',
            content.settings,
            expected.settings,
          ),
          for (final row in content.unplaced) 'unplaced: ${row.ref}',
          for (final name in content.foreignNames)
            'a name this build does not know: ${name.area}/${name.name}',
        ];
      case NotFound():
        return const ['the store does not hold the strategy'];
      case InUnreadableStrategy():
        return const ['the store lists the strategy as unreadable'];
      case NotRead(:final failure):
        return [
          'reading the strategy back: '
              '${storageFailureWords(failure, StoreStep.read)}',
        ];
    }
  }

  Future<List<String>> _pageDifferences(
    LibraryStore other,
    String strategyId,
    String pageId,
  ) async {
    final expected = _expected;
    final sentPage = expected.pages[pageId];
    switch (await other.readPage(strategyId, pageId)) {
      case Found(value: final shown):
        if (sentPage == null) {
          return ['page $pageId: the store holds it, the server dropped it'];
        }
        return pageDifferences(
          shown: shown,
          page: sentPage,
          settings: expected.settings[pageId],
          elements: expected.elements[pageId] ?? const {},
          lineupGroups: expected.lineupGroups[pageId] ?? const {},
        );
      case NotFound():
        return [
          if (sentPage != null) 'page $pageId: missing from the store',
        ];
      case InUnreadableStrategy():
        return const ['the store lists the strategy as unreadable'];
      case NotRead(:final failure):
        return [
          'reading page $pageId back: '
              '${storageFailureWords(failure, StoreStep.read)}',
        ];
    }
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
      ..._differences(
        'item',
        {for (final row in shown.elements) row.publicId: row},
        elements,
      ),
      ..._differences(
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

Iterable<String> _differences<T extends Object>(
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
