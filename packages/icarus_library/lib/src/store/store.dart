import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';

import '../apply.dart';
import '../derived_id.dart';
import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../payloads.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import '../wire.dart';
import 'engine.dart';
import 'journal.dart';
import 'layout.dart';
import 'loaded_strategy.dart';
import 'results.dart';
import 'summary.dart';

typedef CanRead = bool Function(ElementPayload payload);

sealed class StoreOpening {
  const StoreOpening();
}

final class StoreOpened extends StoreOpening {
  const StoreOpened(this.store);

  final LibraryStore store;
}

final class StoreNotOpened extends StoreOpening {
  const StoreNotOpened(this.problem);

  final OpenProblem problem;
}

sealed class _State {
  const _State();
}

final class _Ready extends _State {
  const _Ready();
}

final class _Finishing extends _State {
  const _Finishing(this.record);

  final JournalRecord record;
}

final class _Stopped extends _State {
  const _Stopped(this.cause);

  final StorageFailure cause;
}

final class _Closed extends _State {
  const _Closed();
}

DateTime _now() => DateTime.now().toUtc();

String _stored(Row row) => canonicalJson(row.toJson());

String _id(String segment) => idOf(segment) ?? segment;

final class _WatchedLease implements StorageLease {
  _WatchedLease(this._inner, this._ended);

  final StorageLease _inner;
  final void Function() _ended;

  Future<Stored<T>> _watch<T>(Future<Stored<T>> stored) async {
    final result = await stored;
    if (result case StorageFailed(failure: LeaseEnded())) _ended();
    return result;
  }

  @override
  int get maxKeyLength => _inner.maxKeyLength;

  Future<Stored<String?>> text(String area, String key) async =>
      switch (await read(area, key)) {
        KeyHeld(:final value) => Done(value),
        KeyMissing() => const Done(null),
        KeyNotRead(:final failure) => StorageFailed(failure),
      };

  @override
  LeaseStatus get status => _inner.status;

  @override
  Future<KeyRead> read(String area, String key) async {
    final result = await _inner.read(area, key);
    if (result case KeyNotRead(failure: LeaseEnded())) _ended();
    return result;
  }

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _watch(_inner.entries(area, prefix));

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      _watch(_inner.keys(area, prefix));

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) =>
      _watch(_inner.write(area, values));

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) =>
      _watch(_inner.delete(area, keys));

  @override
  Future<Releasing> release() => _inner.release();
}

final class LibraryStore {
  LibraryStore._(StorageLease lease, this._canRead, this._clock) {
    _lease = _WatchedLease(lease, _leaseEnded);
  }

  static Future<StoreOpening> open(
    StorageEngine engine, {
    required CanRead canRead,
    DateTime Function() clock = _now,
  }) async {
    switch (await engine.lease()) {
      case HeldByAnotherWriter():
        return const StoreNotOpened(StoreAlreadyOpen());
      case LeaseFailed(:final failure):
        return StoreNotOpened(OpenStorageFailed(failure));
      case Leased(:final lease):
        StoreOpening? opening;
        try {
          opening = await _open(lease, canRead, clock);
          return opening;
        } finally {
          if (opening is! StoreOpened) await lease.release();
        }
    }
  }

  static Future<StoreOpening> _open(
    StorageLease lease,
    CanRead canRead,
    DateTime Function() clock,
  ) async {
    final store = LibraryStore._(lease, canRead, clock);
    switch (await store._lease.text(journalArea, journalKey)) {
      case StorageFailed(:final failure):
        return StoreNotOpened(OpenStorageFailed(failure));
      case Done(value: null):
        break;
      case Done(value: final String text):
        switch (JournalRecord.decode(text)) {
          case CouldNotRead(:final problem):
            return StoreNotOpened(SavedEditUnreadable(text, problem));
          case Read(value: final record):
            if (await record.recover(store._lease) case StorageFailed(
              :final failure,
            )) {
              return StoreNotOpened(OpenStorageFailed(failure));
            }
            if (await JournalRecord.clear(store._lease) case StorageFailed(
              :final failure,
            )) {
              return StoreNotOpened(OpenStorageFailed(failure));
            }
        }
    }
    if (await store._readLibrary() case final failure?) {
      return StoreNotOpened(OpenStorageFailed(failure));
    }
    return StoreOpened(store);
  }

