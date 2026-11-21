import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';

StrategyData _strategy(String id, {String? folderId}) => StrategyData(
      id: id,
      name: id,
      mapData: MapValue.ascent,
      versionNumber: 1,
      lastEdited: DateTime.utc(2026),
      folderID: folderId,
      pages: const [],
    );

Folder _folder(String id) =>
    Folder(name: id, id: id, dateCreated: DateTime.utc(2026));

void main() {
  late Directory dir;
  late Box<StrategyData> strategies;
  late Box<Folder> folders;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('icarus-library-order-');
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    strategies = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    folders = await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await strategies.put('kept', _strategy('kept'));
    await strategies.put('filed', _strategy('filed', folderId: 'plans'));
    await folders.put('plans', _folder('plans'));
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a delete leaves the library before the caller awaits it', () async {
    final strategyGone = const LocalLibrary().deleteStrategy('kept');
    expect(strategies.containsKey('kept'), isFalse);
    final treeGone = const LocalLibrary().deleteFoldersWithStrategies(
      folderIds: ['plans'],
      strategyIds: ['filed'],
    );
    expect(strategies.containsKey('filed'), isFalse);
    expect(folders.containsKey('plans'), isFalse);
    expect(await strategyGone, isA<LibraryWritten>());
    expect(await treeGone, isA<LibraryWritten>());
  });

  test('a write to a closed box fails as a value and rethrows as before',
      () async {
    await strategies.close();
    final written = await const LocalLibrary().addStrategy(_strategy('new'));
    expect(written, isA<LibraryWriteFailed>());
    expect(written.orThrow, throwsA(isA<HiveError>()));
  });
}
