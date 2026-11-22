import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';

import '../apply.dart';
import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../payloads.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import '../undo.dart';
import '../wire.dart';
import 'engine.dart';
import 'layout.dart';
import 'loaded_strategy.dart';
import 'results.dart';
import 'summary.dart';
import '../cloud/codec.dart';
import '../cloud/events.dart';
import '../cloud/shown.dart';
import '../cloud/op_facts.dart';
import '../cloud/pending.dart';
import '../cloud/queue.dart';
import '../cloud/sync.dart';
import '../cloud/visible.dart';

part 'cloud_store.dart';

final class StoreWork {
  int rowsDrawn = 0;
  int resultGroupsEncoded = 0;
  int Function() sessionRecords = () => 0;

  void reset() {
    rowsDrawn = 0;
    resultGroupsEncoded = 0;
  }
}

final storeWork = StoreWork();

final _plainDecimal = RegExp(r'^[1-9][0-9]{0,8}$');

StorageFailure? storeFormatProblem(String stored, {int known = storeFormat}) {
  if (!_plainDecimal.hasMatch(stored)) {
    return DamagedLibrary('the store format is not a plain number: $stored');
  }
  final format = int.parse(stored);
  if (format > known) {
    return NewerFormat(FormatLayer.store, found: format, known: known);
  }
  return null;
}

final class CanRead {
  const CanRead({required this.element, required this.lineupGroup});

  final bool Function(ElementPayload payload) element;
  final bool Function(LineupGroupPayload payload) lineupGroup;
}

sealed class StoreOpening {
  const StoreOpening();
}

final class StoreOpened extends StoreOpening {
  StoreOpened(this.store, List<ForeignName> foreignNames, this.origin)
    : foreignNames = List.unmodifiable(foreignNames);

  final LibraryStore store;
  final List<ForeignName> foreignNames;
  final StorageOrigin origin;
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

final class _Shut extends _State {
  const _Shut(this.failure);

  final StorageFailure failure;
}

DateTime _now() => DateTime.now().toUtc();

const _noPageRow = 'its page has no row';

RowSpot _named(String digest, {String? known}) =>
    RowSpot(names: (id) => namesId(digest, id), known: known);

sealed class _Write {
  const _Write(this.area);

  final String area;
}

final class _PutRow extends _Write {
  const _PutRow(super.area, this.row);

  final Row row;
}

final class _PutSummary extends _Write {
  const _PutSummary(this.digest, this.summary) : super(libraryArea);

  final String digest;
  final StrategySummary summary;
}

final class _DeleteName extends _Write {
  const _DeleteName(super.area, this.name);

  final String name;
}

final class _ClearArea extends _Write {
  const _ClearArea(super.area);
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

FolderRow? _folderWithId(Map<String, FolderRow> folders, String id) =>
    rowWithId(folders, id, (row) => row.publicId);

_FolderPlace _placeOf(String folderPublicId, Map<String, FolderRow> folders) {
  final chain = <String>[];
  final seen = <String>{};
  String? at = folderPublicId;
  while (at != null) {
    if (!seen.add(at)) return _Looped(chain.sublist(chain.indexOf(at)));
    chain.add(at);
    switch (_folderWithId(folders, at)) {
      case final ReadableFolder folder:
        at = folder.parentFolderPublicId;
      case final UnreadableFolder folder:
        return _UnderUnreadable(folder);
      case null:
        return _UnderMissing(at);
    }
  }
  return _Filed(chain);
}

LibraryRefusal? _filingRefusal(
  String folderPublicId,
  Map<String, FolderRow> folders, {
  String? moving,
}) => switch (_placeOf(folderPublicId, folders)) {
  _Filed(:final chain) when moving != null && chain.contains(moving) =>
    FolderInsideItself(moving),
  _Filed() => null,
  _Looped(:final loop) => FolderLoop(loop),
  _UnderMissing(:final folderPublicId) => NoSuchFolder(folderPublicId),
  _UnderUnreadable(:final folder) => UnreadableRowInTheWay(folder),
};

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

  Future<Stored<List<String>>> areas(String prefix) =>
      _watch(_inner.areas(prefix));

  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _watch(_inner.entries(area, prefix));

  Future<Committing> commit(List<Change> changes) => _inner.commit(changes);

  Future<Releasing> release() => _inner.release();
}

sealed class _Rebuilt {
  const _Rebuilt();
}

final class _RebuiltSummary extends _Rebuilt {
  const _RebuiltSummary(this.summary);

  final StrategySummary summary;
}

final class _HeaderUnreadable extends _Rebuilt {
  const _HeaderUnreadable(this.row);

  final UnreadableStrategy row;
}

final class _HeaderMissing extends _Rebuilt {
  const _HeaderMissing(this.ref);

  final StrategyRef ref;
}

final class _NoStrategyThere extends _Rebuilt {
  const _NoStrategyThere();
}

final class _RebuildNotRead extends _Rebuilt {
  const _RebuildNotRead(this.failure);

  final StorageFailure failure;
}

final class LibraryStore {
  LibraryStore._(StorageLease lease, this._canRead, this._clock, this._build) {
    storeWork.sessionRecords = () => _sessions.length;
    _lease = _WatchedLease(
      lease,
      () => _shut(const StoreStopped(LeaseEnded())),
    );
  }

  static Future<StoreOpening> open(
    StorageEngine engine, {
    required CanRead canRead,
    DateTime Function() clock = _now,
    String build = '',
  }) async {
    switch (await engine.lease()) {
      case HeldByAnotherWriter():
        return const StoreNotOpened(StoreAlreadyOpen());
      case LeaseFailed(:final failure):
        return StoreNotOpened(OpenStorageFailed(failure));
      case Leased(:final lease):
        if (lease.maxKeyLength < longestName) {
          await lease.release();
          return StoreNotOpened(EngineTooSmall(lease.maxKeyLength));
        }
        final store = LibraryStore._(lease, canRead, clock, build);
        final foreign = <ForeignName>[];
        switch ((await store._readLibrary(foreign), store._settle())) {
          case (Done(value: final origin), Done()):
            return StoreOpened(store, foreign, origin);
          case (StorageFailed(:final failure), _) ||
              (_, StorageFailed(:final failure)):
            await store.close();
            return StoreNotOpened(OpenStorageFailed(failure));
        }
    }
  }

  Future<Stored<StorageOrigin>> _originWithoutMarker(
    List<StoredEntry> libraryRows,
  ) async {
    if (libraryRows.isNotEmpty) return const Done(StorageExisted());
    return switch (await _lease.areas('')) {
      StorageFailed(:final failure) => StorageFailed(failure),
      Done(value: []) => const Done(StorageCreated()),
      Done() => const Done(StorageExisted()),
    };
  }

  List<Change> _withOwedMarker(List<Change> changes) => _markerOwed
      ? [const Put(libraryArea, formatKey, '$storeFormat'), ...changes]
      : changes;

  late final _WatchedLease _lease;
  var _markerOwed = false;
  final CanRead _canRead;
  final DateTime Function() _clock;
  final String _build;
  _State _state = const _Ready();
  Future<void> _tail = Future.value();
  Future<Releasing>? _released;
  Future<Releasing>? _closing;
  final _summaries = <String, StrategySummary>{};
  final _unreadable = <String, UnreadableStrategyListing>{};
  final _folders = <String, FolderRow>{};
  final _unplaced = <String, UnplacedRow>{};
  final _strategies = <String, LoadedStrategy>{};
  final _queues = <String, _LoadedQueue>{};
  var _numbers = const Counters(nextAttempt: 1, nextSession: 1);
  _NumbersRow _numbersRow = const _NoNumbersRow();

  UnreadableQueueRow? get _numbersHold => switch (_numbersRow) {
    _NumbersRowRead() => null,
    _NumbersRowUnreadable(:final problem) => UnreadableQueueRow(
      StoredRowRef(libraryArea, const NumbersName().name),
      problem,
    ),
    _NoNumbersRow() => UnreadableQueueRow(
      StoredRowRef(libraryArea, const NumbersName().name),
      'the numbers row is missing',
    ),
  };
  final _unsaved = <String>{};
  final _unchecked = <String>{};
  final _sessions = <String, ({QueueSession session, Shown shown})>{};
  final _changes = StreamController<StoreChange>.broadcast();

