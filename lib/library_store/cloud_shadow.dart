import 'dart:async';
import 'dart:collection';

import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/library_store/library_store_switch.dart'
    show cloudShadowOff;
import 'package:icarus/library_store/server_rows.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus_library/icarus_library.dart';

enum SkipReason {
  receivedOffline('received while the app counted itself offline'),
  endedConnection('read on a connection that has since ended'),
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

final class RefusedByStore extends Verdict {
  const RefusedByStore(this.why);

  final String why;
}

final class ReadFailed extends Verdict {
  const ReadFailed(this.why);

  final String why;
}

final class LedgerEntry {
  LedgerEntry(this.strategyId, this.what, {this.pageId});

  final String strategyId;
  final String what;
  final String? pageId;
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

final class ShadowEnded extends CloudShadowReport {
  const ShadowEnded(this.reason);

  final String reason;
}

final class ShadowStopped extends CloudShadowReport {
  const ShadowStopped(this.reason);

  final String reason;
}

final class _StoppedNow implements Exception {
  const _StoppedNow();
}

final class _Strategy {
  bool inStore = false;
  int? bound;
  int? newest;
  int? lostConnection;
  final expected = ServerRows();
  final waiting = <_Job>[];
}

sealed class _Job {
  const _Job(this.entry);

  final LedgerEntry? entry;
}

final class _PageJob extends _Job {
  const _PageJob(LedgerEntry super.entry, this.page, this.connection);

  final RemotePageSnapshot page;
  final int? connection;
}

final class _ListJob extends _Job {
  const _ListJob(LedgerEntry super.entry, this.list, this.connection);

  final RemotePageList list;
  final int? connection;
}

final class _LostJob extends _Job {
  const _LostJob() : super(null);
}

final class CloudShadow {
  CloudShadow(
    this.store, {
    required this.build,
    required this.canRead,
    required Future<void> Function() breathe,
  }) : _breathe = breathe {
    throw UnsupportedError(cloudShadowOff);
  }

  static ResultPoint _noPoint() => throw UnsupportedError(cloudShadowOff);

  static Generation _noGeneration() => throw UnsupportedError(cloudShadowOff);

  final LibraryStore store;
  final String build;
  final CanRead canRead;
  final Future<void> Function() _breathe;

  final reports = <CloudShadowReport>[];
  final ledger = <LedgerEntry>[];
  String? stopped;
  String? ended;
  Account? _account;

  Account? get account => _account;

  final _jobs = ListQueue<_Job>();
  final _strategies = <String, _Strategy>{};
  final _openedThisRun = <String>{};
  Completer<void>? _running;

  Iterable<String> get strategies => _strategies.keys;

  Future<void> get idle => _running?.future ?? Future<void>.value();

  void stop(String reason) {
    if (stopped != null) return;
    stopped = reason;
    reports.add(ShadowStopped(reason));
  }

  void end(String reason) {
    if (ended != null || stopped != null) return;
    ended = reason;
    reports.add(ShadowEnded(reason));
  }

  bool get _taking => stopped == null && ended == null;

  void serve(Account served) {
    switch (_account) {
      case null:
        _account = served;
      case final serving when serving != served:
        stop('asked to serve $served while serving $serving');
      case _:
        break;
    }
  }

  Account _serving() =>
      _account ?? (throw StateError('the shadow serves no account yet'));

  void page(String strategyId, RemotePageSnapshot snapshot, int? connection) {
    if (!_taking) return;
    final pageId = snapshot.page.publicId;
    final entry = LedgerEntry(strategyId, 'page $pageId', pageId: pageId);
    ledger.add(entry);
    _add(_PageJob(entry, snapshot, connection));
  }

  void pageList(String strategyId, RemotePageList list, int? connection) {
    if (!_taking) return;
    final entry = LedgerEntry(strategyId, 'the page list');
    ledger.add(entry);
    _add(_ListJob(entry, list, connection));
  }

  void connectionLost() => _add(const _LostJob());

  void _add(_Job job, {bool first = false}) {
    if (stopped != null) return;
    if (first) {
      _jobs.addFirst(job);
    } else {
      _jobs.add(job);
    }
    if (_running == null) unawaited(_pump());
  }

  Future<void> _pump() async {
    final running = _running = Completer<void>();
    try {
      while (_jobs.isNotEmpty && stopped == null) {
        await _breathe();
        if (stopped != null || _jobs.isEmpty) break;
        await _run(_jobs.removeFirst());
      }
    } catch (error) {
      stop('$error');
    } finally {
      _running = null;
      running.complete();
    }
  }

