import 'dart:async';

import 'package:collection/collection.dart';

import '../apply.dart';
import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../payloads.dart';
import '../rows.dart';
import '../wire.dart';
import 'engine.dart';
import 'journal.dart';
import 'layout.dart';
import 'loaded_strategy.dart';
import 'results.dart';
import 'stored_row.dart';
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

DateTime _now() => DateTime.now().toUtc();

String _stored(Row row) => canonicalJson(row.toJson());

final class LibraryStore {
  LibraryStore._(this._engine, this._canRead, this._clock);

  static Future<StoreOpening> open(
    StorageEngine engine, {
    required CanRead canRead,
    DateTime Function() clock = _now,
  }) async {
    if (_held[engine] != null) return const StoreNotOpened(StoreAlreadyOpen());
    _held[engine] = true;
    final opening = await _open(engine, canRead, clock);
    if (opening is StoreNotOpened) _held[engine] = null;
    return opening;
  }

  static final _held = Expando<bool>();

  static Future<StoreOpening> _open(
    StorageEngine engine,
    CanRead canRead,
    DateTime Function() clock,
  ) async {
    switch (await engine.read(journalArea, journalKey)) {
      case StorageFailed(:final failure):
        return StoreNotOpened(OpenStorageFailed(failure));
      case Done(value: null):
        break;
      case Done(value: final String text):
        switch (JournalRecord.decode(text)) {
          case CouldNotRead(:final problem):
            return StoreNotOpened(SavedEditUnreadable(text, problem));
          case Read(value: final record):
            if (await _finish(engine, record) case final failure?) {
              return StoreNotOpened(OpenStorageFailed(failure));
            }
        }
    }
    final store = LibraryStore._(engine, canRead, clock);
    if (await store._readLibrary() case final failure?) {
      return StoreNotOpened(OpenStorageFailed(failure));
    }
    return StoreOpened(store);
  }

  final StorageEngine _engine;
  final CanRead _canRead;
  final DateTime Function() _clock;
  _State _state = const _Ready();
  Future<void> _tail = Future.value();
  final _summaries = <String, StrategySummary>{};
  final _folders = <String, FolderRow>{};
  final _unreadable = <String, UnreadableRow>{};
  final _strategies = <String, LoadedStrategy>{};
  final _changes = StreamController<StoreChange>.broadcast();

  Stream<StoreChange> get changes => _changes.stream;

  LibraryList get library => LibraryList(
    strategies: _summaries.values.toList(),
    folders: _folders.values.toList(),
    unreadable: _unreadable.values.toList(),
  );

