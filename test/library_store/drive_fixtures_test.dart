import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

import '../library_rows/generated_strategies.dart';
import 'aged_summaries.dart';
import 'hive_scratch.dart';

final _notInStoreOut = Platform.environment['ICARUS_NOT_IN_STORE_FIXTURE'];
final _storeToAge = Platform.environment['ICARUS_AGE_STORE'];
final _smallOut = Platform.environment['ICARUS_SMALL_LIBRARY_FIXTURE'];
final _keptOut = Platform.environment['ICARUS_KEPT_ON_HIVE_FIXTURE'];
final _leftBehindOut = Platform.environment['ICARUS_LEFT_BEHIND_FIXTURE'];
final _storeHoldsOut =
    Platform.environment['ICARUS_STORE_HOLDS_LIBRARY_FIXTURE'];

const unreadableInStoreId = 'fixture-unreadable-in-store';
const newerBuildId = 'fixture-newer-build';

Future<void> writeNotInStoreFixture(
  Directory out, {
  bool withRefusals = true,
}) async {
  StrategyData withoutDrawings(StrategyData strategy) => strategy.copyWith(
        pages: [
          for (final page in strategy.pages)
            page.copyWith(drawingData: const []),
        ],
      );
  final full = withoutDrawings(generatedStrategy(Optionals.set));
  final bare = withoutDrawings(generatedStrategy(Optionals.unset));
  final folder = Folder(
    name: 'Retakes',
    id: 'fixture-folder',
    dateCreated: DateTime.utc(2026, 2, 1),
  );
  final strategies = [
    full.copyWith(
      id: 'fixture-kept-in-folder',
      name: 'Kept in a folder',
      folderID: folder.id,
    ),
    bare.copyWith(id: 'fixture-kept', name: 'Kept'),
    bare.copyWith(
      id: unreadableInStoreId,
      name: 'Unreadable in the store',
      mapData: MapValue.bind,
    ),
    bare.copyWith(
      id: newerBuildId,
      name: 'From a newer build',
      versionNumber: Settings.versionNumber + 1,
    ),
  ];
  await openScratchHive(
    out,
    strategies: withRefusals ? strategies : strategies.take(2),
    folders: [folder],
  );
  await Hive.close();
  if (!withRefusals) return;

  final file = libraryStoreFile(out.path);
  file.parent.createSync(recursive: true);
  final engine = SqliteEngine(file.path);
  final store = switch (await LibraryStore.open(engine, canRead: appCanRead)) {
    StoreOpened(:final store) => store,
    StoreNotOpened(:final problem) => fail('$problem'),
  };
  final rows = switch (strategyToRows(strategyAsHiveHoldsIt(strategies[2]))) {
    StrategyRowsMade(:final rows) => rows,
    StrategyRowsRefused(:final problems) => fail('$problems'),
  };
  expect(await store.putStrategy(rows), isA<Saved<LibraryEdited, Object>>());
  await store.close();
  final lease = switch (await engine.lease()) {
    Leased(:final lease) => lease,
    final other => fail('$other'),
  };
  expect(
    await lease.commit([
      Put(strategyArea(unreadableInStoreId), 'strategy', '{"publicId": "half'),
    ]),
    isA<CommitApplied>(),
  );
  await lease.release();
  await engine.close();
  expect(
    strategyToRows(strategyAsHiveHoldsIt(strategies[3])),
    isA<StrategyRowsRefused>(),
  );
}

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

Future<void> writeKeptOnHiveFixture(Directory out) async {
  final bare = generatedStrategy(Optionals.unset).copyWith(
    pages: [
      for (final page in generatedStrategy(Optionals.unset).pages)
        page.copyWith(drawingData: const []),
    ],
  );
  Folder folder(String id, String name) =>
      Folder(name: name, id: id, dateCreated: DateTime.utc(2026, 2, 1));
  await openScratchHive(
    out,
    strategies: [bare.copyWith(id: 'fixture-kept', name: 'Kept')],
    folders: [folder('fixture-retakes', 'Retakes')],
  );
  final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
  final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
  await strategies.put(
    1,
    bare.copyWith(id: 'fixture-numbered', name: 'Strategy under a number'),
  );
  await folders.put(0, folder('fixture-plans', 'Under a number'));
  await folders.put('fixture-plans', folder('fixture-plans', 'Under its id'));
  await folders.put(
    'fixture-alternate',
    folder('fixture-elsewhere', 'Under another key'),
  );
  await Hive.close();
}

void main() {
  test(
    'writes a library with records the store cannot name by id: a folder sharing its id with another, a folder and a strategy under integer keys, a folder under a key that is not its id',
    () async {
      final out = Directory(_keptOut!)..createSync(recursive: true);
      expect(out.listSync(), isEmpty, reason: 'give the fixture a new folder');
      await writeKeptOnHiveFixture(out);
    },
    skip: _keptOut == null
        ? 'set ICARUS_KEPT_ON_HIVE_FIXTURE to a new folder'
        : false,
  );

  test(
    'writes a library with a strategy the converter refuses and one the store cannot read',
    () async {
      final out = Directory(_notInStoreOut!)..createSync(recursive: true);
      expect(out.listSync(), isEmpty, reason: 'give the fixture a new folder');
      await writeNotInStoreFixture(out);
    },
    skip: _notInStoreOut == null
        ? 'set ICARUS_NOT_IN_STORE_FIXTURE to a new folder'
        : false,
  );

  test(
    'writes a small library the store holds whole, a folder and two strategies',
    () async {
      final out = Directory(_smallOut!)..createSync(recursive: true);
      expect(out.listSync(), isEmpty, reason: 'give the fixture a new folder');
      await writeNotInStoreFixture(out, withRefusals: false);
    },
    skip: _smallOut == null
        ? 'set ICARUS_SMALL_LIBRARY_FIXTURE to a new folder'
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
    'ages every summary in a store to the version the build before wrote',
    () async {
      final engine = SqliteEngine(_storeToAge!);
      final aged = await ageSummaries(engine);
      await engine.close();
      expect(aged, greaterThan(0));
      debugPrint('aged $aged summaries in $_storeToAge');
    },
    skip: _storeToAge == null
        ? 'set ICARUS_AGE_STORE to a scratch copy of a library store'
        : false,
  );
}
