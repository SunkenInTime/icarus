import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_rows/round_trip.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

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
    Future<LibraryStore> open(MemoryStorage storage) async => switch (
            await LibraryStore.open(MemoryEngine(storage), canRead: canRead)) {
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
        },
      );
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
      ...groups
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
      StrategyTimes(
        createdAt: made.summary.createdAt,
        lastEdited: made.summary.lastEdited,
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
            '${key.name} $value',
        ].join(', ')}, lineups: $lineups',
        'strategies the same after the round trip: $sameStrategies',
        'strategies the same after a store on the memory engine: $storedStrategies',
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
      for (final store in hiveStoresUnder(root)) {
        report.stores++;
        final library = await loadHiveStore(store);
        for (final strategy in library.strategies) {
          await report.addStrategy(strategy, folders: library.folders);
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
      CloudLineupRow(publicId: id, payload: payload.toPlainJson()),
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
