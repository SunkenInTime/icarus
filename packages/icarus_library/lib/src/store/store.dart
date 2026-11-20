import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';

import '../apply.dart';
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
  StoreOpened(this.store, List<ForeignKey> foreignKeys)
    : foreignKeys = List.unmodifiable(foreignKeys);

  final LibraryStore store;
  final List<ForeignKey> foreignKeys;
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

final _random = Random.secure();

String _newAttempt() => [
  for (var i = 0; i < 16; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

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

  @override
  LeaseStatus get status => _inner.status;

  @override
  Future<KeyRead> read(String area, String key) async {
    final result = await _inner.read(area, key);
    if (result case KeyNotRead(failure: LeaseEnded())) _ended();
    return result;
  }

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      _watch(_inner.keys(area, prefix));

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _watch(_inner.entries(area, prefix));

  Future<Writing> _watchWriting(Future<Writing> writing) async {
    final result = await writing;
    if (result
        case DidNotWrite(failure: LeaseEnded()) ||
            MayHaveWritten(failure: LeaseEnded())) {
      _ended();
    }
    return result;
  }

  @override
  Future<Writing> write(String area, Map<String, String> values) =>
      _watchWriting(_inner.write(area, values));

  @override
  Future<Writing> delete(String area, Iterable<String> keys) =>
      _watchWriting(_inner.delete(area, keys));

  @override
  Future<Releasing> release() => _inner.release();
}

sealed class _FolderPlace {
  const _FolderPlace();
}

final class _Filed extends _FolderPlace {
  const _Filed(this.chain);

  final List<String> chain;
}

final class _Looped extends _FolderPlace {
  const _Looped(this.loop);

  final List<String> loop;
}

final class _UnderMissing extends _FolderPlace {
  const _UnderMissing(this.folderPublicId);

  final String folderPublicId;
}

final class _UnderUnreadable extends _FolderPlace {
  const _UnderUnreadable(this.folder);

  final UnreadableFolder folder;
}

_FolderPlace _placeOf(String folderPublicId, Map<String, FolderRow> folders) {
  final chain = <String>[];
  final seen = <String>{};
  String? at = folderPublicId;
  while (at != null) {
    if (!seen.add(at)) {
      return _Looped(chain.sublist(chain.indexOf(at)));
    }
    chain.add(at);
    switch (folders[at]) {
      case null:
        return _UnderMissing(at);
      case final UnreadableFolder folder:
        return _UnderUnreadable(folder);
      case ReadableFolder(:final parentFolderPublicId):
        at = parentFolderPublicId;
    }
  }
  return _Filed(chain);
}

LibraryEditResult? _folderRefusal(
  String folderPublicId,
  Map<String, FolderRow> folders,
) => switch (_placeOf(folderPublicId, folders)) {
  _Filed() => null,
  _Looped(:final loop) => Refused(FolderLoop(loop)),
  _UnderMissing(:final folderPublicId) => Refused(NoSuchFolder(folderPublicId)),
  _UnderUnreadable(:final folder) => Refused(UnreadableRowInTheWay(folder)),
};

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
    final foreign = <ForeignKey>[];
    final List<StoredEntry> journal;
    switch (await store._lease.entries(journalArea, '')) {
      case StorageFailed(:final failure):
        return StoreNotOpened(OpenStorageFailed(failure));
      case Done(:final value):
        journal = value;
    }
    final markers = <(String, String)>[];
    for (final (:key, :value) in journal) {
      switch (readJournalKey(key)) {
        case RecordAt():
          switch (store._admitRecord(value)) {
            case CouldNotRead(:final problem):
              return StoreNotOpened(SavedEditUnreadable(value, problem));
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
        case RecoveredAt():
          markers.add((key, value));
        case final ForeignKey key:
          foreign.add(key);
      }
    }
    if (await store._prune(markers) case final failure?) {
      return StoreNotOpened(OpenStorageFailed(failure));
    }
    if (await store._readLibrary(foreign) case final failure?) {
      return StoreNotOpened(OpenStorageFailed(failure));
    }
    return StoreOpened(store, foreign);
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

  LibraryState get library => switch ((_state, _lease.status)) {
    (_Closed(), _) => const LibraryShut(StoreClosed()),
    (_, Ended()) => const LibraryShut(LeaseEnded()),
    (_Stopped(:final cause), _) => LibraryShut(StoreStopped(cause)),
    (_Ready() || _Finishing(), Holding()) => LibraryOpen(
      LibraryList(
        strategies: _summaries.values.toList(),
        unreadableStrategies: _unreadableStrategies.values.toList(),
        folders: _folders.values.toList(),
      ),
    ),
  };

  void _leaseEnded() {
    if (_state is! _Closed) _state = const _Stopped(LeaseEnded());
  }

  Future<Releasing> close() => _inTurn(() async {
    if (_state is _Closed) return const Released();
    _state = const _Closed();
    final released = await _lease.release();
    unawaited(_changes.close());
    return released;
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

  Decoded<JournalRecord> _admitRecord(String text) {
    switch (JournalRecord.decode(admit(text))) {
      case final CouldNotRead<JournalRecord> unread:
        return unread;
      case Read(value: final record):
        for (final write in record.writes) {
          if (write.area.length > maxAreaLength ||
              write.key.length > _lease.maxKeyLength) {
            return CouldNotRead(
              text,
              'it writes ${write.area} ${write.key}, longer than this '
              'device holds',
            );
          }
        }
        return Read(record);
    }
  }

  Future<StorageFailure?> _prune(List<(String, String)> markers) async {
    final oldest = _clock().subtract(recoveryAnswerLifetime);
    final expired = [
      for (final (key, value) in markers)
        if (int.tryParse(value) case final millis?
            when millis < oldest.millisecondsSinceEpoch)
          key,
    ];
    if (expired.isEmpty) return null;
    return switch (asStored(await _lease.delete(journalArea, expired))) {
      StorageFailed(:final failure) => failure,
      Done() => null,
    };
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
    if (_lease.status is Ended) _leaseEnded();
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

  IdNotStorable? _unstorable(Iterable<(String, Row)> rows) {
    for (final (area, row) in rows) {
      for (final id in rowIds(row)) {
        if (encodeId(id) case NotStorable(:final problem)) {
          return IdNotStorable(id, problem);
        }
      }
      final key = rowKey(row);
      if (key.length > _lease.maxKeyLength || area.length > maxAreaLength) {
        return IdNotStorable(
          rowIds(row).last,
          KeyLongerThan(_lease.maxKeyLength),
        );
      }
    }
    return null;
  }

  static List<String> _idsNamedBy(StrategyOp op) => switch (op) {
    StrategyPatchOp() => const [],
    PageAddOp(:final pagePublicId) ||
    PagePatchOp(:final pagePublicId) ||
    PageDeleteOp(:final pagePublicId) ||
    PageReorderOp(:final pagePublicId) ||
    PageSettingsPatchOp(:final pagePublicId) => [pagePublicId],
    ElementAddOp(:final elementPublicId, :final pagePublicId) ||
    ElementDeleteOp(:final elementPublicId, :final pagePublicId) ||
    ElementReorderOp(
      :final elementPublicId,
      :final pagePublicId,
    ) => [elementPublicId, pagePublicId],
    ElementPatchOp(:final elementPublicId, :final pagePublicId) => [
      elementPublicId,
      ?pagePublicId,
    ],
    LineupGroupAddOp(:final lineupPublicId, :final pagePublicId) ||
    LineupGroupDeleteOp(:final lineupPublicId, :final pagePublicId) ||
    LineupGroupReorderOp(
      :final lineupPublicId,
      :final pagePublicId,
    ) => [lineupPublicId, pagePublicId],
    LineupGroupPatchOp(:final lineupPublicId, :final pagePublicId) => [
      lineupPublicId,
      ?pagePublicId,
    ],
  };

  IdNotStorable? _unstorableSummary(String strategyPublicId) =>
      switch (encodeId(strategyPublicId)) {
        NotStorable(:final problem) => IdNotStorable(strategyPublicId, problem),
        Storable()
            when summaryKey(strategyPublicId).length > _lease.maxKeyLength =>
          IdNotStorable(strategyPublicId, KeyLongerThan(_lease.maxKeyLength)),
        Storable() => null,
      };

  Future<Saving<S, R>> _save<S, R>(
    Map<String, Object?> edit,
    List<KeyWrite> writes,
    S Function() take,
  ) async {
    if (await _settle() case final failure?) return NotSaved(failure);
    final record = JournalRecord(
      attempt: _newAttempt(),
      issuedAt: _clock(),
      edit: edit,
      writes: writes,
    );
    switch (await record.save(_lease)) {
      case StorageFailed(failure: final LeaseEnded failure):
        return NotSaved(failure);
      case StorageFailed(:final failure):
        if (await JournalRecord.clear(_lease) case StorageFailed()) {
          if (_state is! _Closed) _state = _Stopped(failure);
          return SaveInDoubt(
            failure,
            SaveReceipt(record.attempt, record.issuedAt),
          );
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

  Future<StorageFailure?> _readLibrary(List<ForeignKey> foreign) async {
    final List<StoredEntry> entries;
    switch (await _lease.entries(libraryArea, '')) {
      case StorageFailed(:final failure):
        return failure;
      case Done(:final value):
        entries = value;
    }
    final toRebuild = <String>[];
    for (final (:key, :value) in entries) {
      switch (readLibraryKey(key)) {
        case SummaryAt(:final strategyPublicId):
          switch (admit(value)) {
            case Admitted(:final json):
              switch (StrategySummary.decode(json)) {
                case Read(value: final summary)
                    when summary.publicId == strategyPublicId:
                  _summaries[strategyPublicId] = summary;
                case Read() || CouldNotRead():
                  toRebuild.add(strategyPublicId);
              }
            case NotAdmitted():
              toRebuild.add(strategyPublicId);
          }
        case FolderAt(:final folderPublicId):
          _folders[folderPublicId] = FolderRow.parse(
            admit(value),
            publicId: folderPublicId,
          );
        case final ForeignKey key:
          foreign.add(key);
      }
    }
    for (final id in toRebuild) {
      switch (await _rebuild(id)) {
        case Saved() || NothingToSave():
          break;
        case NotSaved(:final failure) || SaveInDoubt(:final failure):
          return failure;
        case Refused(
          reason: UnreadableRowInTheWay(row: final UnreadableStrategy row),
        ):
          _unreadableStrategies[id] = row;
        case Refused():
          break;
      }
    }
    return null;
  }

  Future<Reading<LoadedStrategy>> _strategy(String strategyPublicId) async {
    if (_strategies[strategyPublicId] case final loaded?) return Found(loaded);
    final area = strategyArea(strategyPublicId);
    final StrategyRow header;
    switch (await _lease.read(area, headerKey)) {
      case KeyNotRead(:final failure):
        return NotRead(failure);
      case KeyMissing():
        return const NotFound();
      case KeyHeld(:final value):
        header = StrategyRow.parse(admit(value), publicId: strategyPublicId);
    }
    final List<StrategyAreaKey> keys;
    switch (await _lease.keys(area, '')) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        keys = [for (final key in value) readStrategyKey(area, key)];
    }
    final pages = <PageRow>[];
    switch (await _lease.entries(area, pagePrefix)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          if (readStrategyKey(area, key) case PageAt(:final pagePublicId)) {
            pages.add(
              PageRow.parse(
                admit(value),
                publicId: pagePublicId,
                strategyPublicId: strategyPublicId,
              ),
            );
          }
        }
    }
    final settings = <PageSettingsRow>[];
    switch (await _lease.entries(area, settingsPrefix)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          if (readStrategyKey(area, key) case SettingsAt(:final pagePublicId)) {
            settings.add(
              PageSettingsRow.parse(admit(value), pagePublicId: pagePublicId),
            );
          }
        }
    }
    final loaded = LoadedStrategy(
      header: header,
      pages: pages,
      settings: settings,
      keys: keys,
    );
    _strategies[strategyPublicId] = loaded;
    return Found(loaded);
  }

  Future<StorageFailure?> _loadPages(
    String strategyPublicId,
    LoadedStrategy strategy,
    Iterable<String> pageIds,
  ) async {
    for (final pageId in pageIds) {
      if (strategy.isLoaded(pageId)) continue;
      if (await _loadPage(strategyPublicId, strategy, pageId)
          case final failure?) {
        return failure;
      }
    }
    return null;
  }

  Future<StorageFailure?> _loadPage(
    String strategyPublicId,
    LoadedStrategy strategy,
    String pagePublicId,
  ) async {
    final page = LoadedPage();
    if (encodeId(pagePublicId) is NotStorable) {
      strategy.addLoadedPage(pagePublicId, page);
      return null;
    }
    final area = strategyArea(strategyPublicId);
    switch (await _lease.entries(area, pageContentPrefix(pagePublicId))) {
      case StorageFailed(:final failure):
        return failure;
      case Done(:final value):
        for (final (:key, :value) in value) {
          switch (readStrategyKey(area, key)) {
            case ElementAt(:final publicId):
              page.elements[publicId] = ElementRow.parse(
                admit(value),
                publicId: publicId,
                pagePublicId: pagePublicId,
                canRead: _canRead,
              );
            case LineupAt(:final publicId):
              page.lineupGroups[publicId] = LineupGroupRow.parse(
                admit(value),
                publicId: publicId,
                strategyPublicId: strategyPublicId,
                pagePublicId: pagePublicId,
              );
            case UnknownKindAt(:final key):
              page.unknownKinds.add(UnknownKindRow(key: key, text: value));
            case final ForeignKey key:
              page.foreignKeys.add(key);
            case HeaderAt() || PageAt() || SettingsAt():
              break;
          }
        }
    }
    strategy.addLoadedPage(pagePublicId, page);
    return null;
  }

  Future<Reading<StrategyContent>> readStrategy(String strategyPublicId) =>
      _inTurn(() async {
        if (await _settle() case final failure?) return NotRead(failure);
        return switch (await _strategy(strategyPublicId)) {
          Found(value: final strategy) => Found(
            StrategyContent(
              strategy: strategy.header,
              pages: _ordered(strategy.pages),
              settings: {...strategy.settings},
              foreignKeys: strategy.foreignKeys,
            ),
          ),
          NotFound() => const NotFound(),
          NotRead(:final failure) => NotRead(failure),
        };
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
      case NotRead(:final failure):
        return NotRead(failure);
    }
    final page = strategy.page(pagePublicId);
    if (page == null) return const NotFound();
    if (await _loadPages(strategyPublicId, strategy, [pagePublicId])
        case final failure?) {
      return NotRead(failure);
    }
    final loaded = strategy.loadedPage(pagePublicId)!;
    return Found(
      PageContent(
        page: page,
        settings: strategy.settingsOf(pagePublicId),
        elements: loaded.elements.values.toList(),
        lineupGroups: loaded.lineupGroups.values.toList(),
        unknownKinds: loaded.unknownKinds,
        foreignKeys: loaded.foreignKeys,
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
    if (readJournalKey(recoveredKey(receipt.attempt)) is! RecoveredAt) {
      return const EditNotRecovered();
    }
    return switch (await _lease.read(
      journalArea,
      recoveredKey(receipt.attempt),
    )) {
      KeyNotRead(:final failure) => RecoveryNotRead(failure),
      KeyHeld() => const EditRecovered(),
      KeyMissing()
          when _clock().difference(receipt.issuedAt) > recoveryAnswerLifetime =>
        const RecoveryForgotten(),
      KeyMissing() => const EditNotRecovered(),
    };
  });

  static List<PageRow> _ordered(Iterable<PageRow> pages) => pages.sorted(
    (a, b) => switch ((_sortOf(a), _sortOf(b))) {
      (final x, final y) when x != y => x.compareTo(y),
      _ => a.publicId.compareTo(b.publicId),
    },
  );

  static int _sortOf(PageRow page) => switch (page) {
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
          pagePublicId,
        ],
        PageAddOp(:final pagePublicId) => {...strategy.pageIds, pagePublicId},
        ElementAddOp(:final pagePublicId, :final elementPublicId) => [
          pagePublicId,
          ?strategy.pageOfElement(elementPublicId),
        ],
        ElementPatchOp(:final pagePublicId, :final elementPublicId) => [
          ?pagePublicId,
          ?strategy.pageOfElement(elementPublicId),
        ],
        ElementDeleteOp(:final elementPublicId) ||
        ElementReorderOp(
          :final elementPublicId,
        ) => [?strategy.pageOfElement(elementPublicId)],
        LineupGroupAddOp(:final pagePublicId, :final lineupPublicId) => [
          pagePublicId,
          ?strategy.pageOfLineupGroup(lineupPublicId),
        ],
        LineupGroupPatchOp(:final pagePublicId, :final lineupPublicId) => [
          ?pagePublicId,
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

  Future<CommitResult> commit(
    String strategyPublicId,
    StrategyOp op,
  ) => _inTurn(() async {
    if (await _settle() case final failure?) return NotSaved(failure);
    for (final id in _idsNamedBy(op)) {
      if (encodeId(id) case NotStorable(:final problem)) {
        return Refused(IdNotStorable(id, problem));
      }
    }
    final LoadedStrategy strategy;
    switch (await _strategy(strategyPublicId)) {
      case Found(:final value):
        strategy = value;
      case NotFound():
        return Refused(NoSuchStrategy(strategyPublicId));
      case NotRead(:final failure):
        return NotSaved(failure);
    }
    final ReadableStrategy header;
    switch (strategy.header) {
      case final UnreadableStrategy row:
        return Refused(UnreadableRowInTheWay(row));
      case final ReadableStrategy row:
        header = row;
    }
    final summary = _summaries[strategyPublicId];
    if (summary == null) return Refused(NoSuchStrategy(strategyPublicId));
    if (await _loadPages(strategyPublicId, strategy, _pagesFor(op, strategy))
        case final failure?) {
      return NotSaved(failure);
    }
    if (op case PageAddOp(copyContentFromPagePublicId: final source?)) {
      if (strategy.loadedPage(source) case final page?
          when page.unknownKinds.isNotEmpty || page.foreignKeys.isNotEmpty) {
        return Refused(CopyLeavesRowsBehind(source));
      }
    }
    final OpApplied applied;
    switch (applyOp(strategy.rowsUnder(header), op)) {
      case OpUnchanged():
        return const NothingToSave();
      case OpRefused(:final refusal):
        return Refused(OpRefusal(refusal));
      case final OpApplied result:
        applied = result;
    }
    final writes = _stamped(header, applied.writes, _clock());
    final area = strategyArea(strategyPublicId);
    if (_unstorable([for (final write in writes) (area, write.after)])
        case final refusal?) {
      return Refused(refusal);
    }
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
    final (after, pages) = strategy.headerAfter(header, writes);
    final summaryAfter = summary.after(after, pages, writes);
    keys.put(
      libraryArea,
      summaryKey(strategyPublicId),
      canonicalJson(summaryAfter.toJson()),
    );
    final CommitResult result = await _save(
      {'strategyPublicId': strategyPublicId, 'op': op.toJson()},
      keys.writes,
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

  Future<RebuildResult> _rebuild(String strategyPublicId) async {
    if (await _settle() case final failure?) return NotSaved(failure);
    final LoadedStrategy strategy;
    switch (await _strategy(strategyPublicId)) {
      case Found(:final value):
        strategy = value;
      case NotFound():
        return Refused(NoSuchStrategy(strategyPublicId));
      case NotRead(:final failure):
        return NotSaved(failure);
    }
    final ReadableStrategy header;
    switch (strategy.header) {
      case final UnreadableStrategy row:
        return Refused(UnreadableRowInTheWay(row));
      case final ReadableStrategy row:
        header = row;
    }
    if (await _loadPages(strategyPublicId, strategy, strategy.pageIds)
        case final failure?) {
      return NotSaved(failure);
    }
    final rebuilt = _summaryOf(header, strategy);
    if (rebuilt == _summaries[strategyPublicId]) return const NothingToSave();
    final keys = KeyWrites()
      ..put(
        libraryArea,
        summaryKey(strategyPublicId),
        canonicalJson(rebuilt.toJson()),
      );
    return _save({'rebuildSummary': strategyPublicId}, keys.writes, () {
      _summaries[strategyPublicId] = rebuilt;
      _unreadableStrategies.remove(strategyPublicId);
      return rebuilt;
    });
  }

  StrategySummary _summaryOf(ReadableStrategy header, LoadedStrategy strategy) {
    final tallies = <String, PageTally>{};
    for (final pageId in strategy.pageIds) {
      for (final row in strategy.elementsOn(pageId)) {
        tallies[row.pagePublicId] =
            (tallies[row.pagePublicId] ?? PageTally.empty).plus(row, 1);
      }
    }
    return StrategySummary.of(
      strategy: header,
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
          {'library': edit.described},
          edit.writes,
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
        if (_store._unstorableSummary(id) case final refusal?) {
          return Refused(refusal);
        }
        if (_hasStrategy(id) || _removedStrategies.contains(id)) {
          return Refused(StrategyAlreadyInStore(id));
        }
        if (_outside(rows) case final key?) {
          return Refused(RowOutsideStrategy(key));
        }
        final area = strategyArea(id);
        if (_store._unstorable([for (final row in rows.rows) (area, row)])
            case final refusal?) {
          return Refused(refusal);
        }
        if (rows.strategy.folderPublicId case final folder?) {
          if (_folderRefusal(folder, _folders) case final refused?) {
            return refused;
          }
        }
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
        if (folderPublicId != null) {
          if (_folderRefusal(folderPublicId, _folders) case final refused?) {
            return refused;
          }
        }
        final ReadableStrategy current;
        switch (await _header(strategyPublicId)) {
          case Found(value: final ReadableStrategy value):
            current = value;
          case Found(value: final UnreadableStrategy row):
            return Refused(UnreadableRowInTheWay(row));
          case NotFound():
            return Refused(NoSuchStrategy(strategyPublicId));
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
        if (_store._unstorable([(libraryArea, folder)]) case final refusal?) {
          return Refused(refusal);
        }
        if (_folders[id] case final UnreadableFolder row) {
          return Refused(UnreadableRowInTheWay(row));
        }
        if (folder.parentFolderPublicId case final parent?) {
          switch (_placeOf(parent, _folders)) {
            case _Filed(:final chain) when chain.contains(id):
              return Refused(FolderInsideItself(id));
            case _Filed():
              break;
            case _Looped(:final loop):
              return Refused(FolderLoop(loop));
            case _UnderMissing(:final folderPublicId):
              return Refused(NoSuchFolder(folderPublicId));
            case _UnderUnreadable(:final folder):
              return Refused(UnreadableRowInTheWay(folder));
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

  Future<Reading<StrategyRow>> _header(String strategyPublicId) async {
    if (_headers[strategyPublicId] case final header?) return Found(header);
    return switch (await _store._strategy(strategyPublicId)) {
      Found(:final value) => Found(value.header),
      NotFound() => const NotFound(),
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
      _store._strategies[key]?.header = value;
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
