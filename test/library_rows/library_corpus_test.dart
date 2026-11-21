import 'dart:io';

import 'package:collection/collection.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_rows/round_trip.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

import 'library_sources.dart';

const corpusVariable = 'ICARUS_LIBRARY_CORPUS';
const detailVariable = 'ICARUS_LIBRARY_DETAIL';

final class CorpusReport {
  int stores = 0;
  int icaFiles = 0;
  int strategies = 0;
  int pages = 0;
  final items = {for (final kind in ElementKind.values) kind: 0};
  int lineups = 0;
  int folders = 0;
  int sameStrategies = 0;
  int storedStrategies = 0;
  int putStrategies = 0;
  int supersededLegacyItems = 0;
  final differences = <String, int>{};
  final refusals = <String, int>{};
  final details = <String>[];

  int get problemCount =>
      differences.values.fold(0, (sum, count) => sum + count) +
      refusals.values.fold(0, (sum, count) => sum + count);

  void count(Map<String, int> into, String key) =>
      into[key] = (into[key] ?? 0) + 1;

  Future<void> addStrategy(
    StrategyData strategy, {
    List<Folder> folders = const [],
  }) async {
    final ordinal = strategies++;
    pages += strategy.pages.length;
    final result = roundTrip(strategy);
    switch (result) {
      case RoundTripSame(:final made):
        sameStrategies++;
        _addMade(made);
        await _throughStore(ordinal, strategy, made, folders);
      case RoundTripDiffers(:final made, :final back, :final differences):
        _addMade(made);
        for (final difference in differences) {
          count(this.differences, difference.kind.name);
          details.add('strategy $ordinal: $difference');
        }
        for (final row in back.unreadable) {
          count(this.differences, 'unreadable after the round trip');
          details.add('strategy $ordinal: unreadable ${row.publicId}');
        }
        for (final _ in back.notInStrategy) {
          count(this.differences, 'left out after the round trip');
        }
      case RoundTripRefusedToRows(:final refused):
        for (final problem in refused.problems) {
          count(refusals, 'to rows: ${problem.runtimeType}');
          details.add('strategy $ordinal: ${problem.runtimeType}');
        }
      case RoundTripRefusedFromRows(:final refused):
        for (final problem in refused.problems) {
          count(refusals, 'from rows: ${problem.runtimeType}');
          details.add('strategy $ordinal: ${problem.runtimeType}');
        }
    }
  }

  void _storeProblem(int ordinal, String kind, String detail) {
    count(refusals, 'store: $kind');
    details.add('strategy $ordinal: store: $kind: $detail');
  }