  Stream<StoreChange> get changes => _changes.stream;

  LibraryState get library {
    _settle();
    return switch (_state) {
      _Shut(:final failure) => LibraryShut(failure),
      _Ready() => LibraryOpen(
        LibraryList(
          strategies: [
            for (final MapEntry(key: digest, value: summary)
                in _summaries.entries)
              _unchecked.contains(digest)
                  ? summary.withSync(const CloudUnverified())
                  : summary,
          ],
          unreadableStrategies: _unreadable.values.toList(),
          folders: _folders.values.toList(),
          unplaced: _unplaced.values.toList(),
        ),
      ),
    };
  }

  void _shut(StorageFailure failure) {
    if (_state case _Ready()) {
      _state = _Shut(failure);
      _released = _lease.release();
      if (!_changes.isClosed) unawaited(_changes.close());
    }
  }

  void _emit(StoreChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  Future<Releasing> close() => _closing ??= _inTurn(() async {
    _shut(const StoreClosed());
    return _released!;
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
    if (_lease.status is Ended) _shut(const StoreStopped(LeaseEnded()));
    return switch (_state) {
      _Ready() => done,
      _Shut(:final failure) => StorageFailed(failure),
    };
  }

  Parsed<Row> _parseAt(String area, StoreName name, Admission stored) {
    final strategy = switch (strategyAreaNamed(area)) {
      StrategyArea(:final digest) => _named(digest),
      null => RowSpot(names: (_) => false),
    };
    return switch (name) {
      FormatName() ||
      SummaryName() ||
      CloudName() ||
      NumbersName() ||
      PendingName() ||
      AttemptName() ||
      LandedName() ||
      HeaderReadName() ||
      PageReadName() ||
      UnknownKindName() ||
      ForeignName() => Unplaced(null, '${name.name} holds no row'),
      FolderName(:final digest) => FolderRow.parse(
        stored,
        spot: _named(digest),
      ),
      HeaderName() => StrategyRow.parse(stored, spot: strategy),
      PageName(:final digest) => PageRow.parse(
        stored,
        spot: _named(digest),
        strategy: strategy,
      ),
      SettingsName(:final digest) => PageSettingsRow.parse(
        stored,
        spot: _named(digest),
      ),
      ElementName(:final page, :final digest) => ElementRow.parse(
        stored,
        spot: _named(digest),
        page: _named(page),
        canRead: _canRead.element,
      ),
      LineupName(:final page, :final digest) => LineupGroupRow.parse(
        stored,
        spot: _named(digest),
        page: _named(page),
        strategy: strategy,
        canRead: _canRead.lineupGroup,
      ),
    };
  }

  Stored<Change> _change(_Write write) {
    StorageFailed<Change> wouldNot(String name, String problem) =>
        StorageFailed(WouldNotReadBack(write.area, name, problem));
    switch (write) {
      case _PutRow(:final area, :final row):
        final name = nameOf(row);
        switch (encodeJson(row.toJsonView())) {
          case NotEncoded(:final problem):
            return wouldNot(name.name, problem);
          case Encoded(:final text):
            final back = _parseAt(area, name, admit(text));
            return switch (back) {
              Placed(row: final back) when back == row && back.key == row.key =>
                Done(Put(area, name.name, text)),
              Placed(row: final back) => wouldNot(name.name, 'reads as $back'),
              Unplaced(:final problem) => wouldNot(name.name, problem),
            };
        }
      case _PutSummary(:final digest, :final summary):
        final name = SummaryName(digest).name;
        switch (encodeJson(summary.toJson())) {
          case NotEncoded(:final problem):
            return wouldNot(name, problem);
          case Encoded(:final text):
            return switch (admit(text)) {
              Admitted(:final json) => switch (StrategySummary.decode(json)) {
                Read(:final value) when value == summary => Done(
                  Put(libraryArea, name, text),
                ),
                Read(:final value) => wouldNot(name, 'reads as $value'),
                CouldNotRead(:final problem) => wouldNot(name, problem),
              },
              NotAdmitted(:final problem) => wouldNot(name, problem),
            };
        }
      case _DeleteName(:final area, :final name):
        return Done(Delete(area, name));
      case _ClearArea(:final area):
        return Done(ClearArea(area));
      case _PutEntry() ||
          _PutAttempt() ||
          _PutFacts() ||
          _PutNumbers() ||
          _PutGroup() ||
          _PutLanded():
        return _cloudChange(write);
    }
  }

  static List<Change> _collapsed(List<Change> changes) {
    final kept = <Change>[];
    final named = <(String, String)>{};
    final cleared = <String>{};
    for (final change in changes.reversed) {
      switch (change) {
        case ClearArea(:final area):
          if (cleared.add(area)) kept.add(change);
        case Put(:final area, :final key) || Delete(:final area, :final key):
          if (!cleared.contains(area) && named.add((area, key))) {
            kept.add(change);
          }
      }
    }
    return kept.reversed.toList();
  }

  Future<Saving<S, R>> _commit<S, R>(
    List<_Write> writes,
    S Function() take,
  ) async {
    if (_settle() case StorageFailed(:final failure)) return NotSaved(failure);
    final changes = <Change>[];
    for (final write in writes) {
      switch (_change(write)) {
        case Done(value: final change):
          changes.add(change);
        case StorageFailed(:final failure):
          return NotSaved(failure);
      }
    }
    switch (await _lease.commit(_withOwedMarker(_collapsed(changes)))) {
      case CommitApplied():
        _markerOwed = false;
        return Saved(take());
      case CommitRefused(:final failure):
        if (failure is LeaseEnded) _shut(const StoreStopped(LeaseEnded()));
        return NotSaved(failure);
      case CommitUnknown(:final failure):
        _shut(StoreStopped(failure));
        await _released;
        return SaveInDoubt(failure);
    }
  }

  Future<Stored<StorageOrigin>> _readLibrary(List<ForeignName> foreign) async {
    final List<StoredEntry> entries;
    switch (await _lease.entries(libraryArea, '')) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(:final value):
        entries = value;
    }
    final format = [
      for (final (:key, :value) in entries)
        if (key == formatKey) value,
    ].firstOrNull;
    final StorageOrigin origin;
    if (format != null) {
      if (storeFormatProblem(format) case final problem?) {
        return StorageFailed(problem);
      }
      if (int.parse(format) < storeFormat) _markerOwed = true;
      origin = const StorageExisted();
    } else {
      switch (await _originWithoutMarker(entries)) {
        case StorageFailed(:final failure):
          return StorageFailed(failure);
        case Done(:final value):
          origin = value;
      }
      _markerOwed = true;
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
                  if (summary.sync case KeptInCloud(
                    :final tally,
                  ) when tally.standing == Standing.good && tally.total == 0) {
                    _unchecked.add(digest);
                  }
                case Read() || CouldNotRead():
                  toRebuild.add(digest);
              }
            case NotAdmitted():
              toRebuild.add(digest);
          }
        case final FolderName name:
          switch (FolderRow.parse(admit(value), spot: _named(name.digest))) {
            case Placed(:final row):
              _folders[name.digest] = row;
            case Unplaced(:final stored, :final problem):
              _unplaced[key] = UnplacedRow(
                ref: StoredRowRef(libraryArea, key),
                stored: stored,
                problem: problem,
              );
          }
        case final ForeignName name:
          foreign.add(name);
        case NumbersName():
          switch (countersFromText(value)) {
            case CloudRowRead(value: final numbers):
              _numbers = numbers;
              _numbersRow = _NumbersRowRead(numbers);
            case CloudRowUnreadable(:final problem):
              _numbersRow = _NumbersRowUnreadable(problem);
          }
        case _:
          break;
      }
    }
    for (final digest in toRebuild) {
      await _repair(digest);
    }
    return Done(origin);
  }

  Future<void> _repair(String digest) async {
    switch (await _rebuilt(digest)) {
      case _RebuiltSummary(:final summary):
        _keepInMemory(digest, summary);
      case _RebuildNotRead(:final failure):
        _summaries.remove(digest);
        _unsaved.remove(digest);
        _unreadable[digest] = UnreadableStrategyListing(
          ref: StrategyRef(StrategyArea(digest).name),
          header: HeaderAbsent('its rows could not be read: $failure'),
        );
      case _HeaderUnreadable() || _HeaderMissing():
        if (_strategies[digest] case final strategy?) _listUnreadable(strategy);
      case _NoStrategyThere():
        _listGone(digest);
    }
  }

  void _listGone(String digest) {
    _summaries.remove(digest);
    _unsaved.remove(digest);
    _strategies.remove(digest);
    _unreadable[digest] = UnreadableStrategyListing(
      ref: StrategyRef(StrategyArea(digest).name),
      header: const HeaderAbsent('none of its rows are stored'),
    );
  }

  Future<_Rebuilt> _summaryFor(LoadedStrategy strategy) async {
    if (_summaries[strategy.digest] case final summary?) {
      return _RebuiltSummary(summary);
    }
    final rebuilt = await _rebuilt(strategy.digest);
    if (rebuilt case _RebuiltSummary(:final summary)) {
      _keepInMemory(strategy.digest, summary);
    }
    return rebuilt;
  }

  Future<_Rebuilt> _summaryForId(String strategyPublicId) async =>
      switch (await _strategy(strategyPublicId)) {
        Found(value: final strategy) => await _summaryFor(strategy),
        NotFound() => const _NoStrategyThere(),
        NotRead(:final failure) => _RebuildNotRead(failure),
        InUnreadableStrategy(:final listing) => _HeaderMissing(listing.ref),
      };

  void _keepInMemory(String digest, StrategySummary summary) {
    _unreadable.remove(digest);
    if (summary == _summaries[digest]) return;
    _summaries[digest] = summary;
    _unsaved.add(digest);
  }

  void _listUnreadable(LoadedStrategy strategy) {
    _summaries.remove(strategy.digest);
    _unsaved.remove(strategy.digest);
    _unreadable[strategy.digest] = UnreadableStrategyListing(
      ref: StrategyRef(strategy.area),
      header: strategy.header,
    );
  }

  static StrategySummary _summaryOf(
    LoadedStrategy strategy,
    ReadableStrategy header,
    Map<String, PageTally> stored,
  ) => StrategySummary.of(
    strategy: header,
    pages: strategy.pages,
    settings: strategy.allSettings,
    tallies: strategy.talliesOver(stored),
    elsewhere: strategy.elsewhere,
  );

  void _refresh(LoadedStrategy strategy) {
    final current = _summaries[strategy.digest];
    if (current == null || strategy.keeping == Keeping.cloud) return;
    if (strategy.header case HeaderPlaced(row: final ReadableStrategy header)) {
      _keepInMemory(
        strategy.digest,
        _summaryOf(strategy, header, current.tallies),
      );
    }
  }

  Future<_Rebuilt> _rebuilt(String digest) async {
    final LoadedStrategy strategy;
    switch (await _strategyAt(digest)) {
      case Found(:final value):
        strategy = value;
      case NotFound():
        return const _NoStrategyThere();
      case NotRead(:final failure):
        return _RebuildNotRead(failure);
      case InUnreadableStrategy(:final listing):
        return _HeaderMissing(listing.ref);
    }
    final ReadableStrategy header;
    switch (strategy.header) {
      case HeaderPlaced(row: final ReadableStrategy row):
        header = row;
      case HeaderPlaced(row: final UnreadableStrategy row):
        return _HeaderUnreadable(row);
      case HeaderUnplaced() || HeaderAbsent():
        return _HeaderMissing(StrategyRef(strategy.area));
    }
    if (await _loadPages(strategy, strategy.pageDigests) case StorageFailed(
      :final failure,
    )) {
      return _RebuildNotRead(failure);
    }
    if (strategy.keeping == Keeping.cloud) {
      return switch (await _queueOf(strategy)) {
        _QueueLoaded(:final queue) => switch (await _cloudSummaryAll(
          strategy,
          header,
          queue.current,
        )) {
          Done(:final value) => _RebuiltSummary(value),
          StorageFailed(:final failure) => _RebuildNotRead(failure),
        },
        _QueueHeld(:final rows) => _RebuiltSummary(
          _summaryOf(strategy, header, const {}).withSync(_heldSync(rows)),
        ),
        _QueueNotRead(:final failure) => _RebuildNotRead(failure),
      };
    }
    return _RebuiltSummary(_summaryOf(strategy, header, const {}));
  }

  Future<Reading<LoadedStrategy>> _strategyAt(String digest) async {
    if (_strategies[digest] case final loaded?) return Found(loaded);
    final area = StrategyArea(digest);
    final known = _summaries[digest]?.publicId;
    final StrategyHeader header;
    switch (await _lease.read(area.name, const HeaderName().name)) {
      case KeyNotRead(:final failure):
        return NotRead(failure);
      case KeyMissing():
        header = const HeaderAbsent('the strategy row is missing');
      case KeyHeld(:final value):
        header = headerFrom(
          StrategyRow.parse(admit(value), spot: _named(digest, known: known)),
        );
    }
    final strategyId = switch (header) {
      HeaderPlaced(:final row) => row.publicId,
      HeaderUnplaced() || HeaderAbsent() => known,
    };
    final List<StoreName> names;
    switch (await _lease.keys(area.name, '')) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        if (value.isEmpty) return const NotFound();
        names = [for (final key in value) readName(area, key)];
    }
    final pages = <String, PageRow>{};
    final settings = <String, PageSettingsRow>{};
    final unplaced = <String, UnplacedRow>{};
    void keepUnplaced(String key, Object? stored, String problem) =>
        unplaced[key] = UnplacedRow(
          ref: StoredRowRef(area.name, key),
          stored: stored,
          problem: problem,
        );
    switch (await _lease.entries(area.name, 'page/')) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          if (readName(area, key) case final PageName name) {
            switch (PageRow.parse(
              admit(value),
              spot: _named(name.digest),
              strategy: _named(digest, known: strategyId),
            )) {
              case Placed(:final row):
                pages[name.digest] = row;
              case Unplaced(:final stored, :final problem):
                keepUnplaced(key, stored, problem);
            }
          }
        }
    }
    switch (await _lease.entries(area.name, 'settings/')) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          if (readName(area, key) case final SettingsName name) {
            switch (PageSettingsRow.parse(
              admit(value),
              spot: _named(name.digest),
            )) {
              case Placed(:final row):
                settings[name.digest] = row;
              case Unplaced(:final stored, :final problem):
                keepUnplaced(key, stored, problem);
            }
          }
        }
    }
    for (final MapEntry(key: page, value: row) in settings.entries.toList()) {
      if (pages.containsKey(page)) continue;
      settings.remove(page);
      keepUnplaced(SettingsName(page).name, row.toJsonView(), _noPageRow);
    }
    final loaded = LoadedStrategy(
      digest: digest,
      header: header,
      strategyId: strategyId,
      pages: pages,
      settings: settings,
      unplaced: unplaced,
      names: names,
    );
    if (await _loadPages(loaded, loaded.pagesWithoutRow.toList())
        case StorageFailed(:final failure)) {
      return NotRead(failure);
    }
    _strategies[digest] = loaded;
    _refresh(loaded);
    return Found(loaded);
  }

  Future<Reading<LoadedStrategy>> _strategy(String strategyPublicId) async {
    switch (await _strategyAt(digestOf(strategyPublicId))) {
      case Found(value: final loaded):
        switch (loaded.header) {
          case HeaderPlaced(:final row) when row.publicId == strategyPublicId:
            return Found(loaded);
          case HeaderPlaced():
            return const NotFound();
          case HeaderUnplaced() || HeaderAbsent():
            _listUnreadable(loaded);
            return InUnreadableStrategy(_unreadable[loaded.digest]!);
        }
      case final reading:
        return reading;
    }
  }

  Future<Stored<void>> _loadPages(
    LoadedStrategy strategy,
    Iterable<String> pageDigests,
  ) async {
    for (final page in pageDigests) {
      if (strategy.isLoaded(page)) continue;
      if (await _loadPage(strategy, page) case StorageFailed(:final failure)) {
        return StorageFailed(failure);
      }
    }
    return done;
  }

  Future<Stored<void>> _loadPage(
    LoadedStrategy strategy,
    String pageDigest,
  ) async {
    final area = StrategyArea(strategy.digest);
    final page = LoadedPage();
    final pageSpot = _named(pageDigest, known: strategy.pageIdOf(pageDigest));
    final strategySpot = _named(strategy.digest, known: strategy.strategyId);
    final orphaned = !strategy.hasPageRow(pageDigest);
    switch (await _lease.entries(area.name, pageContentPrefix(pageDigest))) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          void keepUnplaced(Object? stored, String problem) =>
              page.unplaced[key] = UnplacedRow(
                ref: StoredRowRef(area.name, key),
                stored: stored,
                problem: problem,
              );
          switch (readName(area, key)) {
            case final ElementName name:
              switch (ElementRow.parse(
                admit(value),
                spot: _named(name.digest),
                page: pageSpot,
                canRead: _canRead.element,
              )) {
                case Placed(:final row) when orphaned:
                  keepUnplaced(row.toJsonView(), _noPageRow);
                case Placed(:final row):
                  page.elements[name.digest] = row;
                case Unplaced(:final stored, :final problem):
                  keepUnplaced(stored, problem);
              }
            case final LineupName name:
              switch (LineupGroupRow.parse(
                admit(value),
                spot: _named(name.digest),
                page: pageSpot,
                strategy: strategySpot,
                canRead: _canRead.lineupGroup,
              )) {
                case Placed(:final row) when orphaned:
                  keepUnplaced(row.toJsonView(), _noPageRow);
                case Placed(:final row):
                  page.lineupGroups[name.digest] = row;
                case Unplaced(:final stored, :final problem):
                  keepUnplaced(stored, problem);
              }
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
    _refresh(strategy);
    return done;
  }

  Future<Reading<StrategyContent>> readStrategy(String strategyPublicId) =>
      _inTurn(() async {
        if (_settle() case StorageFailed(:final failure)) {
          return NotRead(failure);
        }
        final found = await _strategy(strategyPublicId);
        if (found case Found(
          value: final loaded,
        ) when loaded.keeping == Keeping.cloud) {
          return switch (await _openCloud(strategyPublicId)) {
            final _CloudReady cloud => await _readCloudStrategy(cloud),
            final _CloudHeld cloud => await _readCloudStrategy(cloud),
            _CloudUnread(:final failure) => NotRead(failure),
            _CloudRefused() => InUnreadableStrategy(
              UnreadableStrategyListing(
                ref: StrategyRef(loaded.area),
                header: loaded.header,
              ),
            ),
          };
        }
        return switch (found) {
          Found(value: final strategy) => Found(
            StrategyContent(
              strategy: switch (strategy.header) {
                HeaderPlaced(:final row) => row,
                HeaderUnplaced() || HeaderAbsent() => throw StateError(
                  'a strategy found by id has its own row',
                ),
              },
              pages: _ordered(strategy.pages),
              settings: strategy.settingsByPage,
              unplaced: strategy.allUnplaced,
              foreignNames: strategy.foreignNames,
            ),
          ),
          NotFound() => const NotFound(),
          NotRead(:final failure) => NotRead(failure),
          InUnreadableStrategy(:final listing) => InUnreadableStrategy(listing),
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
      case InUnreadableStrategy(:final listing):
        return InUnreadableStrategy(listing);
    }
    if (strategy.keeping == Keeping.cloud) {
      return switch (await _openCloud(strategyPublicId)) {
        final _CloudReady cloud => await _readCloudPage(cloud, pagePublicId),
        final _CloudHeld cloud => await _readCloudPage(cloud, pagePublicId),
        _CloudUnread(:final failure) => NotRead(failure),
        _CloudRefused() => InUnreadableStrategy(
          UnreadableStrategyListing(
            ref: StrategyRef(strategy.area),
            header: strategy.header,
          ),
        ),
      };
    }
    final page = strategy.page(pagePublicId);
    if (page == null) return const NotFound();
    final pageDigest = digestOf(pagePublicId);
    if (await _loadPages(strategy, [pageDigest]) case StorageFailed(
      :final failure,
    )) {
      return NotRead(failure);
    }
    final loaded = strategy.loadedPage(pageDigest)!;
    return Found(
      PageContent(
        page: page,
        settings: switch (strategy.settingsOf(pagePublicId)) {
          final row? => SettingsStored(row),
          null => const NoSettingsStored(),
        },
        elements: loaded.elements.values,
        lineupGroups: loaded.lineupGroups.values,
        unknownKinds: loaded.unknownKinds,
        unplaced: loaded.unplaced.values,
        foreignNames: loaded.foreignNames,
      ),
    );
  });

  Future<StrategySearch> findStrategies() => _inTurn(() async {
    if (_settle() case StorageFailed(:final failure)) {
      return StrategiesNotSearched(failure);
    }
    final List<String> areas;
    switch (await _lease.areas(strategyAreaPrefix)) {
      case StorageFailed(:final failure):
        return StrategiesNotSearched(failure);
      case Done(:final value):
        areas = value;
    }
    final listed = <String>{};
    final rebuilt = <String, StrategySummary>{};
    final unreadable = <String, LoadedStrategy>{};
    for (final area in areas) {
      final digest = switch (strategyAreaNamed(area)) {
        StrategyArea(:final digest) => digest,
        null => null,
      };
      if (digest == null) continue;
      listed.add(digest);
      if (_summaries.containsKey(digest) || _unreadable.containsKey(digest)) {
        continue;
      }
      switch (await _rebuilt(digest)) {
        case _RebuiltSummary(:final summary):
          rebuilt[digest] = summary;
        case _RebuildNotRead(:final failure):
          return StrategiesNotSearched(failure);
        case _HeaderUnreadable() || _HeaderMissing():
          if (_strategies[digest] case final strategy?) {
            unreadable[digest] = strategy;
          }
        case _NoStrategyThere():
          break;
      }
    }
    final gone = [
      for (final digest in _summaries.keys)
        if (!listed.contains(digest)) digest,
    ];
    for (final MapEntry(key: digest, value: summary) in rebuilt.entries) {
      _keepInMemory(digest, summary);
    }
    for (final strategy in unreadable.values) {
      _listUnreadable(strategy);
    }
    gone.forEach(_listGone);
    return StrategiesFound(
      rebuilt: rebuilt.values.toList(),
      unreadable: [
        for (final digest in [...unreadable.keys, ...gone])
          _unreadable[digest]!,
      ],
    );
  });

  Future<Unloading> unload(String strategyPublicId) => _inTurn(() async {
    if (_settle() case StorageFailed(:final failure)) {
      return NotUnloaded(failure);
    }
    _strategies.remove(digestOf(strategyPublicId));
    _queues.remove(digestOf(strategyPublicId));
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
          ...strategy.pagesOfElement(elementPublicId),
        ],
        ElementPatchOp(:final pagePublicId, :final elementPublicId) => [
          if (pagePublicId != null) digestOf(pagePublicId),
          ...strategy.pagesOfElement(elementPublicId),
        ],
        ElementDeleteOp(:final elementPublicId) ||
        ElementReorderOp(
          :final elementPublicId,
        ) => strategy.pagesOfElement(elementPublicId),
        LineupGroupAddOp(:final pagePublicId, :final lineupPublicId) => [
          digestOf(pagePublicId),
          ...strategy.pagesOfLineupGroup(lineupPublicId),
        ],
        LineupGroupPatchOp(:final pagePublicId, :final lineupPublicId) => [
          if (pagePublicId != null) digestOf(pagePublicId),
          ...strategy.pagesOfLineupGroup(lineupPublicId),
        ],
        LineupGroupDeleteOp(:final lineupPublicId) ||
        LineupGroupReorderOp(
          :final lineupPublicId,
        ) => strategy.pagesOfLineupGroup(lineupPublicId),
      };

  static CommitRefusal? _inTheWay(Held held, Row written) => switch (held) {
    HeldNothing() => null,
    HeldUnplaced(:final row) => UnplacedRowInTheWay(row.ref),
    HeldRow(
      row: UnreadableStrategy() ||
          UnreadableFolder() ||
          UnreadablePage() ||
          UnreadablePageSettings() ||
          UnreadableElement() ||
          UnreadableLineupGroup(),
    ) =>
      OpRefusal(UnreadableTarget(written.key)),
    HeldRow(:final row) when row.key != written.key => OpRefusal(
      UnreadableTarget(written.key),
    ),
    HeldRow() => null,
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

  Future<CommitResult> commit(String strategyPublicId, StrategyOp op) async =>
      switch (await commitAll(strategyPublicId, [op])) {
        Saved(:final value) => Saved(value.single),
        NothingToSave() => const NothingToSave(),
        Refused(:final reason) => Refused(reason),
        NotSaved(:final failure) => NotSaved(failure),
        SaveInDoubt(:final failure) => SaveInDoubt(failure),
      };

  static CommitRefusal? _blocked(LoadedStrategy strategy, StrategyOp op) {
    if (op case PageAddOp(
      :final pagePublicId,
      :final copyContentFromPagePublicId,
    )) {
      if (strategy.orphansUnder(digestOf(pagePublicId)).firstOrNull
          case final row?) {
        return UnplacedRowInTheWay(row.ref);
      }
      if (copyContentFromPagePublicId case final source?
          when strategy.orphansUnder(digestOf(source)).isNotEmpty) {
        return CopyLeavesRowsBehind(source);
      }
    }
    if (op case PageAddOp(copyContentFromPagePublicId: final source?)) {
      if (strategy.loadedPage(digestOf(source)) case final page?
          when page.unknownKinds.isNotEmpty ||
              page.foreignNames.isNotEmpty ||
              page.unplaced.isNotEmpty) {
        return CopyLeavesRowsBehind(source);
      }
    }
    if (op is PageAddOp || op is PageDeleteOp || op is PageReorderOp) {
      if (strategy.unplacedPages.firstOrNull case final row?) {
        return UnplacedRowInTheWay(row.ref);
      }
    }
    return null;
  }

  Future<BatchResult> commitAll(String strategyPublicId, List<StrategyOp> ops) {
    final asked = List<StrategyOp>.of(ops);
    return _inTurn(() async {
      if (_settle() case StorageFailed(:final failure)) {
        return NotSaved(failure);
      }
      final LoadedStrategy strategy;
      switch (await _strategy(strategyPublicId)) {
        case Found(:final value):
          strategy = value;
        case NotFound():
          return Refused(NoSuchStrategy(strategyPublicId));
        case NotRead(:final failure):
          return NotSaved(failure);
        case InUnreadableStrategy(:final listing):
          return Refused(StrategyNotReadable(listing.ref));
      }
      final digest = strategy.digest;
      final ReadableStrategy header;
      switch (strategy.header) {
        case HeaderPlaced(row: final ReadableStrategy row):
          header = row;
        case HeaderPlaced(row: final UnreadableStrategy row):
          return Refused(UnreadableRowInTheWay(row));
        case HeaderUnplaced() || HeaderAbsent():
          return Refused(NoSuchStrategy(strategyPublicId));
      }
      if (strategy.keeping == Keeping.cloud) {
        return switch (await _openCloud(strategyPublicId)) {
          final _CloudReady cloud => await _commitCloud(cloud, asked),
          _CloudHeld(:final rows) => Refused(QueueHeld(rows)),
          _CloudUnread(:final failure) => NotSaved(failure),
          _CloudRefused(:final refusal) => Refused(refusal),
        };
      }
      for (final op in asked) {
        if (await _loadPages(strategy, _pagesFor(op, strategy))
            case StorageFailed(:final failure)) {
          return NotSaved(failure);
        }
      }
      final StrategySummary before;
      switch (await _summaryFor(strategy)) {
        case _RebuiltSummary(summary: final found):
          before = found;
        case _HeaderUnreadable(:final row):
          return Refused(UnreadableRowInTheWay(row));
        case _HeaderMissing(:final ref):
          return Refused(StrategyNotReadable(ref));
        case _RebuildNotRead(:final failure):
          return NotSaved(failure);
        case _NoStrategyThere():
          return Refused(NoSuchStrategy(strategyPublicId));
      }
      final pending = PendingRows(strategy, header);
      final applied = <(StrategyOp, List<RowWrite>, Undo)>[];
      final now = _clock();
      for (final op in asked) {
        if (_blocked(strategy, op) case final refusal?) {
          return Refused(refusal);
        }
        switch (applyOp(pending, op)) {
          case OpUnchanged():
            continue;
          case OpRefused(:final refusal):
            return Refused(OpRefusal(refusal));
          case OpApplied(:final writes, :final undo):
            final stamped = _stamped(pending.strategy, writes, now);
            pending.take(stamped);
            applied.add((op, stamped, undo));
        }
      }
      if (applied.isEmpty) return const NothingToSave();
      final area = strategy.area;
      final changes = <_Write>[];
      final written = <RowWrite>[];
      final committed = <Committed>[];
      var summary = before;
      var (after, pagesAfter, settingsAfter) = strategy.after(header, const []);
      final pagesById = {for (final page in pagesAfter) page.publicId: page};
      final settingsById = {
        for (final row in settingsAfter) row.pagePublicId: row,
      };
      for (final (op, writes, undo) in applied) {
        for (final write in writes) {
          if (_inTheWay(strategy.heldUnder(nameOf(write.after)), write.after)
              case final refusal?) {
            return Refused(refusal);
          }
          changes.add(_PutRow(area, write.after));
          if (write case RowChanged(
            :final before,
          ) when nameOf(before).name != nameOf(write.after).name) {
            changes.add(_DeleteName(area, nameOf(before).name));
          }
          switch (write.after) {
            case final ReadableStrategy row:
              after = row;
            case final PageRow row:
              pagesById[row.publicId] = row;
            case final PageSettingsRow row:
              settingsById[row.pagePublicId] = row;
            case _:
              break;
          }
        }
        written.addAll(writes);
        summary = summary.after(
          after,
          pagesById.values,
          settingsById.values,
          writes,
        );
        committed.add(
          Committed(
            change: StrategyEdited(
              strategyPublicId: strategyPublicId,
              opId: op.opId,
              writes: writes,
              removed: const [],
              summary: summary,
            ),
            undo: undo,
          ),
        );
      }
      final summaryAfter = summary;
      changes.add(_PutSummary(digest, summaryAfter));
      final BatchResult result = await _commit(changes, () {
        strategy.take(written);
        _summaries[digest] = summaryAfter;
        _unsaved.remove(digest);
        return List<Committed>.unmodifiable(committed);
      });
      if (result case Saved(:final value)) {
        for (final each in value) {
          _emit(each.change);
        }
      }
      return result;
    });
  }

  Future<LibraryEditResult> putStrategy(
    StrategyRowSet rows,
  ) => _inTurn(() async {
    if (_settle() case StorageFailed(:final failure)) {
      return NotSaved(failure);
    }
    if (_rowOutside(rows) case final key?) {
      return Refused(RowOutsideStrategy(key));
    }
    if (rows.strategy.folderPublicId case final folder?) {
      if (_filingRefusal(folder, _folders) case final refusal?) {
        return Refused(refusal);
      }
    }
    final id = rows.strategy.publicId;
    final digest = digestOf(id);
    final area = strategyArea(id);
    final LoadedStrategy? loaded;
    switch (await _strategyAt(digest)) {
      case NotFound():
        loaded = null;
      case NotRead(:final failure):
        return NotSaved(failure);
      case InUnreadableStrategy(:final listing):
        return Refused(StrategyNotReadable(listing.ref));
      case Found(value: final strategy):
        switch (strategy.header) {
          case HeaderPlaced(row: final ReadableStrategy row)
              when row.publicId == id:
            break;
          case HeaderPlaced(row: final UnreadableStrategy row):
            return Refused(UnreadableRowInTheWay(row));
          case HeaderPlaced() || HeaderUnplaced() || HeaderAbsent():
            return Refused(StrategyNotReadable(StrategyRef(area)));
        }
        if (await _loadPages(strategy, strategy.pageDigests) case StorageFailed(
          :final failure,
        )) {
          return NotSaved(failure);
        }
        if (strategy.keeping == Keeping.cloud) {
          return Refused(KeptInTheCloud(id));
        }
        if (_dropped(strategy) case final refusal?) {
          return Refused(refusal);
        }
        loaded = strategy;
    }
    final held = loaded?.heldRows ?? const {};
    final changes = <_Write>[];
    final written = <RowWrite>[];
    final kept = <RowKey>{};
    for (final row in rows.rows) {
      kept.add(row.key);
      switch (held[row.key]) {
        case (_, final stored)
            when sameJsonTree(stored.toJsonView(), row.toJsonView()):
          continue;
        case (final name, final stored) when !_keepsUnknownFields(stored, row):
          return Refused(
            PutWouldDrop(StoredRowRef(area, name), Dropped.unknownField),
          );
        case (final name, final stored):
          changes.add(_PutRow(area, row));
          if (nameOf(row).name != name) {
            changes.add(_DeleteName(area, name));
          }
          written.add(RowChanged(before: stored, after: row, fields: const {}));
        case null:
          changes.add(_PutRow(area, row));
          written.add(RowAdded(row));
      }
    }
    final gone = <Row>[];
    for (final MapEntry(key: key, value: (name, row)) in held.entries) {
      if (kept.contains(key)) continue;
      changes.add(_DeleteName(area, name));
      gone.add(row);
    }
    final summary = _summaryOfRows(rows);
    if (changes.isEmpty &&
        summary == _summaries[digest] &&
        !_unsaved.contains(digest)) {
      return const NothingToSave();
    }
    changes.add(_PutSummary(digest, summary));
    final result = await _commit<LibraryEdited, LibraryRefusal>(changes, () {
      if (loaded == null) {
        _strategies[digest] = LoadedStrategy.image(digest, rows);
      } else {
        for (final write in written) {
          if (write case RowAdded(after: PageRow(:final publicId))) {
            loaded.addLoadedPage(digestOf(publicId), LoadedPage());
          }
        }
        loaded
          ..drop(gone)
          ..take(written);
      }
      _summaries[digest] = summary;
      _unsaved.remove(digest);
      _unreadable.remove(digest);
      return LibraryEdited(
        summaries: [summary],
        removedStrategies: const [],
        removedUnreadableStrategies: const [],
        folders: const [],
        removedFolders: const [],
      );
    });
    if (result case Saved(:final value)) _emit(value);
    return result;
  });

  Future<RecordResult> record(
    String strategyPublicId,
    List<QueueEvent> events,
  ) {
    final asked = List<QueueEvent>.of(events);
    return _inTurn(() async {
      if (_settle() case StorageFailed(:final failure)) {
        return NotSaved(failure);
      }
      return _recordCloud(strategyPublicId, asked);
    });
  }

  Future<Saving<StrategySummary, LibraryRefusal>> addCloudStrategy(
    HeaderRead header,
    List<PageRead> pages,
  ) {
    final asked = List<PageRead>.of(pages);
    return _inTurn(() async {
      if (_settle() case StorageFailed(:final failure)) {
        return NotSaved(failure);
      }
      final result = await _addCloud(header, asked);
      if (result case Saved(:final value)) {
        _emit(
          LibraryEdited(
            summaries: [value],
            removedStrategies: const [],
            removedUnreadableStrategies: const [],
            folders: const [],
            removedFolders: const [],
          ),
        );
      }
      return result;
    });
  }

  Future<Saving<StrategySummary, CommitRefusal>> discardUnreadableQueue(
    String strategyPublicId,
    DiscardsUnsentWork acknowledged,
  ) => _inTurn(() async {
    if (_settle() case StorageFailed(:final failure)) return NotSaved(failure);
    return _discardHeld(strategyPublicId);
  });

  Future<RebuildResult> rebuildSummary(String strategyPublicId) =>
      _inTurn(() async {
        if (_settle() case StorageFailed(:final failure)) {
          return NotSaved(failure);
        }
        switch (await _strategy(strategyPublicId)) {
          case Found(:final value) when value.keeping == Keeping.cloud:
            switch (await _queueOf(value)) {
              case _QueueHeld(:final rows):
                return Refused(QueueHeld(rows));
              case _QueueNotRead(:final failure):
                return NotSaved(failure);
              case _QueueLoaded():
                break;
            }
          case Found():
            break;
          case NotFound():
            return Refused(NoSuchStrategy(strategyPublicId));
          case NotRead(:final failure):
            return NotSaved(failure);
          case InUnreadableStrategy(:final listing):
            return Refused(StrategyNotReadable(listing.ref));
        }
        final digest = digestOf(strategyPublicId);
        final StrategySummary rebuilt;
        switch (await _rebuilt(digest)) {
          case _RebuiltSummary(:final summary):
            rebuilt = summary;
          case _HeaderUnreadable(:final row):
            return Refused(UnreadableRowInTheWay(row));
          case _HeaderMissing(:final ref):
            return Refused(StrategyNotReadable(ref));
          case _RebuildNotRead(:final failure):
            return NotSaved(failure);
          case _NoStrategyThere():
            return Refused(NoSuchStrategy(strategyPublicId));
        }
        if (rebuilt == _summaries[digest] && !_unsaved.contains(digest)) {
          return const NothingToSave();
        }
        final result = await _commit<StrategySummary, CommitRefusal>(
          [_PutSummary(digest, rebuilt)],
          () {
            _summaries[digest] = rebuilt;
            _unsaved.remove(digest);
            _unreadable.remove(digest);
            return rebuilt;
          },
        );
        if (result case Saved(:final value)) {
          _emit(
            LibraryEdited(
              summaries: [value],
              removedStrategies: const [],
              removedUnreadableStrategies: const [],
              folders: const [],
              removedFolders: const [],
            ),
          );
        }
        return result;
      });

  Future<LibraryEditResult> editLibrary(List<LibraryChange> changes) {
    final asked = List<LibraryChange>.of(changes);
    return _inTurn(() async {
      if (_settle() case StorageFailed(:final failure)) {
        return NotSaved(failure);
      }
      final edit = _LibraryEdit(this);
      for (final change in asked) {
        if (await edit.add(change) case _Stop(:final result)) return result;
      }
      if (edit.isEmpty) return const NothingToSave();
      final result = await _commit<LibraryEdited, LibraryRefusal>(
        edit.writes,
        edit.take,
      );
      if (result case Saved(:final value)) _emit(value);
      return result;
    });
  }
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

final class _Staged<V extends Object> extends MapBase<String, V> {
  _Staged(this._base);

  final Map<String, V> _base;
  final _put = <String, V>{};
  final _gone = <String>{};

  @override
  V? operator [](Object? key) =>
      _gone.contains(key) ? null : _put[key] ?? _base[key];

  @override
  void operator []=(String key, V value) {
    _gone.remove(key);
    _put[key] = value;
  }

  @override
  V? remove(Object? key) {
    final was = this[key];
    _put.remove(key);
    if (key is String) _gone.add(key);
    return was;
  }

  @override
  bool containsKey(Object? key) =>
      !_gone.contains(key) && (_put.containsKey(key) || _base.containsKey(key));

  @override
  Iterable<String> get keys => {
    ..._put.keys,
    for (final key in _base.keys)
      if (!_gone.contains(key)) key,
  };

  @override
  void clear() {
    _put.clear();
    _gone.addAll(_base.keys);
  }
}

RowKey? _rowOutside(StrategyRowSet rows) {
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

StrategySummary _summaryOfRows(StrategyRowSet rows) {
  final tallies = <String, PageTally>{};
  for (final row in rows.elements) {
    tallies[row.pagePublicId] = (tallies[row.pagePublicId] ?? PageTally.empty)
        .plus(row, 1);
  }
  for (final row in rows.lineupGroups) {
    tallies[row.pagePublicId] = (tallies[row.pagePublicId] ?? PageTally.empty)
        .plusGroup(row, 1);
  }
  return StrategySummary.of(
    strategy: rows.strategy,
    pages: rows.pages,
    settings: rows.settings,
    tallies: tallies,
    elsewhere: PageTally.empty,
  );
}

Set<String> _keys(JsonObject? fields) => {...?fields?.toMap().keys};

bool _keeps(JsonObject? stored, JsonObject? given) =>
    _keys(given).containsAll(_keys(stored));

bool _keepsUnknownFields(Row stored, Row given) => switch ((stored, given)) {
  (final ReadableStrategy a, final ReadableStrategy b) =>
    _keeps(a.unknownFields, b.unknownFields) &&
        _keeps(
          a.themeOverridePalette?.unknownFields,
          b.themeOverridePalette?.unknownFields,
        ),
  (final ReadablePageRow a, final ReadablePageRow b) => _keeps(
    a.unknownFields,
    b.unknownFields,
  ),
  (final ReadablePageSettings a, final ReadablePageSettings b) =>
    _keeps(a.unknownFields, b.unknownFields) &&
        _keeps(a.settings?.unknownFields, b.settings?.unknownFields),
  (final ReadableElementRow a, final ReadableElementRow b) =>
    _keeps(a.unknownFields, b.unknownFields) &&
        _keeps(a.payload.unknownFields, b.payload.unknownFields),
  (final ReadableLineupGroupRow a, final ReadableLineupGroupRow b) =>
    _keeps(a.unknownFields, b.unknownFields) &&
        _keeps(a.payload.unknownFields, b.payload.unknownFields),
  _ => true,
};

LibraryRefusal? _dropped(LoadedStrategy strategy) {
  final area = strategy.area;
  StoredRowRef at(Row row) => StoredRowRef(area, nameOf(row).name);
  for (final name in strategy.foreignNames) {
    return PutWouldDrop(StoredRowRef(area, name.name), Dropped.foreignName);
  }
  for (final row in strategy.allUnplaced) {
    return UnplacedRowInTheWay(row.ref);
  }
  for (final page in strategy.pages) {
    switch (page) {
      case UnreadablePage():
        return UnreadableRowInTheWay(page);
      case TrashedPage():
        return PutWouldDrop(at(page), Dropped.trashedPage);
      case LivePage():
        break;
    }
  }
  for (final row in strategy.allSettings) {
    if (row is UnreadablePageSettings) return UnreadableRowInTheWay(row);
  }
  final seen = <RowKey>{};
  for (final digest in strategy.pageDigests) {
    final page = strategy.loadedPage(digest)!;
    for (final row in [...page.elements.values, ...page.lineupGroups.values]) {
      if (!seen.add(row.key)) {
        return PutWouldDrop(at(row), Dropped.duplicateRow);
      }
    }
    for (final name in page.foreignNames) {
      return PutWouldDrop(StoredRowRef(area, name.name), Dropped.foreignName);
    }
    for (final row in page.unknownKinds) {
      return PutWouldDrop(StoredRowRef(area, row.key), Dropped.unknownKind);
    }
    for (final row in page.unplaced.values) {
      return UnplacedRowInTheWay(row.ref);
    }
    for (final row in [...page.elements.values, ...page.lineupGroups.values]) {
      switch (row) {
        case UnreadableElement() || UnreadableLineupGroup():
          return UnreadableRowInTheWay(row);
        case DeletedElement() || DeletedLineupGroup():
          return PutWouldDrop(at(row), Dropped.tombstone);
        case _:
          break;
      }
    }
  }
  return null;
}

final class _LibraryEdit {
  _LibraryEdit(this._store)
    : _folders = _Staged(_store._folders),
      _summaries = _Staged(_store._summaries),
      _unreadable = _Staged(_store._unreadable);

  final LibraryStore _store;
  final Map<String, FolderRow> _folders;
  final Map<String, StrategySummary> _summaries;
  final Map<String, UnreadableStrategyListing> _unreadable;
  final writes = <_Write>[];
  final _headers = <String, ReadableStrategy>{};
  final _stored = <String, (ReadableStrategy, StrategySummary)>{};
  final _added = <String, (ReadableStrategy, StrategySummary)>{};
  final _putSummaries = <String, StrategySummary>{};
  final _removed = <String, String>{};
  final _removedUnreadable = <String, StrategyRef>{};
  final _putFolders = <String, ReadableFolder>{};
  final _removedFolders = <String, String>{};

  bool get isEmpty => writes.isEmpty;

  StrategySummary? _summaryWithId(String id) =>
      switch (_summaries[digestOf(id)]) {
        final summary? when summary.publicId == id => summary,
        _ => null,
      };

  UnreadableStrategyListing? _unreadableWithId(String id) =>
      switch (_unreadable[digestOf(id)]) {
        final listing? &&
                UnreadableStrategyListing(
                  header: HeaderPlaced(row: StrategyRow(:final publicId)),
                )
            when publicId == id =>
          listing,
        _ => null,
      };

  bool _hasStrategy(String id) =>
      _summaryWithId(id) != null || _unreadableWithId(id) != null;

  void _removeArea(String digest) {
    writes
      ..add(_ClearArea(StrategyArea(digest).name))
      ..add(_DeleteName(libraryArea, SummaryName(digest).name));
    _summaries.remove(digest);
    _putSummaries.remove(digest);
    _unreadable.remove(digest);
    _headers.removeWhere((id, _) => digestOf(id) == digest);
    _added.removeWhere((id, _) => digestOf(id) == digest);
    _stored.removeWhere((id, _) => digestOf(id) == digest);
  }

  Future<_Step> add(LibraryChange change) async {
    switch (change) {
      case AddStrategy(:final rows):
        final id = rows.strategy.publicId;
        final digest = digestOf(id);
        if (_hasStrategy(id) ||
            _removed.containsKey(digest) ||
            _removedUnreadable.containsKey(digest)) {
          return _Stop(Refused(StrategyAlreadyInStore(id)));
        }
        if (_rowOutside(rows) case final key?) {
          return _Stop(Refused(RowOutsideStrategy(key)));
        }
        if (rows.strategy.folderPublicId case final folder?) {
          if (_filingRefusal(folder, _folders) case final refusal?) {
            return _Stop(Refused(refusal));
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
          writes.add(_PutRow(area, row));
        }
        _headers[id] = rows.strategy;
        final summary = _summaryOfRows(rows);
        _added[id] = (rows.strategy, summary);
        _putSummary(summary);
      case RemoveStrategy(:final strategyPublicId):
        final digest = digestOf(strategyPublicId);
        if (_unreadable[digest] case UnreadableStrategyListing(
          :final ref,
          header: HeaderUnplaced() || HeaderAbsent(),
        )) {
          return _Stop(Refused(StrategyNotReadable(ref)));
        }
        if (_removed.containsKey(digest) ||
            _removedUnreadable.containsKey(digest)) {
          return _Stop(Refused(NoSuchStrategy(strategyPublicId)));
        }
        switch (await _store._strategy(strategyPublicId)) {
          case Found(value: final strategy)
              when strategy.keeping == Keeping.cloud:
            switch (await _store._queueOf(strategy)) {
              case _QueueLoaded(:final queue):
                final tally = Tally.of(queue.current, _store._cloudNow());
                if (tally.total > 0) {
                  return _Stop(
                    Refused(CloudWorkOutstanding(strategyPublicId, tally)),
                  );
                }
              case _QueueHeld():
                return _Stop(
                  Refused(UnsentWorkInArea(StrategyRef(strategy.area))),
                );
              case _QueueNotRead(:final failure):
                return _Stop(NotSaved(failure));
            }
          case NotRead(:final failure):
            return _Stop(NotSaved(failure));
          case Found() || NotFound() || InUnreadableStrategy():
            break;
        }
        switch (await _header(strategyPublicId)) {
          case NotRead(:final failure):
            return _Stop(NotSaved(failure));
          case InUnreadableStrategy(:final listing):
            return _Stop(Refused(StrategyNotReadable(listing.ref)));
          case NotFound() when !_hasStrategy(strategyPublicId):
            return _Stop(Refused(NoSuchStrategy(strategyPublicId)));
          case Found() || NotFound():
            break;
        }
        _removeArea(digest);
        _removed[digest] = strategyPublicId;
      case RemoveUnreadableStrategy(:final ref, :final discarding):
        final digest = switch (strategyAreaNamed(ref.area)) {
          StrategyArea(:final digest) => digest,
          null => null,
        };
        if (digest == null || !_unreadable.containsKey(digest)) {
          return _Stop(Refused(NoSuchUnreadableStrategy(ref)));
        }
        if (discarding == null) {
          switch (await _store._lease.keys(ref.area, '')) {
            case StorageFailed(:final failure):
              return _Stop(NotSaved(failure));
            case Done(:final value) when value.any(_queueName):
              return _Stop(Refused(UnsentWorkInArea(ref)));
            case Done():
              break;
          }
        }
        _removeArea(digest);
        _removedUnreadable[digest] = ref;
      case MoveStrategy(:final strategyPublicId, :final folderPublicId):
        final digest = digestOf(strategyPublicId);
        if (_removed.containsKey(digest) ||
            _removedUnreadable.containsKey(digest)) {
          return _Stop(Refused(NoSuchStrategy(strategyPublicId)));
        }
        switch (await _store._strategy(strategyPublicId)) {
          case Found(:final value) when value.keeping == Keeping.cloud:
            return _Stop(Refused(KeptInTheCloud(strategyPublicId)));
          case NotRead(:final failure):
            return _Stop(NotSaved(failure));
          case Found() || NotFound() || InUnreadableStrategy():
            break;
        }
        if (folderPublicId != null) {
          if (_filingRefusal(folderPublicId, _folders) case final refusal?) {
            return _Stop(Refused(refusal));
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
          case InUnreadableStrategy(:final listing):
            return _Stop(Refused(StrategyNotReadable(listing.ref)));
        }
        final found = switch (_putSummaries[digest]) {
          final put? => _RebuiltSummary(put),
          null => await _store._summaryForId(strategyPublicId),
        };
        final StrategySummary summary;
        switch (found) {
          case _RebuiltSummary(summary: final rebuilt):
            summary = rebuilt;
          case _HeaderUnreadable(:final row):
            return _Stop(Refused(UnreadableRowInTheWay(row)));
          case _HeaderMissing(:final ref):
            return _Stop(Refused(StrategyNotReadable(ref)));
          case _RebuildNotRead(:final failure):
            return _Stop(NotSaved(failure));
          case _NoStrategyThere():
            return _Stop(Refused(NoSuchStrategy(strategyPublicId)));
        }
        if (current.folderPublicId == folderPublicId) return const _Next();
        final added = _added[strategyPublicId];
        final (header, headerSummary) =
            added ??
            _stored.putIfAbsent(strategyPublicId, () => (current, summary));
        final area = strategyArea(strategyPublicId);
        writes.removeWhere(
          (write) => switch (write) {
            _PutRow(row: StrategyRow()) => write.area == area,
            _PutSummary() => write.digest == digest,
            _ => false,
          },
        );
        if (added == null && header.folderPublicId == folderPublicId) {
          _headers[strategyPublicId] = header;
          _putSummaries.remove(digest);
          _summaries[digest] = headerSummary;
          return const _Next();
        }
        final now = _store._clock();
        final moved = header.rewritten(
          folder: switch (folderPublicId) {
            final folder? => SetValue(folder),
            null => const ClearValue(),
          },
          revision: added == null ? header.revision + 1 : header.revision,
          updatedAt: added == null && now.isAfter(header.updatedAt)
              ? now
              : header.updatedAt,
        );
        writes.add(_PutRow(area, moved));
        _headers[strategyPublicId] = moved;
        _putSummary(headerSummary.withHeader(moved));
      case PutFolder(:final folder):
        final id = folder.publicId;
        final digest = digestOf(id);
        if (_store._unplaced[FolderName(digest).name] case final row?) {
          return _Stop(Refused(UnplacedRowInTheWay(row.ref)));
        }
        if (_folders[digest] case final UnreadableFolder row) {
          return _Stop(Refused(UnreadableRowInTheWay(row)));
        }
        if (folder.parentFolderPublicId case final parent?) {
          if (_filingRefusal(parent, _folders, moving: id)
              case final refusal?) {
            return _Stop(Refused(refusal));
          }
        }
        if (_folderWithId(_folders, id) == folder) return const _Next();
        writes.add(_PutRow(libraryArea, folder));
        _folders[digest] = folder;
        _putFolders[digest] = folder;
        _removedFolders.remove(digest);
      case RemoveFolder(:final folderPublicId):
        final digest = digestOf(folderPublicId);
        switch (_folderWithId(_folders, folderPublicId)) {
          case ReadableFolder():
            break;
          case final UnreadableFolder row:
            return _Stop(Refused(UnreadableRowInTheWay(row)));
          case null:
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
        writes.add(_DeleteName(libraryArea, FolderName(digest).name));
    }
    return const _Next();
  }

  Future<Reading<StrategyRow>> _header(String strategyPublicId) async {
    final digest = digestOf(strategyPublicId);
    if (_removed.containsKey(digest) ||
        _removedUnreadable.containsKey(digest)) {
      return const NotFound();
    }
    if (_headers[strategyPublicId] case final header?) return Found(header);
    return switch (await _store._strategy(strategyPublicId)) {
      Found(value: LoadedStrategy(header: HeaderPlaced(:final row))) => Found(
        row,
      ),
      Found() || NotFound() => const NotFound(),
      NotRead(:final failure) => NotRead(failure),
      InUnreadableStrategy(:final listing) => InUnreadableStrategy(listing),
    };
  }

  void _putSummary(StrategySummary summary) {
    final digest = digestOf(summary.publicId);
    _summaries[digest] = summary;
    _putSummaries[digest] = summary;
    _removed.remove(digest);
    writes.add(_PutSummary(digest, summary));
  }

  LibraryEdited take() {
    _store._unsaved.removeAll({
      ..._removed.keys,
      ..._removedUnreadable.keys,
      ..._putSummaries.keys,
    });
    for (final digest in {..._removed.keys, ..._removedUnreadable.keys}) {
      _store._summaries.remove(digest);
      _store._strategies.remove(digest);
      _store._queues.remove(digest);
      _store._sessions.remove(digest);
      _store._unreadable.remove(digest);
    }
    _store._summaries.addAll(_putSummaries);
    for (final MapEntry(:key, :value) in _headers.entries) {
      _store._strategies[digestOf(key)]?.header = HeaderPlaced(value);
    }
    for (final digest in _removedFolders.keys) {
      _store._folders.remove(digest);
    }
    _store._folders.addAll(_putFolders);
    return LibraryEdited(
      summaries: _putSummaries.values.toList(),
      removedStrategies: _removed.values.toList(),
      removedUnreadableStrategies: _removedUnreadable.values.toList(),
      folders: _putFolders.values.toList(),
      removedFolders: _removedFolders.values.toList(),
    );
  }
}
