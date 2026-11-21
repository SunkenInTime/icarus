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
import 'layout.dart';
import 'loaded_strategy.dart';
import 'results.dart';
import 'summary.dart';

typedef CanRead = bool Function(ElementPayload payload);

sealed class StoreOpening {
  const StoreOpening();
}

final class StoreOpened extends StoreOpening {
  StoreOpened(this.store, this.lastSave, List<ForeignName> foreignNames)
    : foreignNames = List.unmodifiable(foreignNames);

  final LibraryStore store;
  final LastSave lastSave;
  final List<ForeignName> foreignNames;
}

final class StoreNotOpened extends StoreOpening {
  const StoreNotOpened(this.problem, this.lastSave);

  final OpenProblem problem;
  final LastSave lastSave;
}

sealed class _State {
  const _State();
}

final class _Ready extends _State {
  const _Ready();
}

final class _Stopped extends _State {
  const _Stopped(this.cause);

  final StorageFailure cause;
}

final class _Closed extends _State {
  const _Closed();
}

DateTime _now() => DateTime.now().toUtc();

String _stored(Object? json) => canonicalJson(json);

final _random = Random();

String _newAttempt() => [
  for (var i = 0; i < 16; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

final _attempt = RegExp(r'^[0-9a-f]{32}$');

RowSpot _spot(StoreName name, String digest) =>
    RowSpot(name: name.name, names: (id) => namesId(digest, id));

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
    if (!seen.add(at)) return _Looped(chain.sublist(chain.indexOf(at)));
    chain.add(at);
    switch (folders[digestOf(at)]) {
      case final ReadableFolder folder when folder.publicId == at:
        at = folder.parentFolderPublicId;
      case final UnreadableFolder folder:
        return _UnderUnreadable(folder);
      case ReadableFolder() || null:
        return _UnderMissing(at);
    }
  }
  return _Filed(chain);
}

final class _WatchedLease {
  _WatchedLease(this._inner, this._ended);

  final StorageLease _inner;
  final void Function() _ended;

  int get maxKeyLength => _inner.maxKeyLength;

  LeaseStatus get status => _inner.status;

  Future<KeyRead> read(String area, String key) async {
    final result = await _inner.read(area, key);
    if (result case KeyNotRead(failure: LeaseEnded())) _ended();
    return result;
  }

  Future<Stored<T>> _watch<T>(Future<Stored<T>> stored) async {
    final result = await stored;
    if (result case StorageFailed(failure: LeaseEnded())) _ended();
    return result;
  }

  Future<Stored<List<String>>> keys(String area, String prefix) =>
      _watch(_inner.keys(area, prefix));

  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _watch(_inner.entries(area, prefix));