  Future<void> close() => _inTurn(() async {
    await _changes.close();
    _held[_engine] = null;
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

  static Future<StorageFailure?> _finish(
    StorageEngine engine,
    JournalRecord record,
  ) async {
    if (await record.replay(engine) case StorageFailed(:final failure)) {
      return failure;
    }
    if (await JournalRecord.clear(engine) case StorageFailed(:final failure)) {
      return failure;
    }
    return null;
  }

  Future<StorageFailure?> _readLibrary() async {
    final List<String> summaryKeys;
    switch (await _engine.keys(libraryArea, summaryPrefix)) {
      case StorageFailed(:final failure):
        return failure;
      case Done(:final value):
        summaryKeys = value;
    }
    final toRebuild = <String>[];
    for (final key in summaryKeys) {
      final id = Uri.decodeComponent(key.substring(summaryPrefix.length));
      switch (await _readKey(libraryArea, key, StrategySummary.decode)) {
        case NotRead(:final failure):
          return failure;
        case Found(:final value) when value.publicId == id:
          _summaries[id] = value;
        case Found():
        case NotFound():
        case Unreadable():
          toRebuild.add(id);
      }
    }
    final List<String> folderKeys;
    switch (await _engine.keys(libraryArea, folderPrefix)) {
      case StorageFailed(:final failure):
        return failure;
      case Done(:final value):
        folderKeys = value;
    }
    for (final key in folderKeys) {
      switch (await _readKey(libraryArea, key, FolderRow.decode)) {
        case NotRead(:final failure):
          return failure;
        case Found(:final value) when folderKey(value.publicId) == key:
          _folders[value.publicId] = value;
        case Found(:final value):
          _unreadable[key] = UnreadableRow(
            area: libraryArea,
            key: key,
            text: _stored(value),
            problem: 'a folder row under another folder id',
          );
        case Unreadable(:final row):
          _unreadable[key] = row;
        case NotFound():
          break;
      }
    }
    for (final id in toRebuild) {
      switch (await _rebuild(id)) {
        case Saved():
        case NothingToSave():
          break;
        case NotSaved(:final failure) || SaveInDoubt(:final failure):
          return failure;
        case Refused():
          if (await _engine.read(libraryArea, summaryKey(id)) case Done(
            value: final String text,
          )) {
            _unreadable[summaryKey(id)] = UnreadableRow(
              area: libraryArea,
              key: summaryKey(id),
              text: text,
              problem: 'a summary this build cannot read or rebuild',
            );
          }
      }
    }
    return null;
  }

  Future<Reading<T>> _readKey<T>(
    String area,
    String key,
    Decoded<T> Function(Object? json) decode,
  ) async {
    switch (await _engine.read(area, key)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(value: null):
        return const NotFound();
      case Done(value: final String text):
        return switch (readStored(area, key, text, decode)) {
          ReadText(:final value) => Found(value),
          UnreadableText(:final row) => Unreadable(row),
        };
    }
  }

  Future<Reading<LoadedStrategy>> _strategy(String strategyPublicId) async {
    if (_strategies[strategyPublicId] case final loaded?) return Found(loaded);
    final area = strategyArea(strategyPublicId);
    final StrategyRow header;
    switch (await _readKey(area, headerKey, StrategyRow.decode)) {
      case NotRead(:final failure):
        return NotRead(failure);
      case NotFound():
        return const NotFound();
      case Unreadable(:final row):
        return Unreadable(row);
      case Found(:final value) when value.publicId != strategyPublicId:
        return Unreadable(
          UnreadableRow(
            area: area,
            key: headerKey,
            text: _stored(value),
            problem: 'the strategy row names another strategy',
          ),
        );
      case Found(:final value):
        header = value;
    }
    final unreadable = <UnreadableRow>[];
    final pages = <PageRow>[];
    switch (await _readAll(area, pagePrefix, PageRow.decode)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (key, read) in value) {
          switch (read) {
            case ReadText(value: final row)
                when pageKey(row.publicId) == key &&
                    row.strategyPublicId == strategyPublicId:
              pages.add(row);
            case ReadText(value: final row):
              unreadable.add(_misplaced(area, key, row));
            case UnreadableText(:final row):
              unreadable.add(row);
          }
        }
    }
    final settings = <PageSettingsRow>[];
    switch (await _readAll(area, settingsPrefix, PageSettingsRow.decode)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        for (final (key, read) in value) {
          switch (read) {
            case ReadText(value: final row)
                when settingsKey(row.pagePublicId) == key:
              settings.add(row);
            case ReadText(value: final row):
              unreadable.add(_misplaced(area, key, row));
            case UnreadableText(:final row):
              unreadable.add(row);
          }
        }
    }
    final List<String> contentKeys;
    switch (await _engine.keys(area, contentPrefix)) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        contentKeys = value;
    }
    final loaded = LoadedStrategy(
      strategy: header,
      pages: pages,
      settings: settings,
      unreadable: unreadable,
      contentKeys: contentKeys.map(ContentKey.parse).nonNulls,
    );
    _strategies[strategyPublicId] = loaded;
    return Found(loaded);
  }

  UnreadableRow _misplaced(String area, String key, Row row) => UnreadableRow(
    area: area,
    key: key,
    text: _stored(row),
    problem: 'a row stored under a key that is not its own',
  );

