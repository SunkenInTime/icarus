import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/round_trip.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
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
  int supersededLegacyItems = 0;
  final differences = <String, int>{};
  final refusals = <String, int>{};
  final details = <String>[];

  int get problemCount =>
      differences.values.fold(0, (sum, count) => sum + count) +
      refusals.values.fold(0, (sum, count) => sum + count);

  void count(Map<String, int> into, String key) =>
      into[key] = (into[key] ?? 0) + 1;

  void addStrategy(StrategyData strategy) {
    final ordinal = strategies++;
    pages += strategy.pages.length;
    final result = roundTrip(strategy);
    switch (result) {
      case RoundTripSame(:final made):
        sameStrategies++;
        _addMade(made);
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
        library.strategies.forEach(report.addStrategy);
        library.folders.forEach(report.addFolder);
      }
      final icaFiles = icaFilesUnder(root);
      report.icaFiles = icaFiles.length;
      if (icaFiles.isNotEmpty) {
        (await importIcaFiles(icaFiles)).forEach(report.addStrategy);
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