  Future<Committing> commit(List<Change> changes) async {
    final result = await _inner.commit(changes);
    if (result
        case CommitRefused(failure: LeaseEnded()) ||
            CommitUnknown(failure: LeaseEnded())) {
      _ended();
    }
    return result;
  }

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
        return const StoreNotOpened(StoreAlreadyOpen(), LastSaveNotRead());
      case LeaseFailed(:final failure):
        return StoreNotOpened(
          OpenStorageFailed(failure),
          const LastSaveNotRead(),
        );
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
    if (lease.maxKeyLength < longestName) {
      return StoreNotOpened(
        EngineTooSmall(lease.maxKeyLength),
        const LastSaveNotRead(),
      );
    }
    final store = LibraryStore._(lease, canRead, clock);
    final LastSave lastSave;
    switch (await store._lease.read(libraryArea, lastSaveKey)) {
      case KeyNotRead(:final failure):
        return StoreNotOpened(
          OpenStorageFailed(failure),
          const LastSaveNotRead(),
        );
      case KeyMissing():
        lastSave = const NoSaveRecorded();
      case KeyHeld(:final value) when _attempt.hasMatch(value):
        lastSave = LastSaveWas(value);
      case KeyHeld(:final value):
        lastSave = LastSaveUnreadable(value);
    }
    final foreign = <ForeignName>[];
    if (await store._readLibrary(foreign) case StorageFailed(:final failure)) {
      return StoreNotOpened(OpenStorageFailed(failure), lastSave);
    }
    return StoreOpened(store, lastSave, foreign);
  }

  late final _WatchedLease _lease;
  final CanRead _canRead;
  final DateTime Function() _clock;
  _State _state = const _Ready();
  Future<void> _tail = Future.value();
  Future<Releasing>? _closing;
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
    (_Ready(), Holding()) => LibraryOpen(
      LibraryList(
        strategies: _summaries.values.toList(),
        unreadableStrategies: _unreadableStrategies.values.toList(),
        folders: _folders.values.toList(),
      ),
    ),
  };

  void _leaseEnded() {
    if (_state is! _Closed) _state = const _Stopped(LeaseEnded());
    if (!_changes.isClosed) unawaited(_changes.close());
  }

  void _emit(StoreChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  Future<Releasing> close() => _closing ??= _inTurn(() async {
    _state = const _Closed();
    final released = await _lease.release();
    if (!_changes.isClosed) unawaited(_changes.close());
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

  Stored<void> _settle() {
    if (_lease.status is Ended) _leaseEnded();
    return switch (_state) {
      _Ready() => done,
      _Stopped(:final cause) => StorageFailed(StoreStopped(cause)),
      _Closed() => const StorageFailed(StoreClosed()),
    };
  }

  Row _readBack(Row row, String text) {
    final stored = admit(text);
    RowSpot spot(String id) =>
        RowSpot(name: nameOf(row).name, names: (other) => other == id);
    return switch (row) {
      StrategyRow(:final publicId) => StrategyRow.parse(
        stored,
        spot: spot(publicId),
      ),
      FolderRow(:final publicId) => FolderRow.parse(
        stored,
        spot: spot(publicId),
      ),
      PageRow(:final publicId, :final strategyPublicId) => PageRow.parse(
        stored,
        spot: spot(publicId),
        strategy: RowSpot(
          name: strategyPublicId,
          names: (id) => id == strategyPublicId,
        ),
      ),
      PageSettingsRow(:final pagePublicId) => PageSettingsRow.parse(
        stored,
        spot: spot(pagePublicId),
      ),
      ElementRow(:final publicId, :final pagePublicId) => ElementRow.parse(
        stored,
        spot: spot(publicId),
        page: RowSpot(name: pagePublicId, names: (id) => id == pagePublicId),
        canRead: _canRead,
      ),
      LineupGroupRow(
        :final publicId,
        :final pagePublicId,
        :final strategyPublicId,
      ) =>
        LineupGroupRow.parse(
          stored,
          spot: spot(publicId),
          page: RowSpot(name: pagePublicId, names: (id) => id == pagePublicId),
          strategy: RowSpot(
            name: strategyPublicId,
            names: (id) => id == strategyPublicId,
          ),
        ),
    };
  }

  Stored<void> _readsBack(String area, Row row, String text) =>
      switch (_readBack(row, text)) {
        final back when back == row => done,
        final back => StorageFailed(
          WouldNotReadBack(area, nameOf(row).name, 'reads back as $back'),
        ),
      };

  Future<Saving<S, R>> _save<S, R>(
    List<Change> changes,
    S Function() take,
  ) async {
    if (_settle() case StorageFailed(:final failure)) return NotSaved(failure);
    final attempt = _newAttempt();
    switch (await _lease.commit([
      ...changes,
      Put(libraryArea, lastSaveKey, attempt),
    ])) {
      case CommitApplied():
        return Saved(take());
      case CommitRefused(:final failure):
        return NotSaved(failure);
      case CommitUnknown(:final failure):
        if (_state is _Ready) _state = _Stopped(failure);
        return SaveInDoubt(failure, attempt);
    }
  }

  Future<Stored<void>> _readLibrary(List<ForeignName> foreign) async {
    final List<StoredEntry> entries;
    switch (await _lease.entries(libraryArea, '')) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(:final value):
        entries = value;
    }
    final toRebuild = <String>[];
    for (final (:key, :value) in entries) {
      switch (readName(const LibraryArea(), key)) {
        case SummaryName(:final digest):
          switch (admit(value)) {
            case Admitted(:final json):
              switch (StrategySummary.decode(json)) {
                case Read(value: final summary)
                    when namesId(digest, summary.publicId):
                  _summaries[digest] = summary;
                case Read() || CouldNotRead():
                  toRebuild.add(digest);
              }
            case NotAdmitted():
              toRebuild.add(digest);
          }
        case final FolderName name:
          _folders[name.digest] = FolderRow.parse(
            admit(value),
            spot: _spot(name, name.digest),
          );
        case LastSaveName():
          break;
        case final ForeignName name:
          foreign.add(name);
        case _:
          break;
      }
    }
    for (final digest in toRebuild) {
      switch (await _rebuild(digest)) {
        case Saved() || NothingToSave():
          break;
        case NotSaved(:final failure) || SaveInDoubt(:final failure):
          return StorageFailed(failure);
        case Refused(
          reason: UnreadableRowInTheWay(row: final UnreadableStrategy row),
        ):
          _unreadableStrategies[digest] = row;
        case Refused():
          break;
      }
    }
    return done;
  }

  Future<Reading<LoadedStrategy>> _strategyAt(String digest) async {
    if (_strategies[digest] case final loaded?) return Found(loaded);
    final area = StrategyArea(digest).name;
    final StrategyRow header;
    switch (await _lease.read(area, const HeaderName().name)) {
      case KeyNotRead(:final failure):
        return NotRead(failure);
      case KeyMissing():
        return const NotFound();
      case KeyHeld(:final value):
        header = StrategyRow.parse(
          admit(value),
          spot: RowSpot(name: area, names: (id) => namesId(digest, id)),
        );
    }
    final List<StoreName> names;
    switch (await _lease.keys(area, '')) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        names = [for (final key in value) readName(StrategyArea(digest), key)];
    }
    final pages = <String, PageRow>{};
    switch (await _lease.entries(area, 'page/')) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          if (readName(StrategyArea(digest), key) case final PageName name) {
            pages[name.digest] = PageRow.parse(
              admit(value),
              spot: _spot(name, name.digest),
              strategy: RowSpot(
                name: header.publicId,
                names: (id) => namesId(digest, id),
              ),
            );
          }
        }
    }
    final settings = <String, PageSettingsRow>{};
    switch (await _lease.entries(area, 'settings/')) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          if (readName(StrategyArea(digest), key)
              case final SettingsName name) {
            settings[name.digest] = PageSettingsRow.parse(
              admit(value),
              spot: _spot(name, name.digest),
            );
          }
        }
    }
    final loaded = LoadedStrategy(
      header: header,
      pages: pages,
      settings: settings,
      names: names,
    );
    _strategies[digest] = loaded;
    return Found(loaded);
  }

  Future<Reading<LoadedStrategy>> _strategy(String strategyPublicId) async =>
      switch (await _strategyAt(digestOf(strategyPublicId))) {
        Found(value: final loaded)
            when loaded.header is ReadableStrategy &&
                loaded.header.publicId != strategyPublicId =>
          const NotFound(),
        final reading => reading,
      };

  Future<Stored<void>> _loadPages(
    String digest,
    LoadedStrategy strategy,
    Iterable<String> pageDigests,
  ) async {
    for (final page in pageDigests) {
      if (strategy.isLoaded(page)) continue;
      if (await _loadPage(digest, strategy, page) case StorageFailed(
        :final failure,
      )) {
        return StorageFailed(failure);
      }
    }
    return done;
  }

  Future<Stored<void>> _loadPage(
    String digest,
    LoadedStrategy strategy,
    String pageDigest,
  ) async {
    final area = StrategyArea(digest);
    final page = LoadedPage();
    final pageSpot = RowSpot(
      name: strategy.pageIdOf(pageDigest),
      names: (id) => namesId(pageDigest, id),
    );
    switch (await _lease.entries(area.name, pageContentPrefix(pageDigest))) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          switch (readName(area, key)) {
            case final ElementName name:
              page.elements[name.digest] = ElementRow.parse(
                admit(value),
                spot: _spot(name, name.digest),
                page: pageSpot,
                canRead: _canRead,
              );
            case final LineupName name:
              page.lineupGroups[name.digest] = LineupGroupRow.parse(
                admit(value),
                spot: _spot(name, name.digest),
                page: pageSpot,
                strategy: RowSpot(
                  name: strategy.header.publicId,
                  names: (id) => namesId(digest, id),
                ),
              );
            case UnknownKindName(:final name):
              page.unknownKinds.add(UnknownKindRow(key: name, text: value));
            case final ForeignName name:
              page.foreignNames.add(name);
            case _:
              break;
          }
        }
    }
    strategy.addLoadedPage(pageDigest, page);
    return done;
  }

  Future<Reading<StrategyContent>> readStrategy(String strategyPublicId) =>
      _inTurn(() async {
        if (_settle() case StorageFailed(:final failure)) {
          return NotRead(failure);
        }
        return switch (await _strategy(strategyPublicId)) {
          Found(value: final strategy) => Found(
            StrategyContent(
              strategy: strategy.header,
              pages: _ordered(strategy.pages),
              settings: strategy.settingsByPage,
              foreignNames: strategy.foreignNames,
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
    if (_settle() case StorageFailed(:final failure)) return NotRead(failure);
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
    final pageDigest = digestOf(pagePublicId);
    if (await _loadPages(digestOf(strategyPublicId), strategy, [pageDigest])
        case StorageFailed(:final failure)) {
      return NotRead(failure);
    }
    final loaded = strategy.loadedPage(pageDigest)!;
    return Found(
      PageContent(
        page: page,
        settings: strategy.settingsOf(pagePublicId),
        elements: loaded.elements.values.toList(),
        lineupGroups: loaded.lineupGroups.values.toList(),
        unknownKinds: loaded.unknownKinds,
        foreignNames: loaded.foreignNames,
      ),
    );
  });

  Future<Unloading> unload(String strategyPublicId) => _inTurn(() async {
    if (_settle() case StorageFailed(:final failure)) {
      return NotUnloaded(failure);
    }
    _strategies.remove(digestOf(strategyPublicId));
    return const Unloaded();
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
          digestOf(pagePublicId),
        ],
        PageAddOp(:final pagePublicId) => {
          ...strategy.pageDigests,
          digestOf(pagePublicId),
        },
        ElementAddOp(:final pagePublicId, :final elementPublicId) => [
          digestOf(pagePublicId),
          ?strategy.pageOfElement(elementPublicId),
        ],
        ElementPatchOp(:final pagePublicId, :final elementPublicId) => [
          if (pagePublicId != null) digestOf(pagePublicId),
          ?strategy.pageOfElement(elementPublicId),
        ],
        ElementDeleteOp(:final elementPublicId) ||
        ElementReorderOp(
          :final elementPublicId,
        ) => [?strategy.pageOfElement(elementPublicId)],
        LineupGroupAddOp(:final pagePublicId, :final lineupPublicId) => [
          digestOf(pagePublicId),
          ?strategy.pageOfLineupGroup(lineupPublicId),
        ],
        LineupGroupPatchOp(:final pagePublicId, :final lineupPublicId) => [
          if (pagePublicId != null) digestOf(pagePublicId),
          ?strategy.pageOfLineupGroup(lineupPublicId),
        ],
        LineupGroupDeleteOp(:final lineupPublicId) ||
        LineupGroupReorderOp(
          :final lineupPublicId,
        ) => [?strategy.pageOfLineupGroup(lineupPublicId)],
      };

  static bool _holdsOtherThan(Row? current, Row written) => switch (current) {
    null => false,
    UnreadableStrategy() ||
    UnreadableFolder() ||
    UnreadablePage() ||
    UnreadablePageSettings() ||
    UnreadableElement() ||
    UnreadableLineupGroup() => true,
    final row => row.key != written.key,
  };

  static List<RowWrite> _stamped(
    ReadableStrategy header,
    List<RowWrite> writes,
    DateTime now,
  ) {
    DateTime later(DateTime current) => now.isAfter(current) ? now : current;
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
              after: after.rewritten(updatedAt: later(after.updatedAt)),
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
          after: header.rewritten(updatedAt: later(header.updatedAt)),
          fields: {RowField.updatedAt},
        ),
      );
    }
    return stamped;
  }

  Future<CommitResult> commit(String strategyPublicId, StrategyOp op) =>
      _inTurn(() async {
        if (_settle() case StorageFailed(:final failure)) {
          return NotSaved(failure);
        }
        final digest = digestOf(strategyPublicId);
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
        final summary = _summaries[digest];
        if (summary == null) return Refused(NoSuchStrategy(strategyPublicId));
        if (await _loadPages(digest, strategy, _pagesFor(op, strategy))
            case StorageFailed(:final failure)) {
          return NotSaved(failure);
        }
        if (op case PageAddOp(copyContentFromPagePublicId: final source?)) {
          if (strategy.loadedPage(digestOf(source)) case final page?
              when page.unknownKinds.isNotEmpty ||
                  page.foreignNames.isNotEmpty) {
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
        final area = StrategyArea(digest).name;
        final changes = <Change>[];
        for (final write in writes) {
          if (_holdsOtherThan(strategy.current(write.after), write.after)) {
            return Refused(OpRefusal(UnreadableTarget(write.after.key)));
          }
          final text = _stored(write.after.toJson());
          if (_readsBack(area, write.after, text) case StorageFailed(
            :final failure,
          )) {
            return NotSaved(failure);
          }
          final name = nameOf(write.after).name;
          changes.add(Put(area, name, text));
          if (write case RowChanged(
            :final before,
          ) when nameOf(before).name != name) {
            changes.add(Delete(area, nameOf(before).name));
          }
        }
        final (after, pages, settings) = strategy.after(header, writes);
        final summaryAfter = summary.after(after, pages, settings, writes);
        changes.add(
          Put(
            libraryArea,
            SummaryName(digest).name,
            _stored(summaryAfter.toJson()),
          ),
        );
        final CommitResult result = await _save(changes, () {
          strategy.take(writes);
          _summaries[digest] = summaryAfter;
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
        });
        if (result case Saved(:final value)) _emit(value.change);
        return result;
      });

  Future<RebuildResult> rebuildSummary(String strategyPublicId) =>
      _inTurn(() async {
        final result = await _rebuild(digestOf(strategyPublicId));
        if (result case Saved(:final value)) {
          _emit(
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

  Future<RebuildResult> _rebuild(String digest) async {
    if (_settle() case StorageFailed(:final failure)) return NotSaved(failure);
    final LoadedStrategy strategy;
    switch (await _strategyAt(digest)) {
      case Found(:final value):
        strategy = value;
      case NotFound():
        return Refused(NoSuchStrategy(StrategyArea(digest).name));
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
    if (await _loadPages(digest, strategy, strategy.pageDigests)
        case StorageFailed(:final failure)) {
      return NotSaved(failure);
    }
    final tallies = <String, PageTally>{};
    for (final page in strategy.pageDigests) {
      for (final row in strategy.elementsOnPage(page)) {
        tallies[row.pagePublicId] =
            (tallies[row.pagePublicId] ?? PageTally.empty).plus(row, 1);
      }
      for (final row in strategy.lineupGroupsOnPage(page)) {
        tallies[row.pagePublicId] =
            (tallies[row.pagePublicId] ?? PageTally.empty).plusGroup(row, 1);
      }
    }
    final rebuilt = StrategySummary.of(
      strategy: header,
      pages: strategy.pages,
      settings: strategy.allSettings,
      tallies: tallies,
    );
    if (rebuilt == _summaries[digest]) return const NothingToSave();
    return _save(
      [Put(libraryArea, SummaryName(digest).name, _stored(rebuilt.toJson()))],
      () {
        _summaries[digest] = rebuilt;
        _unreadableStrategies.remove(digest);
        return rebuilt;
      },
    );
  }

  Future<LibraryEditResult> editLibrary(List<LibraryChange> changes) =>
      _inTurn(() async {
        if (_settle() case StorageFailed(:final failure)) {
          return NotSaved(failure);
        }
        final edit = _LibraryEdit(this);
        for (final change in changes) {
          if (await edit.add(change) case _Stop(:final result)) return result;
        }
        if (edit.isEmpty) return const NothingToSave();
        final result = await _save<LibraryEdited, LibraryRefusal>(
          edit.changes,
          edit.take,
        );
        if (result case Saved(:final value)) _emit(value);
        return result;
      });
}

sealed class _Step {
  const _Step();
}

final class _Next extends _Step {
  const _Next();
}

final class _Stop extends _Step {
  const _Stop(this.result);

  final LibraryEditResult result;
}

final class _LibraryEdit {
  _LibraryEdit(this._store)
    : _folders = {..._store._folders},
      _summaries = {..._store._summaries};

  final LibraryStore _store;
  final Map<String, FolderRow> _folders;
  final Map<String, StrategySummary> _summaries;
  final changes = <Change>[];
  final _headers = <String, ReadableStrategy>{};
  final _putSummaries = <String, StrategySummary>{};
  final _removedStrategies = <String, String>{};
  final _putFolders = <String, ReadableFolder>{};
  final _removedFolders = <String, String>{};

  bool get isEmpty => changes.isEmpty;

  bool _hasStrategy(String id) =>
      _summaries.containsKey(digestOf(id)) ||
      _store._unreadableStrategies.containsKey(digestOf(id));

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

  _Step _put(String area, Row row) {
    final text = _stored(row.toJson());
    if (_store._readsBack(area, row, text) case StorageFailed(:final failure)) {
      return _Stop(NotSaved(failure));
    }
    changes.add(Put(area, nameOf(row).name, text));
    return const _Next();
  }

  Future<_Step> add(LibraryChange change) async {
    switch (change) {
      case AddStrategy(:final rows):
        final id = rows.strategy.publicId;
        if (_hasStrategy(id) || _removedStrategies.containsKey(digestOf(id))) {
          return _Stop(Refused(StrategyAlreadyInStore(id)));
        }
        if (_outside(rows) case final key?) {
          return _Stop(Refused(RowOutsideStrategy(key)));
        }
        if (rows.strategy.folderPublicId case final folder?) {
          switch (_placeOf(folder, _folders)) {
            case _Filed():
              break;
            case _Looped(:final loop):
              return _Stop(Refused(FolderLoop(loop)));
            case _UnderMissing(:final folderPublicId):
              return _Stop(Refused(NoSuchFolder(folderPublicId)));
            case _UnderUnreadable(:final folder):
              return _Stop(Refused(UnreadableRowInTheWay(folder)));
          }
        }
        final area = strategyArea(id);
        switch (await _store._lease.keys(area, '')) {
          case StorageFailed(:final failure):
            return _Stop(NotSaved(failure));
          case Done(value: final keys) when keys.isNotEmpty:
            return _Stop(Refused(StrategyAlreadyInStore(id)));
          case Done():
            break;
        }
        for (final row in rows.rows) {
          if (_put(area, row) case final _Stop stop) return stop;
        }
        _headers[id] = rows.strategy;
        final tallies = <String, PageTally>{};
        for (final row in rows.elements) {
          tallies[row.pagePublicId] =
              (tallies[row.pagePublicId] ?? PageTally.empty).plus(row, 1);
        }
        for (final row in rows.lineupGroups) {
          tallies[row.pagePublicId] =
              (tallies[row.pagePublicId] ?? PageTally.empty).plusGroup(row, 1);
        }
        _putSummary(
          StrategySummary.of(
            strategy: rows.strategy,
            pages: rows.pages,
            settings: rows.settings,
            tallies: tallies,
          ),
        );
      case RemoveStrategy(:final strategyPublicId):
        if (!_hasStrategy(strategyPublicId)) {
          return _Stop(Refused(NoSuchStrategy(strategyPublicId)));
        }
        final digest = digestOf(strategyPublicId);
        changes
          ..add(ClearArea(strategyArea(strategyPublicId)))
          ..add(Delete(libraryArea, SummaryName(digest).name));
        _headers.remove(strategyPublicId);
        _summaries.remove(digest);
        _putSummaries.remove(digest);
        _removedStrategies[digest] = strategyPublicId;
      case MoveStrategy(:final strategyPublicId, :final folderPublicId):
        final summary = _summaries[digestOf(strategyPublicId)];
        if (summary == null) {
          return _Stop(Refused(NoSuchStrategy(strategyPublicId)));
        }
        if (folderPublicId != null) {
          switch (_placeOf(folderPublicId, _folders)) {
            case _Filed():
              break;
            case _Looped(:final loop):
              return _Stop(Refused(FolderLoop(loop)));
            case _UnderMissing(:final folderPublicId):
              return _Stop(Refused(NoSuchFolder(folderPublicId)));
            case _UnderUnreadable(:final folder):
              return _Stop(Refused(UnreadableRowInTheWay(folder)));
          }
        }
        final ReadableStrategy current;
        switch (await _header(strategyPublicId)) {
          case Found(value: final ReadableStrategy value):
            current = value;
          case Found(value: final UnreadableStrategy row):
            return _Stop(Refused(UnreadableRowInTheWay(row)));
          case NotFound():
            return _Stop(Refused(NoSuchStrategy(strategyPublicId)));
          case NotRead(:final failure):
            return _Stop(NotSaved(failure));
        }
        if (current.folderPublicId == folderPublicId) return const _Next();
        final now = _store._clock();
        final moved = current.rewritten(
          folder: switch (folderPublicId) {
            final folder? => SetValue(folder),
            null => const ClearValue(),
          },
          revision: current.revision + 1,
          updatedAt: now.isAfter(current.updatedAt) ? now : current.updatedAt,
        );
        if (_put(strategyArea(strategyPublicId), moved) case final _Stop stop) {
          return stop;
        }
        _headers[strategyPublicId] = moved;
        _putSummary(summary.withHeader(moved));
      case PutFolder(:final folder):
        final id = folder.publicId;
        final digest = digestOf(id);
        if (_folders[digest] case final UnreadableFolder row) {
          return _Stop(Refused(UnreadableRowInTheWay(row)));
        }
        if (folder.parentFolderPublicId case final parent?) {
          switch (_placeOf(parent, _folders)) {
            case _Filed(:final chain) when chain.contains(id):
              return _Stop(Refused(FolderInsideItself(id)));
            case _Filed():
              break;
            case _Looped(:final loop):
              return _Stop(Refused(FolderLoop(loop)));
            case _UnderMissing(:final folderPublicId):
              return _Stop(Refused(NoSuchFolder(folderPublicId)));
            case _UnderUnreadable(:final folder):
              return _Stop(Refused(UnreadableRowInTheWay(folder)));
          }
        }
        if (_folders[digest] == folder) return const _Next();
        if (_put(libraryArea, folder) case final _Stop stop) return stop;
        _folders[digest] = folder;
        _putFolders[digest] = folder;
        _removedFolders.remove(digest);
      case RemoveFolder(:final folderPublicId):
        final digest = digestOf(folderPublicId);
        switch (_folders[digest]) {
          case final ReadableFolder folder
              when folder.publicId == folderPublicId:
            break;
          case final UnreadableFolder row:
            return _Stop(Refused(UnreadableRowInTheWay(row)));
          case ReadableFolder() || null:
            return const _Next();
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
          return _Stop(Refused(FolderNotEmpty(folderPublicId)));
        }
        _folders.remove(digest);
        _putFolders.remove(digest);
        _removedFolders[digest] = folderPublicId;
        changes.add(Delete(libraryArea, FolderName(digest).name));
    }
    return const _Next();
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
    final digest = digestOf(summary.publicId);
    _summaries[digest] = summary;
    _putSummaries[digest] = summary;
    _removedStrategies.remove(digest);
    changes.add(
      Put(libraryArea, SummaryName(digest).name, _stored(summary.toJson())),
    );
  }

  LibraryEdited take() {
    for (final digest in _removedStrategies.keys) {
      _store._summaries.remove(digest);
      _store._strategies.remove(digest);
      _store._unreadableStrategies.remove(digest);
    }
    _store._summaries.addAll(_putSummaries);
    for (final MapEntry(:key, :value) in _headers.entries) {
      _store._strategies[digestOf(key)]?.header = value;
    }
    for (final digest in _removedFolders.keys) {
      _store._folders.remove(digest);
    }
    _store._folders.addAll(_putFolders);
    return LibraryEdited(
      summaries: _putSummaries.values.toList(),
      removedStrategies: _removedStrategies.values.toList(),
      folders: _putFolders.values.toList(),
      removedFolders: _removedFolders.values.toList(),
    );
  }
}