  late final _WatchedLease _lease;
  final CanRead _canRead;
  final DateTime Function() _clock;
  _State _state = const _Ready();
  Future<void> _tail = Future.value();
  final _summaries = <String, StrategySummary>{};
  final _unreadableStrategies = <String, UnreadableStrategy>{};
  final _folders = <String, FolderRow>{};
  final _strategies = <String, LoadedStrategy>{};
  final _changes = StreamController<StoreChange>.broadcast();

  Stream<StoreChange> get changes => _changes.stream;

  LibraryList get library => LibraryList(
    strategies: _summaries.values.toList(),
    unreadableStrategies: _unreadableStrategies.values.toList(),
    folders: _folders.values.toList(),
  );

  void _leaseEnded() {
    if (_state is! _Closed) _state = const _Stopped(LeaseEnded());
  }

  Future<void> close() => _inTurn(() async {
    if (_state is _Closed) return;
    _state = const _Closed();
    await _lease.release();
    unawaited(_changes.close());
  });

  Future<T> _inTurn<T>(FutureOr<T> Function() task) async {
    final previous = _tail;
    final turn = Completer<void>();
    _tail = turn.future;
    await previous;
    try {
      return await task();
    } finally {
      turn.complete();
    }
  }

  Future<StorageFailure?> _finish(JournalRecord record) async {
    if (await record.replay(_lease) case StorageFailed(:final failure)) {
      return failure;
    }
    if (await JournalRecord.clear(_lease) case StorageFailed(:final failure)) {
      return failure;
    }
    return null;
  }

  Future<StorageFailure?> _settle() async {
    switch (_state) {
      case _Ready():
        return null;
      case _Stopped(:final cause):
        return StoreStopped(cause);
      case _Closed():
        return const StoreClosed();
      case _Finishing(:final record):
        if (await _finish(record) case final failure?) return failure;
        if (_state is _Finishing) _state = const _Ready();
        return null;
    }
  }

  Future<Saving<S, R>> _save<S, R>(
    JournalRecord record,
    S Function() take,
  ) async {
    if (await _settle() case final failure?) return NotSaved(failure);
    for (final write in record.writes) {
      if (write.key.length > _lease.maxKeyLength) {
        return NotSaved(KeyTooLong(write.area, write.key));
      }
    }
    switch (await record.save(_lease)) {
      case StorageFailed(failure: final LeaseEnded failure):
        return NotSaved(failure);
      case StorageFailed(:final failure):
        if (await JournalRecord.clear(_lease) case StorageFailed()) {
          if (_state is! _Closed) _state = _Stopped(failure);
          return SaveInDoubt(failure, SaveReceipt(record.receipt));
        }
        return NotSaved(failure);
      case Done():
        break;
    }
    final saved = take();
    if (await _finish(record) != null && _state is _Ready) {
      _state = _Finishing(record);
    }
    return Saved(saved);
  }

