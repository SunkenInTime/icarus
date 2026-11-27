import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

import '../library_rows/generated_strategies.dart';
import 'aged_summaries.dart';
import 'hive_scratch.dart';

final _resultsToMakeNewer = Platform.environment['ICARUS_NEWER_RESULTS_STORE'];
final _leftBehindOut = Platform.environment['ICARUS_LEFT_BEHIND_FIXTURE'];
final _sixtyDrawingsOut =
    Platform.environment['ICARUS_SIXTY_DRAWINGS_FIXTURE'];
final _storeHoldsOut =
    Platform.environment['ICARUS_STORE_HOLDS_LIBRARY_FIXTURE'];

const newerBuildId = 'fixture-newer-build';

Future<void> writeLeftBehindFixture(Directory out) async {
  final bare = generatedStrategy(Optionals.unset).copyWith(
    pages: [
      for (final page in generatedStrategy(Optionals.unset).pages)
        page.copyWith(drawingData: const []),
    ],
  );
  final folder = Folder(
    name: 'Retakes',
    id: 'fixture-folder',
    dateCreated: DateTime.utc(2026, 2, 1),
  );
  final newer = bare.copyWith(
    id: newerBuildId,
    name: 'From a newer build',
    versionNumber: Settings.versionNumber + 1,
  );
  await openScratchHive(
    out,
    strategies: [
      bare.copyWith(
        id: 'fixture-moved-in-folder',
        name: 'Moved in a folder',
        folderID: folder.id,
      ),
      bare.copyWith(id: 'fixture-moved', name: 'Moved'),
      newer,
    ],
    folders: [folder],
  );
  await Hive.close();
  expect(strategyToRows(strategyAsHiveHoldsIt(newer)), isA<StrategyRowsRefused>());
}

Future<void> writeStoreHoldsLibraryFixture(Directory out) async {
  await writeLeftBehindFixture(out);
  final file = libraryStoreFile(out.path);
  file.parent.createSync(recursive: true);
  final engine = SqliteEngine(file.path);
  final store = switch (await LibraryStore.open(engine, canRead: appCanRead)) {
    StoreOpened(:final store) => store,
    StoreNotOpened(:final problem) => fail('$problem'),
  };
  expect(
    await store.editLibrary([
      PutFolder(ReadableFolder(
        publicId: 'fixture-already-here',
        name: 'Already here',
        createdAt: DateTime.utc(2026, 2, 1),
      )),
    ]),
    isA<Saved<LibraryEdited, Object>>(),
  );
  await store.close();
  await engine.close();
}

Future<void> writeSixtyDrawingsFixture(Directory out) async {
  final parts = [
    for (var index = 0; index < 40; index++)
      generatedPage(
        id: 'part-$index',
        sortIndex: index,
        optionals: Optionals.set,
        isAttack: true,
        itemPrefix: 'sixty-$index',
      ),
  ];
  final page = parts.first.copyWith(
    drawingData: [
      for (final part in parts) ...part.drawingData,
    ].take(60).toList(),
    agentData: [for (final part in parts.take(3)) ...part.agentData],
    abilityData: [for (final part in parts.take(3)) ...part.abilityData],
    imageData: const [],
  );
  final strategy = generatedStrategy(Optionals.unset).copyWith(
    id: 'fixture-sixty-drawings',
    name: 'Sixty drawings',
    pages: [page],
  );
  await openScratchHive(out, strategies: [strategy]);
  await Hive.close();
}

void main() {
  test(
    'writes a library of one strategy whose page holds sixty drawings',
    () async {
      final out = Directory(_sixtyDrawingsOut!)..createSync(recursive: true);
      expect(out.listSync(), isEmpty, reason: 'give the fixture a new folder');
      await writeSixtyDrawingsFixture(out);
    },
    skip: _sixtyDrawingsOut == null
        ? 'set ICARUS_SIXTY_DRAWINGS_FIXTURE to a new folder'
        : false,
  );

  test(
    'writes a library of two strategies and a folder that move into the store, '
    'and one from a newer build that stays behind',
    () async {
      final out = Directory(_leftBehindOut!)..createSync(recursive: true);
      expect(out.listSync(), isEmpty, reason: 'give the fixture a new folder');
      await writeLeftBehindFixture(out);
    },
    skip: _leftBehindOut == null
        ? 'set ICARUS_LEFT_BEHIND_FIXTURE to a new folder'
        : false,
  );

  test(
    'writes that library beside a store that already holds a folder and has '
    'no record of a copy',
    () async {
      final out = Directory(_storeHoldsOut!)..createSync(recursive: true);
      expect(out.listSync(), isEmpty, reason: 'give the fixture a new folder');
      await writeStoreHoldsLibraryFixture(out);
    },
    skip: _storeHoldsOut == null
        ? 'set ICARUS_STORE_HOLDS_LIBRARY_FIXTURE to a new folder'
        : false,
  );

  test(
    'writes the stored page list results of every cloud strategy in a store '
    'as a newer build would, in a shape this build cannot read',
    () async {
      final engine = SqliteEngine(_resultsToMakeNewer!);
      final changed = await resultsAsANewerBuildWroteThem(engine);
      await engine.close();
      expect(changed, greaterThan(0));
      debugPrint('made $changed stored results newer in $_resultsToMakeNewer');
    },
    skip: _resultsToMakeNewer == null
        ? 'set ICARUS_NEWER_RESULTS_STORE to a scratch copy of a library store'
        : false,
  );
}