  Future<Stored<List<(String, StoredText<T>)>>> _readAll<T>(
    String area,
    String prefix,
    Decoded<T> Function(Object? json) decode,
  ) async {
    final List<String> keys;
    switch (await _engine.keys(area, prefix)) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(:final value):
        keys = value;
    }
    final read = <(String, StoredText<T>)>[];
    for (final key in keys) {
      switch (await _engine.read(area, key)) {
        case StorageFailed(:final failure):
          return StorageFailed(failure);
        case Done(value: null):
          break;
        case Done(value: final String text):
          read.add((key, readStored(area, key, text, decode)));
      }
    }
    return Done(read);
  }

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
    final area = strategyArea(strategy.publicId);
    final List<String> keys;
    switch (await _engine.keys(area, '$contentPrefix$pageSegment/')) {
      case StorageFailed(:final failure):
        return failure;
      case Done(:final value):
        keys = value;
    }
    final page = LoadedPage();
    final unreadable = <UnreadableRow>[];
    for (final key in keys) {
      final String text;
      switch (await _engine.read(area, key)) {
        case StorageFailed(:final failure):
          return failure;
        case Done(value: null):
          continue;
        case Done(value: final String value):
          text = value;
      }
      switch (ContentKey.parse(key)) {
        case ElementContentKey():
          switch (readStored(
            area,
            key,
            text,
            (json) => ElementRow.decode(json, canRead: _canRead),
          )) {
            case ReadText(value: final row) when rowKey(row) == key:
              page.elements[row.publicId] = row;
            case ReadText(value: final row):
              unreadable.add(_misplaced(area, key, row));
            case UnreadableText(:final row):
              unreadable.add(row);
          }
        case LineupContentKey():
          switch (readStored(area, key, text, LineupGroupRow.decode)) {
            case ReadText(value: final row)
                when rowKey(row) == key &&
                    row.strategyPublicId == strategy.publicId:
              page.lineupGroups[row.publicId] = row;
            case ReadText(value: final row):
              unreadable.add(_misplaced(area, key, row));
            case UnreadableText(:final row):
              unreadable.add(row);
          }
        case OtherContentKey() || null:
          unreadable.add(
            UnreadableRow(
              area: area,
              key: key,
              text: text,
              problem: 'a kind of row this build does not know',
            ),
          );
      }
    }
    strategy.addLoadedPage(pageSegment, page, unreadable);
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
                unreadable: [
                  for (final row in strategy.unreadable.values)
                    if (!row.key.startsWith(contentPrefix)) row,
                ],
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
    if (page == null) {
      if (strategy.unreadable[pageKey(pagePublicId)] case final row?) {
        return Unreadable(row);
      }
      return const NotFound();
    }
    if (await _loadPages(strategy, [segment(pagePublicId)])
        case final failure?) {
      return NotRead(failure);
    }
    final loaded = strategy.loadedPage(pagePublicId)!;
    final prefix = pageContentPrefix(pagePublicId);
    return Found(
      PageContent(
        page: page,
        settings: strategy.settingsOf(pagePublicId),
        elements: loaded.elements.values.toList(),
        lineupGroups: loaded.lineupGroups.values.toList(),
        unreadable: [
          for (final row in strategy.unreadable.values)
            if (row.key.startsWith(prefix)) row,
        ],
      ),
    );
  });

  static List<PageRow> _ordered(Iterable<PageRow> pages) => pages.sorted(
    (a, b) => switch (a.sortIndex.compareTo(b.sortIndex)) {
      0 => a.publicId.compareTo(b.publicId),
      final order => order,
    },
  );

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

  Future<StorageFailure?> _settle() async {
    switch (_state) {
      case _Ready():
        return null;
      case _Stopped(:final cause):
        return StoreStopped(cause);
      case _Finishing(:final record):
        if (await _finish(_engine, record) case final failure?) {
          return failure;
        }
        _state = const _Ready();
        return null;
    }
  }

  Future<Saving<S, R>> _save<S, R>(
    JournalRecord record,
    S Function() take,
  ) async {
    for (final write in record.writes) {
      if (write.key.length > _engine.maxKeyLength) {
        return NotSaved(KeyTooLong(write.area, write.key));
      }
    }
    if (await record.save(_engine) case StorageFailed(:final failure)) {
      if (await JournalRecord.clear(_engine) case StorageFailed()) {
        _state = _Stopped(failure);
        return SaveInDoubt(failure);
      }
      return NotSaved(failure);
    }
    final saved = take();
    if (await _finish(_engine, record) != null) {
      _state = _Finishing(record);
    }
    return Saved(saved);
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
        final area = strategyArea(strategyPublicId);
        final writes = KeyWrites();
        for (final write in applied.writes) {
          final key = rowKey(write.after);
          if (strategy.unreadable[key] case final row?) {
            return Refused(UnreadableRowInTheWay(row));
          }
          writes.put(area, key, _stored(write.after));
          if (write case RowChanged(:final before) when rowKey(before) != key) {
            writes.delete(area, rowKey(before));
          }
        }
        final (header, pages) = strategy.headerAfter(applied.writes);
        final summary = _summaries[strategyPublicId];
        if (summary == null) {
          return Refused(NoSuchStrategy(strategyPublicId));
        }
        final summaryAfter = summary.after(
          header,
          pages,
          applied.writes,
          _clock(),
        );
        writes.put(
          libraryArea,
          summaryKey(strategyPublicId),
          canonicalJson(summaryAfter.toJson()),
        );
        final record = JournalRecord(
          edit: {'strategyPublicId': strategyPublicId, 'op': op.toJson()},
          writes: writes.writes,
        );
        final CommitResult result = await _save(record, () {
          strategy.take(applied.writes);
          _summaries[strategyPublicId] = summaryAfter;
          return StrategyEdited(
            strategyPublicId: strategyPublicId,
            writes: applied.writes,
            undo: applied.undo,
            summary: summaryAfter,
          );
        });
        if (result case Saved(:final value)) _changes.add(value);
        return result;
      });

  Future<RebuildResult> rebuildSummary(String strategyPublicId) =>
      _inTurn(() async {
        if (await _settle() case final failure?) return NotSaved(failure);
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
    final (DateTime, DateTime) times;
    switch (await _timesOf(strategyPublicId)) {
      case Done(:final value):
        times = value;
      case StorageFailed(:final failure):
        return NotSaved(failure);
    }
    final (createdAt, updatedAt) = times;
    final rebuilt = _summaryOf(strategy, createdAt, updatedAt);
    if (rebuilt == _summaries[strategyPublicId]) return const NothingToSave();
    final writes = KeyWrites()
      ..put(
        libraryArea,
        summaryKey(strategyPublicId),
        canonicalJson(rebuilt.toJson()),
      );
    return _save(
      JournalRecord(
        edit: {'rebuildSummary': strategyPublicId},
        writes: writes.writes,
      ),
      () {
        _summaries[strategyPublicId] = rebuilt;
        _unreadable.remove(summaryKey(strategyPublicId));
        return rebuilt;
      },
    );
  }

  Future<Stored<(DateTime, DateTime)>> _timesOf(String strategyPublicId) async {
    if (_summaries[strategyPublicId] case final summary?) {
      return Done((summary.createdAt, summary.updatedAt));
    }
    return switch (await _engine.read(
      libraryArea,
      summaryKey(strategyPublicId),
    )) {
      StorageFailed(:final failure) => StorageFailed(failure),
      Done(value: final String text) => Done(_salvagedTimes(text) ?? _times()),
      Done(value: null) => Done(_times()),
    };
  }

  (DateTime, DateTime) _times() {
    final now = _clock();
    return (now, now);
  }

  static (DateTime, DateTime)? _salvagedTimes(String text) =>
      switch (readStored(libraryArea, '', text, SummaryTimes.decode)) {
        ReadText(:final value) => (value.createdAt, value.updatedAt),
        UnreadableText() => null,
      };

  StrategySummary _summaryOf(
    LoadedStrategy strategy,
    DateTime createdAt,
    DateTime updatedAt,
  ) {
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
      createdAt: createdAt,
      updatedAt: updatedAt,
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
          JournalRecord(edit: {'library': edit.described}, writes: edit.writes),
          edit.take,
        );
        if (result case Saved(:final value)) _changes.add(value);
        return result;
      });
}