  Future<void> _throughStore(
    int ordinal,
    StrategyData strategy,
    StrategyRowsMade made,
    List<Folder> folders,
  ) async {
    final canRead = CanRead(
      element: (payload) => canReadElementPayload(payload, strategy.mapData),
      lineupGroup: (payload) => _appReadsLineup(payload),
    );
    Future<LibraryStore> open(MemoryStorage storage) async =>
        switch (await LibraryStore.open(
          MemoryEngine(storage),
          canRead: canRead,
        )) {
          StoreOpened(:final store) => store,
          StoreNotOpened(:final problem) => throw StateError('$problem'),
        };
    final storage = MemoryStorage();
    final adding = await open(storage);
    final added = await adding.editLibrary([
      for (final folder in _parentsFirst(folders))
        PutFolder(folderToRow(folder).row),
      AddStrategy(made.rows),
    ]);
    await adding.close();
    if (added is! Saved<LibraryEdited, LibraryRefusal>) {
      _storeProblem(
          ordinal,
          'not added',
          switch (added) {
            Refused(:final reason) => '$reason',
            NotSaved(:final failure) => '$failure',
            final other => '$other',
          });
      return;
    }
    final store = await open(storage);
    final id = made.rows.strategy.publicId;
    final content = switch (await store.readStrategy(id)) {
      Found(:final value) => value,
      final other => throw StateError('strategy $ordinal: $other'),
    };
    final elements = <ElementRow>[];
    final groups = <LineupGroupRow>[];
    final damaged = <String>[
      for (final row in content.unplaced) 'unplaced ${row.ref}',
    ];
    for (final page in content.pages) {
      final onPage = switch (await store.readPage(id, page.publicId)) {
        Found(:final value) => value,
        final other => throw StateError('strategy $ordinal: $other'),
      };
      elements.addAll(onPage.elements);
      groups.addAll(onPage.lineupGroups);
      for (final row in onPage.unplaced) {
        damaged.add('unplaced ${row.ref}');
      }
      for (final row in onPage.unknownKinds) {
        damaged.add('unknown kind ${row.key}');
      }
    }
    for (final row in [
      ...content.pages,
      ...content.settings.values,
      ...elements,
      ...groups,
    ]) {
      switch (row) {
        case UnreadablePage(:final problem) ||
              UnreadablePageSettings(:final problem) ||
              UnreadableElement(:final problem) ||
              UnreadableLineupGroup(:final problem):
          damaged.add('${row.key}: $problem');
        case _:
          break;
      }
    }
    final readability = switch (store.library) {
      LibraryOpen(:final list) => list.strategies
          .singleWhere((summary) => summary.publicId == id)
          .readability,
      LibraryShut(:final failure) => throw StateError('$failure'),
    };
    await store.close();
    if (damaged.isNotEmpty || readability is! AllReadable) {
      _storeProblem(ordinal, 'read with damaged rows', damaged.join('; '));
      return;
    }
    final header = content.strategy;
    if (header is! ReadableStrategy) {
      _storeProblem(ordinal, 'header unreadable', '$header');
      return;
    }
    final back = strategyFromRows(
      StrategyRowSet(
        strategy: header,
        pages: content.pages,
        settings: content.settings.values,
        elements: elements,
        lineupGroups: groups,
      ),
    );
    switch (back) {
      case StrategyDataRefused(:final problems):
        _storeProblem(ordinal, 'not converted back', '$problems');
      case StrategyDataMade(strategy: final again):
        final differences = strategyDifferences(strategy, again);
        if (differences.isNotEmpty) {
          _storeProblem(ordinal, 'differs after the store', '$differences');
        } else {
          storedStrategies++;
        }
    }
    final whole = MemoryStorage();
    final putting = await open(whole);
    if (folders.isNotEmpty) {
      await putting.editLibrary([
        for (final folder in _parentsFirst(folders))
          PutFolder(folderToRow(folder).row),
      ]);
    }
    final put = await putting.putStrategy(made.rows);
    final again = await putting.putStrategy(made.rows);
    await putting.close();
    if (put is! Saved<LibraryEdited, LibraryRefusal>) {
      _storeProblem(ordinal, 'not put', '$put');
    } else if (!const DeepCollectionEquality().equals(
      whole.contents,
      storage.contents,
    )) {
      _storeProblem(ordinal, 'put differs from add', 'stored bytes differ');
    } else if (again is! NothingToSave<LibraryEdited, LibraryRefusal>) {
      _storeProblem(ordinal, 'put again saved', '$again');
    } else {
      putStrategies++;
    }
  }

  void _addMade(StrategyRowsMade made) {
    for (final MapEntry(:key, :value) in made.summary.itemCounts.entries) {
      items[key] = items[key]! + value;
    }
    lineups += made.summary.lineupCount;
    supersededLegacyItems += made.supersededLegacyItems;
  }

  void addFolder(Folder folder) {
    folders++;
    final converted = folderToRow(folder);
    switch (folderFromRow(converted.row, converted.dateCreated)) {
      case FolderRefused(:final problems):
        for (final problem in problems) {
          count(refusals, 'folder: ${problem.runtimeType}');
        }
      case FolderMade(folder: final back):
        if (back.name != folder.name ||
            back.id != folder.id ||
            back.parentID != folder.parentID ||
            back.dateCreated != folder.dateCreated ||
            back.iconId != folder.iconId ||
            back.color != folder.color ||
            back.customColor?.toARGB32() != folder.customColor?.toARGB32()) {
          count(differences, 'folder');
        }
    }
  }