  Future<StorageFailure?> _readLibrary() async {
    final List<String> summaryKeys;
    switch (await _lease.keys(libraryArea, summaryPrefix)) {
      case StorageFailed(:final failure):
        return failure;
      case Done(:final value):
        summaryKeys = value;
    }
    final toRebuild = <String>[];
    for (final key in summaryKeys) {
      final id = _id(key.substring(summaryPrefix.length));
      switch (await _lease.text(libraryArea, key)) {
        case StorageFailed(:final failure):
          return failure;
        case Done(value: null):
          break;
        case Done(value: final String text):
          switch (_decodeText(text, StrategySummary.decode)) {
            case final summary? when summaryKey(summary.publicId) == key:
              _summaries[summary.publicId] = summary;
            case _:
              toRebuild.add(id);
          }
      }
    }
    final List<String> folderKeys;
    switch (await _lease.keys(libraryArea, folderPrefix)) {
      case StorageFailed(:final failure):
        return failure;
      case Done(:final value):
        folderKeys = value;
    }
    for (final key in folderKeys) {
      switch (await _lease.text(libraryArea, key)) {
        case StorageFailed(:final failure):
          return failure;
        case Done(value: null):
          break;
        case Done(value: final String text):
          final folder = FolderRow.parse(
            text,
            publicId: _id(key.substring(folderPrefix.length)),
          );
          _folders[folder.publicId] = folder;
      }
    }
    for (final id in toRebuild) {
      switch (await _rebuild(id)) {
        case Saved() || NothingToSave():
          break;
        case NotSaved(:final failure) || SaveInDoubt(:final failure):
          return failure;
        case Refused(
          reason: UnreadableRowInTheWay(:final UnreadableStrategy row),
        ):
          _unreadableStrategies[id] = row;
        case Refused():
          break;
      }
    }
    return null;
  }