  Future<void> _run(_Job job) async {
    try {
      switch (job) {
        case _PageJob(:final entry, :final page, :final connection):
          await _page(entry!, page, connection);
        case _ListJob(:final entry, :final list, :final connection):
          await _list(entry!, list, connection);
        case _LostJob():
          await _lost();
      }
    } on _StoppedNow {
      return;
    } catch (error) {
      stop('$error');
    }
  }

  Future<T> _write<T>(Future<T> Function() write) async {
    if (stopped != null) throw const _StoppedNow();
    final written = await write();
    if (stopped != null) throw const _StoppedNow();
    return written;
  }

  Future<T> _read<T>(Future<T> Function() read) async {
    final value = await read();
    if (stopped != null) throw const _StoppedNow();
    return value;
  }

  _Strategy _of(String strategyId) => _strategies[strategyId] ??= _Strategy();

  bool _admit(LedgerEntry entry, int? connection) {
    if (connection == null) {
      entry.verdict = const Skipped(SkipReason.receivedOffline);
      return false;
    }
    final state = _of(entry.strategyId);
    final ended = switch ((state.lostConnection, state.newest)) {
      (final lost?, _) when connection <= lost => true,
      (_, final newest?) when connection < newest => true,
      _ => false,
    };
    if (ended) {
      entry.verdict = const Skipped(SkipReason.endedConnection);
      return false;
    }
    return true;
  }

  Future<void> _lost() async {
    for (final MapEntry(key: strategyId, value: state) in _strategies.entries) {
      final bound = state.bound;
      if (!state.inStore || bound == null) continue;
      if (state.lostConnection == bound) continue;
      state.lostConnection = bound;
      if (await _record(strategyId, null, [const ConnectionLost()]) != null) {
        reports.add(ShadowConnectionLost(strategyId));
      }
    }
  }

  Future<void> _page(
    LedgerEntry entry,
    RemotePageSnapshot snapshot,
    int? connection,
  ) async {
    if (!_admit(entry, connection)) return;
    final state = _of(entry.strategyId);
    if (!state.inStore) {
      state.waiting.add(_PageJob(entry, snapshot, connection));
      return;
    }
    if (!await _bindFor(entry, state, connection!)) return;
    final PageRead read;
    switch (pageRead(snapshot, canRead)) {
      case RowsRead(:final value):
        read = value;
      case RowsUnreadable(:final problem):
        entry.verdict =
            ReadFailed('the server rows could not be read: $problem');
        return;
    }
    if (await _arrive(entry, read)) {
      state.expected.page(read);
      await _compare(entry, pages: {read.page.publicId});
    }
  }

  Future<void> _list(
    LedgerEntry entry,
    RemotePageList list,
    int? connection,
  ) async {
    if (!_admit(entry, connection)) return;
    final state = _of(entry.strategyId);
    final HeaderRead header;
    switch (pageListRead(list)) {
      case RowsRead(:final value):
        header = value;
      case RowsUnreadable(:final problem):
        entry.verdict =
            ReadFailed('the server rows could not be read: $problem');
        return;
    }
    if (!state.inStore) {
      await _start(entry, state, header, connection!);
      if (!state.inStore) return;
      for (final waiting in state.waiting.reversed) {
        _add(waiting, first: true);
      }
      state.waiting.clear();
      return;
    }
    if (!await _bindFor(entry, state, connection!)) return;
    if (await _arrive(entry, header)) {
      state.expected.header(header);
      await _compare(entry, pages: const {});
    }
  }

  Future<bool> _bindFor(
    LedgerEntry entry,
    _Strategy state,
    int connection,
  ) async {
    if (state.bound == connection) return true;
    return _open(
      entry,
      state,
      connection,
      'the connection came back',
      [ConnectionReturned(_noGeneration())],
    );
  }

  Future<bool> _open(
    LedgerEntry entry,
    _Strategy state,
    int connection,
    String because,
    List<QueueEvent> events,
  ) async {
    state.bound = null;
    state.newest = connection;
    if (await _record(entry.strategyId, entry, events) == null) return false;
    final session = await _sessionOf(entry);
    if (session == null) return false;
    state.bound = connection;
    reports.add(ShadowSessionOpened(entry.strategyId, session, because));
    return true;
  }