  String render({required bool detail}) => [
        'Hive stores: $stores, .ica files: $icaFiles',
        'strategies: $strategies, pages: $pages, folders: $folders',
        'items: ${[
          for (final MapEntry(:key, :value) in items.entries)
            '${key.name} $value'
        ].join(', ')}, lineups: $lineups',
        'strategies the same after the round trip: $sameStrategies',
        'strategies the same after a store on the memory engine: $storedStrategies',
        'strategies saved whole over an empty store with the bytes adding them '
            'writes, and saved again over their own image with nothing to save: '
            '$putStrategies',
        'items in superseded strategy-level lists: $supersededLegacyItems',
        'differences: ${differences.isEmpty ? 'none' : differences}',
        'refusals: ${refusals.isEmpty ? 'none' : refusals}',
        if (detail) ...details,
      ].join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  final corpus = Platform.environment[corpusVariable];
  test(
    'every strategy and folder in the corpus comes back the same',
    skip: corpus == null
        ? '$corpusVariable is not set: it names a folder of Hive stores '
            'and .ica files to check'
        : false,
    () async {
      final root = Directory(corpus!);
      expect(root.existsSync(), isTrue, reason: '$corpusVariable: $corpus');
      final report = CorpusReport();
      StrategyData? largest;
      int itemsOf(StrategyData strategy) => [
            for (final page in strategy.pages) ...pageItemsOf(page),
          ].length;
      for (final store in hiveStoresUnder(root)) {
        report.stores++;
        final library = await loadHiveStore(store);
        for (final strategy in library.strategies) {
          await report.addStrategy(strategy, folders: library.folders);
          if (largest == null || itemsOf(strategy) > itemsOf(largest)) {
            largest = strategy;
          }
        }
        library.folders.forEach(report.addFolder);
      }
      final icaFiles = icaFilesUnder(root);
      report.icaFiles = icaFiles.length;
      if (icaFiles.isNotEmpty) {
        for (final strategy in await importIcaFiles(icaFiles)) {
          await report.addStrategy(strategy);
        }
      }
      if (largest != null) {
        stdout.writeln(await _saveCost(largest, itemsOf(largest)));
      }
      final detail = Platform.environment[detailVariable] == '1';
      printOnFailure(report.render(detail: detail));
      // ignore: avoid_print
      print(report.render(detail: detail));
      expect(report.strategies + report.folders, greaterThan(0));
      expect(report.problemCount, 0);
    },
  );
}

bool _appReadsLineup(LineupGroupPayload payload) {
  final id = payload.data['id'];
  if (id is! String) return false;
  try {
    lineUpGraphFromCloudRows([
      CloudLineupRow(publicId: id, payload: payload.toJson()),
    ]);
    return true;
  } on FormatException {
    return false;
  }
}

List<Folder> _parentsFirst(List<Folder> folders) {
  final byId = {for (final folder in folders) folder.id: folder};
  final ordered = <Folder>[];
  final placed = <String>{};
  void place(Folder folder, Set<String> walking) {
    if (placed.contains(folder.id) || !walking.add(folder.id)) return;
    if (byId[folder.parentID] case final parent?) place(parent, walking);
    placed.add(folder.id);
    ordered.add(folder);
  }

  for (final folder in folders) {
    place(folder, <String>{});
  }
  return ordered;
}

Future<String> _saveCost(StrategyData strategy, int items) async {
  final folder = await Directory.systemTemp.createTemp('icarus-corpus-save-');
  try {
    final store = switch (await LibraryStore.open(
      SqliteEngine('${folder.path}/library.sqlite'),
      canRead: CanRead(
        element: (payload) => canReadElementPayload(payload, strategy.mapData),
        lineupGroup: (_) => true,
      ),
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };
    StrategyRowSet rowsOf(StrategyData model) =>
        (strategyToRows(model) as StrategyRowsMade).rows;
    final first = await store.putStrategy(rowsOf(strategy));
    final withAgents = [
      for (final page in strategy.pages)
        if (page.agentData.isNotEmpty) page.id,
    ];
    final notMeasured = switch (first) {
      Saved() when withAgents.isEmpty => 'no page holds an agent to move',
      Saved() => null,
      final other => 'the first save answered $other',
    };
    if (notMeasured != null) {
      await store.close();
      return 'largest strategy, $items items on ${strategy.pages.length} '
          'pages: save cost not measured, $notMeasured';
    }
    final convert = <int>[];
    final save = <int>[];
    var current = strategy;
    for (var run = 0; run < 25; run++) {
      final pageId = withAgents[run % withAgents.length];
      final moved = current.copyWith(pages: [
        for (final page in current.pages)
          page.id == pageId
              ? page.copyWith(agentData: [
                  for (final (index, agent) in page.agentData.indexed)
                    index == 0
                        ? PlacedAgentNode.fromJson({
                            ...agent.toJson(),
                            'position': {'dx': 100.0 + run, 'dy': 50.0},
                          })
                        : agent,
                ])
              : page,
      ]);
      final watch = Stopwatch()..start();
      final rows = rowsOf(moved);
      convert.add(watch.elapsedMicroseconds);
      final result = await store.putStrategy(rows);
      save.add(watch.elapsedMicroseconds);
      if (result is! Saved<LibraryEdited, LibraryRefusal>) {
        throw StateError('not saved: $result');
      }
      current = moved;
    }
    await store.close();
    int median(List<int> times) => (times..sort())[times.length ~/ 2];
    return 'largest strategy, $items items on ${strategy.pages.length} pages, '
        'one agent moved, saved whole on SQLite: convert ${median(convert)} us, '
        'convert + compare + commit ${median(save)} us (medians of 25)';
  } finally {
    await folder.delete(recursive: true);
  }
}