  static T? _decodeText<T>(String text, Decoded<T> Function(Object?) decode) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    return switch (decode(json)) {
      Read(:final value) => value,
      CouldNotRead() => null,
    };
  }

  Future<Reading<LoadedStrategy>> _strategy(String strategyPublicId) async {
    if (_strategies[strategyPublicId] case final loaded?) return Found(loaded);
    final area = strategyArea(strategyPublicId);
    final ReadableStrategy header;
    switch (await _lease.text(area, headerKey)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(value: null):
        return const NotFound();
      case Done(value: final String text):
        switch (StrategyRow.parse(text, publicId: strategyPublicId)) {
          case final UnreadableStrategy row:
            return Unreadable(row);
          case final ReadableStrategy row:
            header = row;
        }
    }
    final pages = <PageRow>[];
    switch (await _texts(area, pagePrefix)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (key, text) in value) {
          pages.add(
            PageRow.parse(
              text,
              publicId: _id(key.substring(pagePrefix.length)),
              strategyPublicId: strategyPublicId,
            ),
          );
        }
    }
    final settings = <PageSettingsRow>[];
    switch (await _texts(area, settingsPrefix)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (key, text) in value) {
          settings.add(
            PageSettingsRow.parse(
              text,
              pagePublicId: _id(key.substring(settingsPrefix.length)),
            ),
          );
        }
    }
    final List<String> contentKeys;
    switch (await _lease.keys(area, contentPrefix)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        contentKeys = value;
    }
    final loaded = LoadedStrategy(
      strategy: header,
      pages: pages,
      settings: settings,
      contentKeys: contentKeys.map(ContentKey.parse).nonNulls,
    );
    _strategies[strategyPublicId] = loaded;
    return Found(loaded);
  }

  Future<Stored<List<(String, String)>>> _texts(
    String area,
    String prefix,
  ) async => switch (await _lease.entries(area, prefix)) {
    StorageFailed(:final failure) => StorageFailed(failure),
    Done(:final value) => Done([
      for (final (:key, :value) in value) (key, value),
    ]),
  };

  Future<StorageFailure?> _loadPages(
    LoadedStrategy strategy,
    Iterable<String> pageSegments,
  ) async {
    for (final pageSegment in pageSegments) {
      if (strategy.isLoaded(pageSegment)) continue;
      if (await _loadPage(strategy, pageSegment) case final failure?) {
        return failure;
      }
    }
    return null;
  }

  Future<StorageFailure?> _loadPage(
    LoadedStrategy strategy,
    String pageSegment,
  ) async {
    final List<(String, String)> texts;
    switch (await _texts(
      strategyArea(strategy.publicId),
      '$contentPrefix$pageSegment/',
    )) {
      case StorageFailed(:final failure):
        return failure;
      case Done(:final value):
        texts = value;
    }
    final page = LoadedPage();
    for (final (key, text) in texts) {
      switch (ContentKey.parse(key)) {
        case ElementContentKey(:final idSegment):
          page.elements[idSegment] = ElementRow.parse(
            text,
            publicId: _id(idSegment),
            pagePublicId: _id(pageSegment),
            canRead: _canRead,
          );
        case LineupContentKey(:final idSegment):
          page.lineupGroups[idSegment] = LineupGroupRow.parse(
            text,
            publicId: _id(idSegment),
            strategyPublicId: strategy.publicId,
            pagePublicId: _id(pageSegment),
          );
        case OtherContentKey() || null:
          page.unknownKinds.add(UnknownKindRow(key: key, text: text));
      }
    }
    strategy.addLoadedPage(pageSegment, page);
    return null;
  }

  Future<Reading<StrategyContent>> readStrategy(String strategyPublicId) =>
      _inTurn(() async {
        if (await _settle() case final failure?) return NotRead(failure);
        switch (await _strategy(strategyPublicId)) {
          case Found(value: final strategy):
            return Found(
              StrategyContent(
                strategy: strategy.strategy,
                pages: _ordered(strategy.pages),
                settings: {...strategy.settings},
              ),
            );
          case NotFound():
            return const NotFound();
          case Unreadable(:final row):
            return Unreadable(row);
          case NotRead(:final failure):
            return NotRead(failure);
        }
      });

  Future<Reading<PageContent>> readPage(
    String strategyPublicId,
    String pagePublicId,
  ) => _inTurn(() async {
    if (await _settle() case final failure?) return NotRead(failure);
    final LoadedStrategy strategy;
    switch (await _strategy(strategyPublicId)) {
      case Found(:final value):
        strategy = value;
      case NotFound():
        return const NotFound();
      case Unreadable(:final row):
        return Unreadable(row);
      case NotRead(:final failure):
        return NotRead(failure);
    }
    final page = strategy.page(pagePublicId);
    if (page == null) return const NotFound();
    final pageSegment = segment(pagePublicId);
    if (await _loadPages(strategy, [pageSegment]) case final failure?) {
      return NotRead(failure);
    }
    final loaded = strategy.loadedPage(pageSegment)!;
    return Found(
      PageContent(
        page: page,
        settings: strategy.settingsOf(pagePublicId),
        elements: loaded.elements.values.toList(),
        lineupGroups: loaded.lineupGroups.values.toList(),
        unknownKinds: loaded.unknownKinds,
      ),
    );
  });

  Future<Unloading> unload(String strategyPublicId) => _inTurn(() async {
    if (await _settle() case final failure?) return NotUnloaded(failure);
    _strategies.remove(strategyPublicId);
    return const Unloaded();
  });

  Future<Recovery> recovered(SaveReceipt receipt) => _inTurn(() async {
    if (await _settle() case final failure?) return RecoveryNotRead(failure);
    return switch (await _lease.text(journalArea, recoveredKey(receipt.id))) {
      StorageFailed(:final failure) => RecoveryNotRead(failure),
      Done(value: null) => const EditNotRecovered(),
      Done(value: String()) => const EditRecovered(),
    };
  });

  static List<PageRow> _ordered(Iterable<PageRow> pages) => pages.sorted(
    (a, b) => switch ((_placeOf(a), _placeOf(b))) {
      (final x, final y) when x != y => x.compareTo(y),
      _ => a.publicId.compareTo(b.publicId),
    },
  );

  static int _placeOf(PageRow page) => switch (page) {
    ReadablePageRow(:final sortIndex) => sortIndex,
    UnreadablePage(:final sortIndex) => sortIndex ?? 1 << 31,
  };

  Iterable<String> _pagesFor(StrategyOp op, LoadedStrategy strategy) =>
      switch (op) {
        StrategyPatchOp() ||
        PagePatchOp() ||
        PageDeleteOp() ||
        PageReorderOp() ||
        PageSettingsPatchOp() => const [],
        PageAddOp(copyContentFromPagePublicId: null, :final pagePublicId) => [
          segment(pagePublicId),
        ],
        PageAddOp(:final pagePublicId) => {
          ...strategy.pageSegments,
          segment(pagePublicId),
        },
        ElementAddOp(:final pagePublicId, :final elementPublicId) => [
          segment(pagePublicId),
          ?strategy.pageOfElement(elementPublicId),
        ],
        ElementPatchOp(:final pagePublicId, :final elementPublicId) => [
          if (pagePublicId != null) segment(pagePublicId),
          ?strategy.pageOfElement(elementPublicId),
        ],
        ElementDeleteOp(:final elementPublicId) ||
        ElementReorderOp(
          :final elementPublicId,
        ) => [?strategy.pageOfElement(elementPublicId)],
        LineupGroupAddOp(:final pagePublicId, :final lineupPublicId) => [
          segment(pagePublicId),
          ?strategy.pageOfLineupGroup(lineupPublicId),
        ],
        LineupGroupPatchOp(:final pagePublicId, :final lineupPublicId) => [
          if (pagePublicId != null) segment(pagePublicId),
          ?strategy.pageOfLineupGroup(lineupPublicId),
        ],
        LineupGroupDeleteOp(:final lineupPublicId) ||
        LineupGroupReorderOp(
          :final lineupPublicId,
        ) => [?strategy.pageOfLineupGroup(lineupPublicId)],
      };

  static bool _isUnreadable(Row? row) => switch (row) {
    UnreadableStrategy() ||
    UnreadableFolder() ||
    UnreadablePage() ||
    UnreadablePageSettings() ||
    UnreadableElement() ||
    UnreadableLineupGroup() => true,
    _ => false,
  };

  static List<RowWrite> _stamped(
    ReadableStrategy header,
    List<RowWrite> writes,
    DateTime now,
  ) {
    final stamped = <RowWrite>[];
    var touched = false;
    for (final write in writes) {
      switch (write) {
        case RowChanged(
          :final before,
          after: final ReadableStrategy after,
          :final fields,
          :final dataFields,
        ):
          touched = true;
          stamped.add(
            RowChanged(
              before: before,
              after: after.rewritten(updatedAt: now),
              fields: {...fields, RowField.updatedAt},
              dataFields: dataFields,
            ),
          );
        case _:
          stamped.add(write);
      }
    }
    if (!touched) {
      stamped.add(
        RowChanged(
          before: header,
          after: header.rewritten(updatedAt: now),
          fields: {RowField.updatedAt},
        ),
      );
    }
    return stamped;
  }

  Future<CommitResult> commit(String strategyPublicId, StrategyOp op) =>
      _inTurn(() async {
        if (await _settle() case final failure?) return NotSaved(failure);
        final LoadedStrategy strategy;
        switch (await _strategy(strategyPublicId)) {
          case Found(:final value):
            strategy = value;
          case NotFound():
            return Refused(NoSuchStrategy(strategyPublicId));
          case Unreadable(:final row):
            return Refused(UnreadableRowInTheWay(row));
          case NotRead(:final failure):
            return NotSaved(failure);
        }
        final summary = _summaries[strategyPublicId];
        if (summary == null) return Refused(NoSuchStrategy(strategyPublicId));
        if (await _loadPages(strategy, _pagesFor(op, strategy))
            case final failure?) {
          return NotSaved(failure);
        }
        final OpApplied applied;
        switch (applyOp(strategy, op)) {
          case OpUnchanged():
            return const NothingToSave();
          case OpRefused(:final refusal):
            return Refused(OpRefusal(refusal));
          case final OpApplied result:
            applied = result;
        }
        final writes = _stamped(strategy.strategy, applied.writes, _clock());
        final area = strategyArea(strategyPublicId);
        final keys = KeyWrites();
        for (final write in writes) {
          if (_isUnreadable(strategy.current(write.after))) {
            return Refused(OpRefusal(UnreadableTarget(write.after.key)));
          }
          final key = rowKey(write.after);
          keys.put(area, key, _stored(write.after));
          if (write case RowChanged(:final before) when rowKey(before) != key) {
            keys.delete(area, rowKey(before));
          }
        }
        final (header, pages) = strategy.headerAfter(writes);
        final summaryAfter = summary.after(header, pages, writes);
        keys.put(
          libraryArea,
          summaryKey(strategyPublicId),
          canonicalJson(summaryAfter.toJson()),
        );
        final CommitResult result = await _save(
          JournalRecord(
            receipt: op.opId,
            edit: {'strategyPublicId': strategyPublicId, 'op': op.toJson()},
            writes: keys.writes,
          ),
          () {
            strategy.take(writes);
            _summaries[strategyPublicId] = summaryAfter;
            return Committed(
              change: StrategyEdited(
                strategyPublicId: strategyPublicId,
                opId: op.opId,
                writes: writes,
                removed: const [],
                summary: summaryAfter,
              ),
              undo: applied.undo,
            );
          },
        );
        if (result case Saved(:final value)) _changes.add(value.change);
        return result;
      });

  Future<RebuildResult> rebuildSummary(String strategyPublicId) =>
      _inTurn(() async {
        final result = await _rebuild(strategyPublicId);
        if (result case Saved(:final value)) {
          _changes.add(
            LibraryEdited(
              summaries: [value],
              removedStrategies: const [],
              folders: const [],
              removedFolders: const [],
            ),
          );
        }
        return result;
      });

  String _receipt(Object? what) =>
      derivedId(jsonEncode([what, _clock().microsecondsSinceEpoch]));

  Future<RebuildResult> _rebuild(String strategyPublicId) async {
    if (await _settle() case final failure?) return NotSaved(failure);
    final LoadedStrategy strategy;
    switch (await _strategy(strategyPublicId)) {
      case Found(:final value):
        strategy = value;
      case NotFound():
        return Refused(NoSuchStrategy(strategyPublicId));
      case Unreadable(:final row):
        return Refused(UnreadableRowInTheWay(row));
      case NotRead(:final failure):
        return NotSaved(failure);
    }
    if (await _loadPages(strategy, strategy.pageSegments) case final failure?) {
      return NotSaved(failure);
    }
    final rebuilt = _summaryOf(strategy);
    if (rebuilt == _summaries[strategyPublicId]) return const NothingToSave();
    final keys = KeyWrites()
      ..put(
        libraryArea,
        summaryKey(strategyPublicId),
        canonicalJson(rebuilt.toJson()),
      );
    return _save(
      JournalRecord(
        receipt: _receipt(['rebuildSummary', strategyPublicId]),
        edit: {'rebuildSummary': strategyPublicId},
        writes: keys.writes,
      ),
      () {
        _summaries[strategyPublicId] = rebuilt;
        _unreadableStrategies.remove(strategyPublicId);
        return rebuilt;
      },
    );
  }

  StrategySummary _summaryOf(LoadedStrategy strategy) {
    final tallies = <String, PageTally>{};
    for (final pageSegment in strategy.pageSegments) {
      for (final row in strategy.elementsOnSegment(pageSegment)) {
        tallies[row.pagePublicId] =
            (tallies[row.pagePublicId] ?? PageTally.empty).plus(row, 1);
      }
    }
    return StrategySummary.of(
      strategy: strategy.strategy,
      pages: strategy.pages,
      tallies: tallies,
    );
  }

  Future<LibraryEditResult> editLibrary(List<LibraryChange> changes) =>
      _inTurn(() async {
        if (await _settle() case final failure?) return NotSaved(failure);
        final edit = _LibraryEdit(this);
        for (final change in changes) {
          final outcome = await edit.add(change);
          if (outcome != null) return outcome;
        }
        if (edit.isEmpty) return const NothingToSave();
        final result = await _save<LibraryEdited, LibraryRefusal>(
          JournalRecord(
            receipt: _receipt(['library', edit.described]),
            edit: {'library': edit.described},
            writes: edit.writes,
          ),
          edit.take,
        );
        if (result case Saved(:final value)) _changes.add(value);
        return result;
      });
}

