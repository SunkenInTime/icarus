import 'dart:async';

import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus_library/icarus_library.dart';

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

final class ShadowRecorded extends CloudShadowReport {
  const ShadowRecorded(this.strategyId, this.what, this.session);

  final String strategyId;
  final String what;
  final int session;
}

final class ShadowNotApplied extends CloudShadowReport {
  const ShadowNotApplied(this.strategyId, this.what, this.why);

  final String strategyId;
  final String what;
  final String why;
}

final class ShadowSkipped extends CloudShadowReport {
  const ShadowSkipped(this.strategyId, this.what, this.why);

  final String strategyId;
  final String what;
  final String why;
}

final class ShadowEqual extends CloudShadowReport {
  const ShadowEqual(this.strategyId, this.pageId, this.rows);

  final String strategyId;
  final String pageId;
  final int rows;
}

final class ShadowDiffers extends CloudShadowReport {
  const ShadowDiffers(this.strategyId, this.pageId, this.differences);

  final String strategyId;
  final String pageId;
  final List<String> differences;
}

final class ShadowStoreFailed extends CloudShadowReport {
  const ShadowStoreFailed(this.what, this.failure, this.step);

  final String what;
  final StorageFailure failure;
  final StoreStep step;

  String get words => storageFailureWords(failure, step);
}

final class ShadowRefused extends CloudShadowReport {
  const ShadowRefused(this.strategyId, this.what, this.refusal);

  final String strategyId;
  final String what;
  final Object refusal;
}

typedef _Binding = ({int stamp, int session});

final class _Expected {
  _Expected(this.pageId);

  final String pageId;
  PageRow? page;
  PageSettingsRow? settings;
  Map<String, ElementRow>? elements;
  Map<String, LineupGroupRow>? lineupGroups;

  bool get complete =>
      page != null &&
      settings != null &&
      elements != null &&
      lineupGroups != null;
}

final class CloudShadow {
  CloudShadow(this.store, {required this.build, required this.canRead});

  final LibraryStore store;
  final String build;
  final CanRead canRead;

  final reports = <CloudShadowReport>[];

  Future<void> _tail = Future<void>.value();
  final _openedThisRun = <String>{};
  String? _strategyId;
  bool _inStore = false;
  _Binding? _binding;
  int? _stamp;
  String? _account;
  _Expected? _expected;
  ({RemotePageSnapshot page, int stamp})? _waitingPage;

  Future<void> get idle => _tail;

  void _then(Future<void> Function() work) {
    _tail = _tail.then((_) => work());
  }

  void connection(int? stamp) => _then(() async {
        _stamp = stamp;
        final strategyId = _strategyId;
        if (strategyId == null || !_inStore) return;
        if (stamp == null) {
          _binding = null;
          if (await _record(strategyId, 'the connection dropping', [
                const ConnectionLost(),
              ]) !=
              null) {
            reports.add(ShadowConnectionLost(strategyId));
          }
          return;
        }
        await _open(strategyId, stamp, 'the connection came back', [
          const ConnectionReturned(),
        ]);
      });

  void account(String? accountId) => _then(() async {
        final before = _account;
        _account = accountId;
        final strategyId = _strategyId;
        if (before == null || before == accountId) return;
        if (strategyId == null || !_inStore) return;
        const because = 'the account changed';
        switch (_stamp) {
          case final stamp?:
            await _open(strategyId, stamp, because, [const AccountChanged()]);
          case null:
            await _record(strategyId, because, [const AccountChanged()]);
        }
      });

  void strategyClosed() => _then(() async {
        _strategyId = null;
        _inStore = false;
        _binding = null;
        _expected = null;
        _waitingPage = null;
      });

  void pageList(String strategyId, RemotePageList list,
          {required int? stamp}) =>
      _then(() async {
        const what = 'the page list';
        if (stamp == null) {
          reports.add(ShadowSkipped(strategyId, what, 'received offline'));
          return;
        }
        final HeaderRead header;
        switch (pageListRead(list)) {
          case RowsRead(:final value):
            header = value;
          case RowsUnreadable(:final problem):
            reports.add(ShadowSkipped(strategyId, what, problem));
            return;
        }
        if (_strategyId != strategyId || !_inStore) {
          await _start(strategyId, header, stamp);
          return;
        }
        if (await _arrive(strategyId, what, header, stamp)) {
          _expectHeader(header);
          await _check(strategyId);
        }
      });