final class SummaryTimes {
  const SummaryTimes(this.createdAt, this.updatedAt);

  final DateTime createdAt;
  final DateTime updatedAt;

  static Decoded<SummaryTimes> decode(Object? json) =>
      JsonFields.read(json, 'summary times', (fields) {
        final created = fields.whole('createdAt');
        final updated = fields.whole('updatedAt');
        if (created.abs() > 8640000000000000 ||
            updated.abs() > 8640000000000000) {
          fields.reject('expected times');
        }
        return () => SummaryTimes(
          DateTime.fromMillisecondsSinceEpoch(created, isUtc: true),
          DateTime.fromMillisecondsSinceEpoch(updated, isUtc: true),
        );
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
  final _headers = <String, StrategyRow>{};
  final _putSummaries = <String, StrategySummary>{};
  final _removedStrategies = <String>{};
  final _putFolders = <String, FolderRow>{};
  final _removedFolders = <String>{};

  bool get isEmpty => described.isEmpty;

  List<KeyWrite> get writes => _keys.writes;

  bool _hasStrategy(String id) =>
      _summaries.containsKey(id) ||
      _store._unreadable.containsKey(summaryKey(id));

  Future<LibraryEditResult?> add(LibraryChange change) async {
    switch (change) {
      case AddStrategy(:final rows, :final createdAt, :final updatedAt):
        final id = rows.strategy.publicId;
        if (_hasStrategy(id) || _removedStrategies.contains(id)) {
          return Refused(StrategyAlreadyInStore(id));
        }
        if (rows.strategy.folderPublicId case final folder?
            when !_folders.containsKey(folder)) {
          return Refused(NoSuchFolder(folder));
        }
        final area = strategyArea(id);
        switch (await _store._engine.keys(area, '')) {
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
            createdAt: createdAt.toUtc(),
            updatedAt: updatedAt.toUtc(),
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
        switch (await _store._engine.keys(area, '')) {
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
        if (folderPublicId != null && !_folders.containsKey(folderPublicId)) {
          return Refused(NoSuchFolder(folderPublicId));
        }
        final StrategyRow current;
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
        final moved = StrategyRow(
          publicId: current.publicId,
          folderPublicId: folderPublicId,
          name: current.name,
          mapData: current.mapData,
          themeProfileId: current.themeProfileId,
          themeOverridePalette: current.themeOverridePalette,
          revision: current.revision + 1,
        );
        _headers[strategyPublicId] = moved;
        _keys.put(strategyArea(strategyPublicId), headerKey, _stored(moved));
        _putSummary(summary.withHeader(moved, _store._clock()));
        described.add({
          'moveStrategy': strategyPublicId,
          'folderPublicId': folderPublicId,
        });
      case PutFolder(:final folder):
        final id = folder.publicId;
        if (_store._unreadable[folderKey(id)] case final row?) {
          return Refused(UnreadableRowInTheWay(row));
        }
        if (folder.parentFolderPublicId case final parent?) {
          if (!_folders.containsKey(parent)) {
            return Refused(NoSuchFolder(parent));
          }
          for (
            String? at = parent;
            at != null;
            at = _folders[at]?.parentFolderPublicId
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
        if (!_folders.containsKey(folderPublicId)) return null;
        final holdsFolder = _folders.values.any(
          (folder) => folder.parentFolderPublicId == folderPublicId,
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
      _store._unreadable.remove(summaryKey(id));
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