final class _LibraryEdit {
  _LibraryEdit(this._store)
    : _folders = {..._store._folders},
      _summaries = {..._store._summaries};

  final LibraryStore _store;
  final Map<String, FolderRow> _folders;
  final Map<String, StrategySummary> _summaries;
  final _keys = KeyWrites();
  final described = <Object?>[];
  final _headers = <String, ReadableStrategy>{};
  final _putSummaries = <String, StrategySummary>{};
  final _removedStrategies = <String>{};
  final _putFolders = <String, ReadableFolder>{};
  final _removedFolders = <String>{};

  bool get isEmpty => described.isEmpty;

  List<KeyWrite> get writes => _keys.writes;

  bool _hasStrategy(String id) =>
      _summaries.containsKey(id) ||
      _store._unreadableStrategies.containsKey(id);

  RowKey? _outside(StrategyRowSet rows) {
    final id = rows.strategy.publicId;
    final pages = {for (final page in rows.pages) page.publicId};
    for (final page in rows.pages) {
      if (page.strategyPublicId != id) return page.key;
    }
    for (final row in rows.settings) {
      if (!pages.contains(row.pagePublicId)) return row.key;
    }
    for (final row in rows.elements) {
      if (!pages.contains(row.pagePublicId)) return row.key;
    }
    for (final row in rows.lineupGroups) {
      if (row.strategyPublicId != id || !pages.contains(row.pagePublicId)) {
        return row.key;
      }
    }
    return null;
  }