  void page(
    String strategyId,
    RemotePageSnapshot snapshot, {
    required int? stamp,
  }) =>
      _then(() async {
        final what = 'page ${snapshot.page.publicId}';
        if (stamp == null) {
          reports.add(
            ShadowSkipped(strategyId, what, 'not received on this connection'),
          );
          return;
        }
        if (_strategyId != strategyId || !_inStore) {
          _waitingPage = (page: snapshot, stamp: stamp);
          return;
        }
        await _arrivePage(strategyId, snapshot, stamp);
      });

  Future<void> _arrivePage(
    String strategyId,
    RemotePageSnapshot snapshot,
    int stamp,
  ) async {
    final what = 'page ${snapshot.page.publicId}';
    final PageRead read;
    final PageSettingsRow settings;
    switch ((pageRead(snapshot, canRead), pageSettingsRead(snapshot))) {
      case (RowsRead(value: final page), RowsRead(value: final pageSettings)):
        read = page;
        settings = pageSettings;
      case (RowsUnreadable(:final problem), _) ||
            (_, RowsUnreadable(:final problem)):
        reports.add(ShadowSkipped(strategyId, what, problem));
        return;
    }
    if (await _arrive(strategyId, what, read, stamp)) {
      _expectPage(read, settings);
      await _check(strategyId);
    }
  }

  Future<void> _start(String strategyId, HeaderRead header, int stamp) async {
    _strategyId = strategyId;
    _inStore = false;
    _binding = null;
    _expected = null;
    final StrategySummary? listed;
    switch (store.library) {
      case LibraryOpen(:final list):
        listed = list.strategies
            .where((summary) => summary.publicId == strategyId)
            .firstOrNull;
      case LibraryShut(:final failure):
        reports.add(
          ShadowStoreFailed(
              'reading the library list', failure, StoreStep.read),
        );
        return;
    }
    switch (listed?.sync) {
      case null:
        await _add(strategyId, header, stamp);
      case KeptHere():
        reports.add(ShadowSkipped(
          strategyId,
          'the page list',
          'the store holds it as a local strategy',
        ));
        return;
      case KeptInCloud() || CloudUnverified():
        final because = _openedThisRun.add(strategyId)
            ? 'the app started'
            : 'the strategy was opened again';
        await _open(strategyId, stamp, because, [
          if (because == 'the app started') AppRestarted(build: build),
          const ConnectionReturned(),
        ]);
        if (_binding == null) return;
        if (await _arrive(strategyId, 'the page list', header, stamp)) {
          _expectHeader(header);
        }
    }
    if (_binding == null) return;
    _inStore = true;
    switch (_waitingPage) {
      case (:final page, stamp: final pageStamp) when pageStamp == stamp:
        _waitingPage = null;
        await _arrivePage(strategyId, page, pageStamp);
      case _:
        await _check(strategyId);
    }
  }

  Future<void> _add(String strategyId, HeaderRead header, int stamp) async {
    const what = 'adding the strategy';
    _openedThisRun.add(strategyId);
    final result = await store.addCloudStrategy(header, const []);
    switch (result) {
      case Saved():
        final session = await _sessionOf(strategyId);
        if (session == null) {
          reports.add(ShadowSkipped(strategyId, what, 'not added as cloud'));
          return;
        }
        _binding = (stamp: stamp, session: session);
        reports.add(
          ShadowSessionOpened(strategyId, session, 'the strategy was added'),
        );
        reports.add(ShadowRecorded(strategyId, 'the page list', session));
        _expectHeader(header);
      case NothingToSave():
        reports.add(ShadowSkipped(strategyId, what, 'nothing to save'));
      case Refused(:final reason):
        reports.add(ShadowRefused(strategyId, what, reason));
      case NotSaved(:final failure):
        reports.add(ShadowStoreFailed(what, failure, StoreStep.refusedSave));
      case SaveInDoubt(:final failure):
        reports.add(ShadowStoreFailed(what, failure, StoreStep.saveInDoubt));
    }
  }

  Future<void> _open(
    String strategyId,
    int stamp,
    String because,
    List<QueueEvent> events,
  ) async {
    _binding = null;
    final recorded = await _record(strategyId, because, events);
    if (recorded == null) return;
    final session = await _sessionOf(strategyId);
    if (session == null) {
      reports.add(ShadowSkipped(strategyId, because, 'no cloud queue'));
      return;
    }
    _binding = (stamp: stamp, session: session);
    _expected = null;
    reports.add(ShadowSessionOpened(strategyId, session, because));
  }