  Future<void> _start(
    LedgerEntry entry,
    _Strategy state,
    HeaderRead header,
    int connection,
  ) async {
    final strategyId = entry.strategyId;
    final StrategySummary? listed;
    switch (store.library) {
      case LibraryOpen(:final list):
        listed = list.strategies
            .where((summary) => summary.publicId == strategyId)
            .firstOrNull;
      case LibraryShut(:final failure):
        entry.verdict = RefusedByStore(
          'the store is shut: ${storageFailureWords(failure, StoreStep.read)}',
        );
        return;
    }
    switch (listed?.sync) {
      case null:
        _openedThisRun.add(strategyId);
        state.newest = connection;
        final added = await _write(
          () => store.addCloudStrategy(
            _serving(),
            StampedRead(header, _noPoint()),
            const [],
          ),
        );
        switch (added) {
          case Saved():
            final session = await _sessionOf(entry);
            if (session == null) return;
            state.bound = connection;
            state.inStore = true;
            reports.add(
              ShadowSessionOpened(
                  strategyId, session, 'the strategy was added'),
            );
            state.expected.header(header);
            await _compare(entry, pages: const {});
          case NothingToSave():
            entry.verdict = const RefusedByStore('the store saved nothing');
          case Refused(:final reason):
            entry.verdict = RefusedByStore(
              'the store refused it: ${reason.runtimeType} $reason',
            );
          case NotSaved(:final failure):
            entry.verdict = RefusedByStore(
              storageFailureWords(failure, StoreStep.refusedSave),
            );
          case SaveInDoubt(:final failure):
            entry.verdict = RefusedByStore(
              storageFailureWords(failure, StoreStep.saveInDoubt),
            );
        }
      case KeptHere():
        entry.verdict = const RefusedByStore(
          'the store holds this id as a strategy kept on this device',
        );
      case KeptInCloud() || CloudUnverified():
        final restarted = _openedThisRun.add(strategyId);
        if (!await _open(
          entry,
          state,
          connection,
          restarted ? 'the app started' : 'the strategy was opened again',
          [
            if (restarted) AppRestarted(build: build),
            ConnectionReturned(_noGeneration()),
          ],
        )) {
          return;
        }
        state.inStore = true;
        if (await _arrive(entry, header)) {
          state.expected.header(header);
          await _compare(entry, pages: const {});
        }
    }
  }

  Future<bool> _arrive(LedgerEntry entry, ArrivedBase base) async {
    final session = await _sessionOf(entry);
    if (session == null) return false;
    final recorded = await _record(entry.strategyId, entry, [
      BaseArrived(base, session: session, point: _noPoint()),
    ]);
    if (recorded == null) return false;
    for (final outcome in recorded.outcomes) {
      switch (outcome) {
        case ReportNotApplicable(why: FromAnEndedSession()):
          entry.verdict = const Skipped(SkipReason.endedSession);
          return false;
        case ReportNotApplicable(:final why):
          entry.verdict = RefusedByStore('the queue did not apply it: $why');
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
    void refused(String why) {
      if (entry != null) {
        entry.verdict = RefusedByStore(why);
      } else {
        stop(why);
      }
    }

    switch (await _write(
      () => store.record(_serving(), strategyId, events),
    )) {
      case Saved(:final value):
        return value;
      case NothingToSave():
        refused('the store saved nothing');
      case Refused(:final reason):
        refused('the store refused it: ${reason.runtimeType} $reason');
      case NotSaved(:final failure):
        refused(storageFailureWords(failure, StoreStep.refusedSave));
      case SaveInDoubt(:final failure):
        refused(storageFailureWords(failure, StoreStep.saveInDoubt));
    }
    return null;
  }

  Future<int?> _sessionOf(LedgerEntry entry) async {
    switch (await _read(() => store.readStrategy(entry.strategyId))) {
      case Found(value: StrategyContent(sync: CloudStrategy(:final queue))):
        return queue.session.number;
      case Found():
        entry.verdict = const RefusedByStore('the store holds no cloud queue');
      case NotFound():
        entry.verdict = const RefusedByStore('the store does not hold it');
      case InUnreadableStrategy():
        entry.verdict =
            const RefusedByStore('the store lists it as unreadable');
      case NotRead(:final failure):
        entry.verdict =
            RefusedByStore(storageFailureWords(failure, StoreStep.read));
    }
    return null;
  }

  Future<void> _compare(LedgerEntry entry, {required Set<String> pages}) async {
    final differences = await _read(
      () => differencesFromServer(
        store,
        entry.strategyId,
        _of(entry.strategyId).expected,
        account: account,
        pages: pages,
      ),
    );
    entry.verdict = differences.isEmpty
        ? const ComparedEqual()
        : ComparedDifferent(differences);
  }

  Future<Map<String, List<String>>> readBack(LibraryStore other) async => {
        for (final MapEntry(key: strategyId, value: state)
            in _strategies.entries)
          if (state.inStore)
            strategyId: await differencesFromServer(
              other,
              strategyId,
              state.expected,
              account: account,
              pages: null,
            ),
      };
}