  Future<LibraryEditResult?> add(LibraryChange change) async {
    switch (change) {
      case AddStrategy(:final rows):
        final id = rows.strategy.publicId;
        if (_hasStrategy(id) || _removedStrategies.contains(id)) {
          return Refused(StrategyAlreadyInStore(id));
        }
        if (_outside(rows) case final key?) {
          return Refused(RowOutsideStrategy(key));
        }
        if (rows.strategy.folderPublicId case final folder?
            when _folders[folder] is! ReadableFolder) {
          return Refused(NoSuchFolder(folder));
        }
        final area = strategyArea(id);
        switch (await _store._lease.keys(area, '')) {
          case StorageFailed(:final failure):
            return NotSaved(failure);
          case Done(value: final keys) when keys.isNotEmpty:
            return Refused(StrategyAlreadyInStore(id));
          case Done():
            break;
        }
        _headers[id] = rows.strategy;
        for (final row in rows.rows) {
          _keys.put(area, rowKey(row), _stored(row));
        }
        final tallies = <String, PageTally>{};
        for (final row in rows.elements) {
          tallies[row.pagePublicId] =
              (tallies[row.pagePublicId] ?? PageTally.empty).plus(row, 1);
        }
        _putSummary(
          StrategySummary.of(
            strategy: rows.strategy,
            pages: rows.pages,
            tallies: tallies,
          ),
        );
        described.add({'addStrategy': id});
      case RemoveStrategy(:final strategyPublicId):
        if (!_hasStrategy(strategyPublicId)) {
          return Refused(NoSuchStrategy(strategyPublicId));
        }
        final area = strategyArea(strategyPublicId);
        _keys.dropArea(area);
        _headers.remove(strategyPublicId);
        switch (await _store._lease.keys(area, '')) {
          case StorageFailed(:final failure):
            return NotSaved(failure);
          case Done(value: final keys):
            for (final key in keys) {
              _keys.delete(area, key);
            }
        }
        _keys.delete(libraryArea, summaryKey(strategyPublicId));
        _summaries.remove(strategyPublicId);
        _putSummaries.remove(strategyPublicId);
        _removedStrategies.add(strategyPublicId);
        described.add({'removeStrategy': strategyPublicId});
      case MoveStrategy(:final strategyPublicId, :final folderPublicId):
        final summary = _summaries[strategyPublicId];
        if (summary == null) return Refused(NoSuchStrategy(strategyPublicId));
        if (folderPublicId != null &&
            _folders[folderPublicId] is! ReadableFolder) {
          return Refused(NoSuchFolder(folderPublicId));
        }
        final ReadableStrategy current;
        switch (await _header(strategyPublicId)) {
          case Found(:final value):
            current = value;
          case NotFound():
            return Refused(NoSuchStrategy(strategyPublicId));
          case Unreadable(:final row):
            return Refused(UnreadableRowInTheWay(row));
          case NotRead(:final failure):
            return NotSaved(failure);
        }
        if (current.folderPublicId == folderPublicId) return null;
        final moved = current.rewritten(
          folder: switch (folderPublicId) {
            final folder? => SetValue(folder),
            null => const ClearValue(),
          },
          revision: current.revision + 1,
          updatedAt: _store._clock(),
        );
        _headers[strategyPublicId] = moved;
        _keys.put(strategyArea(strategyPublicId), headerKey, _stored(moved));
        _putSummary(summary.withHeader(moved));
        described.add({
          'moveStrategy': strategyPublicId,
          'folderPublicId': folderPublicId,
        });
      case PutFolder(:final folder):
        final id = folder.publicId;
        if (_folders[id] case final UnreadableFolder row) {
          return Refused(UnreadableRowInTheWay(row));
        }
        if (folder.parentFolderPublicId case final parent?) {
          if (_folders[parent] is! ReadableFolder) {
            return Refused(NoSuchFolder(parent));
          }
          for (
            String? at = parent;
            at != null;
            at = switch (_folders[at]) {
              ReadableFolder(:final parentFolderPublicId) =>
                parentFolderPublicId,
              _ => null,
            }
          ) {
            if (at == id) return Refused(FolderInsideItself(id));
          }
        }
        if (_folders[id] == folder) return null;
        _folders[id] = folder;
        _putFolders[id] = folder;
        _removedFolders.remove(id);
        _keys.put(libraryArea, folderKey(id), _stored(folder));
        described.add({'putFolder': id});
      case RemoveFolder(:final folderPublicId):
        switch (_folders[folderPublicId]) {
          case null:
            return null;
          case final UnreadableFolder row:
            return Refused(UnreadableRowInTheWay(row));
          case ReadableFolder():
            break;
        }
        final holdsFolder = _folders.values.any(
          (folder) =>
              folder is ReadableFolder &&
              folder.parentFolderPublicId == folderPublicId,
        );
        final holdsStrategy = _summaries.values.any(
          (summary) => summary.folderPublicId == folderPublicId,
        );
        if (holdsFolder || holdsStrategy) {
          return Refused(FolderNotEmpty(folderPublicId));
        }
        _folders.remove(folderPublicId);
        _putFolders.remove(folderPublicId);
        _removedFolders.add(folderPublicId);
        _keys.delete(libraryArea, folderKey(folderPublicId));
        described.add({'removeFolder': folderPublicId});
    }
    return null;
  }