  Future<bool> _arrive(
    String strategyId,
    String what,
    ArrivedBase base,
    int stamp,
  ) async {
    final binding = _binding;
    if (binding == null || binding.stamp != stamp || _stamp != stamp) {
      reports.add(
        ShadowSkipped(strategyId, what, 'received on a connection that ended'),
      );
      return false;
    }
    final recorded = await _record(strategyId, what, [
      BaseArrived(base, session: binding.session),
    ]);
    if (recorded == null) return false;
    for (final outcome in recorded.outcomes) {
      if (outcome case ReportNotApplicable(:final why)) {
        reports.add(ShadowNotApplied(strategyId, what, '$why'));
        return false;
      }
    }
    reports.add(ShadowRecorded(strategyId, what, binding.session));
    return true;
  }

  Future<Recorded?> _record(
    String strategyId,
    String what,
    List<QueueEvent> events,
  ) async {
    switch (await store.record(strategyId, events)) {
      case Saved(:final value):
        return value;
      case NothingToSave():
        return null;
      case Refused(:final reason):
        reports.add(ShadowRefused(strategyId, what, reason));
      case NotSaved(:final failure):
        reports.add(ShadowStoreFailed(what, failure, StoreStep.refusedSave));
      case SaveInDoubt(:final failure):
        reports.add(ShadowStoreFailed(what, failure, StoreStep.saveInDoubt));
    }
    return null;
  }

  Future<int?> _sessionOf(String strategyId) async =>
      switch (await store.readStrategy(strategyId)) {
        Found(value: StrategyContent(sync: CloudStrategy(:final queue))) =>
          queue.session.number,
        Found() || NotFound() || InUnreadableStrategy() => null,
        NotRead(:final failure) => () {
            reports.add(ShadowStoreFailed(
              'reading the session back',
              failure,
              StoreStep.read,
            ));
            return null;
          }(),
      };

  _Expected _expectedFor(String pageId) => switch (_expected) {
        final expected? when expected.pageId == pageId => expected,
        _ => _expected = _Expected(pageId),
      };

  void _expectHeader(HeaderRead header) {
    final expected = _expected;
    if (expected == null) return;
    for (final page in header.pages) {
      if (page.publicId == expected.pageId) expected.page = page;
    }
    for (final settings in header.settings) {
      if (settings.pagePublicId == expected.pageId) {
        expected.settings = settings;
      }
    }
  }

  void _expectPage(PageRead read, PageSettingsRow settings) {
    final expected = _expectedFor(read.page.publicId)
      ..page = read.page
      ..settings = settings
      ..elements = {for (final row in read.elements) row.publicId: row}
      ..lineupGroups = {
        for (final row in read.lineupGroups) row.publicId: row,
      };
    _expected = expected;
  }

  Future<void> _check(String strategyId) async {
    final expected = _expected;
    if (expected == null || !expected.complete) return;
    switch (await store.readPage(strategyId, expected.pageId)) {
      case Found(:final value):
        final differences = pageDifferences(
          shown: value,
          page: expected.page!,
          settings: expected.settings!,
          elements: expected.elements!,
          lineupGroups: expected.lineupGroups!,
        );
        reports.add(
          differences.isEmpty
              ? ShadowEqual(
                  strategyId,
                  expected.pageId,
                  2 + expected.elements!.length + expected.lineupGroups!.length,
                )
              : ShadowDiffers(strategyId, expected.pageId, differences),
        );
      case NotFound():
        reports.add(ShadowDiffers(
          strategyId,
          expected.pageId,
          const ['the store does not hold the page'],
        ));
      case NotRead(:final failure):
        reports.add(
          ShadowStoreFailed('reading the page back', failure, StoreStep.read),
        );
      case InUnreadableStrategy():
        reports.add(ShadowDiffers(
          strategyId,
          expected.pageId,
          const ['the store lists the strategy as unreadable'],
        ));
    }
  }
}

List<String> pageDifferences({
  required PageContent shown,
  required PageRow page,
  required PageSettingsRow settings,
  required Map<String, ElementRow> elements,
  required Map<String, LineupGroupRow> lineupGroups,
}) =>
    [
      if (shown.page != page) 'page row: ${_rowWords(shown.page, page)}',
      switch (shown.settings) {
        SettingsStored(:final row) when row == settings => null,
        SettingsStored(:final row) =>
          'page settings: ${_rowWords(row, settings)}',
        NoSettingsStored() => 'page settings: the store holds none',
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
    ].nonNulls.toList();

Iterable<String> _differences<T extends Row>(
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
      null => 'nothing',
      _ => '${row.runtimeType}',
    };