  Future<Reading<ReadableStrategy>> _header(String strategyPublicId) async {
    if (_headers[strategyPublicId] case final header?) return Found(header);
    return switch (await _store._strategy(strategyPublicId)) {
      Found(:final value) => Found(value.strategy),
      NotFound() => const NotFound(),
      Unreadable(:final row) => Unreadable(row),
      NotRead(:final failure) => NotRead(failure),
    };
  }

  void _putSummary(StrategySummary summary) {
    _summaries[summary.publicId] = summary;
    _putSummaries[summary.publicId] = summary;
    _removedStrategies.remove(summary.publicId);
    _keys.put(
      libraryArea,
      summaryKey(summary.publicId),
      canonicalJson(summary.toJson()),
    );
  }

  LibraryEdited take() {
    for (final id in _removedStrategies) {
      _store._summaries.remove(id);
      _store._strategies.remove(id);
      _store._unreadableStrategies.remove(id);
    }
    for (final MapEntry(:key, :value) in _putSummaries.entries) {
      _store._summaries[key] = value;
    }
    for (final MapEntry(:key, :value) in _headers.entries) {
      _store._strategies[key]?.strategy = value;
    }
    for (final id in _removedFolders) {
      _store._folders.remove(id);
    }
    _store._folders.addAll(_putFolders);
    return LibraryEdited(
      summaries: _putSummaries.values.toList(),
      removedStrategies: _removedStrategies.toList(),
      folders: _putFolders.values.toList(),
      removedFolders: _removedFolders.toList(),
    );
  }
}
