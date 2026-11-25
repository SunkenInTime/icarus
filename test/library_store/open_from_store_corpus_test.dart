import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/library_store/store_page_reads.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/local_page_reads.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:path/path.dart' as path;

import '../library_rows/library_sources.dart';
import 'hive_scratch.dart';

const corpusVariable = 'ICARUS_LIBRARY_CORPUS';
const scratchVariable = 'ICARUS_LIBRARY_SCRATCH';
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
const _editedCaption = 'edited in the corpus run';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

enum _Opened { fromHive, fromStore }

enum _Pass { noEdit, oneEdit }

Uint8List _bytes(Object? value) {
  final writer = BinaryWriterImpl(Hive);
  writer.write(value);
  return writer.toBytes();
}

bool _same(Object? a, Object? b) =>
    const ListEquality<int>().equals(_bytes(a), _bytes(b));

final _epoch = DateTime.utc(2000);

List<String> differencesBetween(StrategyData hive, StrategyData store) {
  final kinds = <String>[];
  final fields = <String, (Object?, Object?)>{
    'name': (hive.name, store.name),
    'folderID': (hive.folderID, store.folderID),
    'mapData': (hive.mapData.index, store.mapData.index),
    'versionNumber': (hive.versionNumber, store.versionNumber),
    'createdAt': (
      hive.createdAt.microsecondsSinceEpoch,
      store.createdAt.microsecondsSinceEpoch
    ),
    'themeProfileId': (hive.themeProfileId, store.themeProfileId),
    'themeOverridePalette': (
      hive.themeOverridePalette,
      store.themeOverridePalette
    ),
    'page ids in stored order': (
      [for (final page in hive.pages) page.id],
      [for (final page in store.pages) page.id],
    ),
  };
  for (final MapEntry(:key, value: (a, b)) in fields.entries) {
    if (!_same(a, b)) kinds.add(key);
  }
  final storePages = {for (final page in store.pages) page.id: page};
  for (final page in hive.pages) {
    final other = storePages[page.id];
    if (other == null || _same(page, other)) continue;
    final pageFields = <String, (Object?, Object?)>{
      'page name': (page.name, other.name),
      'page sortIndex': (page.sortIndex, other.sortIndex),
      'page isAutoNamed': (page.isAutoNamed, other.isAutoNamed),
      'drawingData': (page.drawingData, other.drawingData),
      'agentData': (page.agentData, other.agentData),
      'abilityData': (page.abilityData, other.abilityData),
      'textData': (page.textData, other.textData),
      'imageData': (page.imageData, other.imageData),
      'utilityData': (page.utilityData, other.utilityData),
      'isAttack': (page.isAttack, other.isAttack),
      'settings': (page.settings, other.settings),
      'lineUpOrigins': (page.lineUpOrigins, other.lineUpOrigins),
      'lineUpLandings': (page.lineUpLandings, other.lineUpLandings),
      'lineUpLinks': (page.lineUpLinks, other.lineUpLinks),
    };
    var named = false;
    for (final MapEntry(:key, value: (a, b)) in pageFields.entries) {
      if (_same(a, b)) continue;
      named = true;
      final orderOnly = a is List &&
          b is List &&
          const UnorderedIterableEquality<String>().equals(
            [for (final x in a) String.fromCharCodes(_bytes(x))],
            [for (final x in b) String.fromCharCodes(_bytes(x))],
          );
      kinds.add(orderOnly ? '$key order' : key);
    }
    if (!named) kinds.add('page, in a field not named here');
  }
  if (kinds.isEmpty &&
      !_same(hive.copyWith(lastEdited: _epoch),
          store.copyWith(lastEdited: _epoch))) {
    kinds.add('strategy, in a field not named here');
  }
  return kinds;
}

Future<Directory> _scratchCopyOf(Directory store, Directory scratchRoot) async {
  final scratch = await scratchRoot.createTemp('open-from-store-');
  for (final file in store.listSync().whereType<File>()) {
    if (path.extension(file.path) == '.hive') {
      await file.copy(path.join(scratch.path, path.basename(file.path)));
    }
  }
  return scratch;
}

Future<void> _startAsTheAppDoes(Directory scratch) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProvider, (_) async => scratch.path);
  await openScratchHive(scratch);
  await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
  await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
  await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
  await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
  await MapThemeProfilesProvider.bootstrap();
  await StrategyMigrator.migrateAllStrategies();
  await moveOrphansToTopLevel(
    Hive.box<Folder>(HiveBoxNames.foldersBox),
    Hive.box<StrategyData>(HiveBoxNames.strategiesBox),
  );
}

final class CorpusOpens {
  var stores = 0;
  var strategies = 0;
  var pagesVisited = 0;
  var edited = 0;
  final served = <String, int>{};
  final differing = {for (final pass in _Pass.values) pass: 0};
  final kinds = {for (final pass in _Pass.values) pass: <String, int>{}};
  final details = <String>[];

  void count(Map<String, int> into, String key) =>
      into[key] = (into[key] ?? 0) + 1;

  String render() => [
        'stores $stores, strategies $strategies, pages visited per pass '
            '$pagesVisited, strategies the edit pass changed $edited',
        'loads in the store runs: '
            '${[
          for (final key in served.keys.toList()..sort()) '$key ${served[key]}'
        ].join(', ')}',
        for (final pass in _Pass.values)
          '${pass.name}: strategies whose Hive record differs between the '
              'Hive open and the store open ${differing[pass]}'
              '${kinds[pass]!.isEmpty ? '' : ', ${kinds[pass]}'}',
        ...details.take(100),
      ].join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CoordinateSystem(playAreaSize: const Size(1920, 1080));
  StorePageReads? reads;
  late final ProviderContainer container;
  setUpAll(() {
    container = ProviderContainer(overrides: [
      authProvider.overrideWith(_SignedOut.new),
      localPageReadsProvider.overrideWith((ref) => reads),
    ]);
    appProviderContainer = container;
  });

  Future<Map<String, StrategyData>> run(
    Directory corpusStore,
    Directory scratchRoot,
    _Opened opened,
    _Pass pass,
    CorpusOpens totals,
  ) async {
    final scratch = await _scratchCopyOf(corpusStore, scratchRoot);
    await _startAsTheAppDoes(scratch);
    final StoreMirror? mirror;
    LibraryStore? store;
    SqliteEngine? engine;
    switch (opened) {
      case _Opened.fromHive:
        mirror = null;
        reads = null;
      case _Opened.fromStore:
        final following = StoreMirror(
          reads: HiveReads(),
          betweenAnimations: () => Future<void>.value(),
        );
        mirror = following;
        LocalLibrary.follower = following;
        final file = libraryStoreFile(scratch.path);
        await file.parent.create(recursive: true);
        engine = SqliteEngine(file.path);
        store = await openStoreOn(engine);
        final writes = LibraryBoxWrites();
        await following.copyThenFollow(store, writes: writes);
        await writes.stop();
        reads = StorePageReads(following);
    }
    container.invalidate(localPageReadsProvider);
    final editor = container.read(strategyProvider.notifier);
    final ids = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .map((strategy) => strategy.id)
        .toSet()
        .toList()
      ..sort();
    for (final id in ids) {
      await mirror?.drained();
      if (!await editor.loadFromHive(id)) continue;
      if (pass == _Pass.oneEdit) {
        final agents = container.read(agentProvider);
        if (agents.isNotEmpty) {
          container
              .read(agentProvider.notifier)
              .setCaption(agents.first.id, _editedCaption);
          if (opened == _Opened.fromHive) totals.edited++;
        }
      }
      final pageIds =
          container.read(strategyPageSessionProvider).availablePageIds;
      for (final pageId in pageIds.skip(1)) {
        await editor.setActivePage(pageId);
      }
      if (opened == _Opened.fromHive && pass == _Pass.noEdit) {
        totals.pagesVisited += pageIds.length;
      }
      await editor.saveToHive(id);
    }
    await mirror?.drained();
    final records = {
      for (final strategy
          in Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values)
        strategy.id: strategy.copyWith(lastEdited: _epoch),
    };
    if (reads case final StorePageReads served) {
      for (final load in served.loads) {
        totals.count(
          totals.served,
          '${load.kind.name} ${switch (load.outcome) {
            ServedFromStore() => 'from the store',
            ServedFromHive(:final reason) => 'from Hive: ${reason.name}',
            GaveWay() => 'never shown',
            NoPageToShow() => 'no page to show',
            OpenFailed() => 'failed',
          }}',
        );
      }
    }
    reads = null;
    container.invalidate(localPageReadsProvider);
    LocalLibrary.follower = null;
    await store?.close();
    await engine?.close();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await scratch.delete(recursive: true);
    return records;
  }

  final corpus = Platform.environment[corpusVariable];
  test(
    'every strategy in the corpus, opened from the store, every page visited '
    'and saved, leaves Hive holding what the same steps leave after an open '
    'from Hive, with no edit and after one edit',
    skip: corpus == null
        ? '$corpusVariable names a folder of Hive stores'
        : false,
    timeout: const Timeout(Duration(hours: 1)),
    () async {
      final scratchRoot = await Directory(
        Platform.environment[scratchVariable] ?? Directory.systemTemp.path,
      ).createTemp('icarus-open-from-store-');
      addTearDown(() => scratchRoot.delete(recursive: true));
      final totals = CorpusOpens();
      for (final corpusStore in hiveStoresUnder(Directory(corpus!))) {
        totals.stores++;
        final label = path.relative(corpusStore.path, from: corpus);
        for (final pass in _Pass.values) {
          final hive = await run(
              corpusStore, scratchRoot, _Opened.fromHive, pass, totals);
          final stored = await run(
              corpusStore, scratchRoot, _Opened.fromStore, pass, totals);
          if (pass == _Pass.noEdit) totals.strategies += hive.length;
          for (final MapEntry(:key, value: fromHive) in hive.entries) {
            final fromStore = stored[key];
            final kinds = fromStore == null
                ? ['missing after the store run']
                : differencesBetween(fromHive, fromStore);
            if (kinds.isEmpty) continue;
            totals.differing[pass] = totals.differing[pass]! + 1;
            for (final kind in kinds) {
              totals.count(totals.kinds[pass]!, kind);
            }
            totals.details.add('${pass.name} $label $key: ${kinds.join(', ')}');
          }
        }
      }
      // ignore: avoid_print
      print(totals.render());
      final notFromStore = {
        for (final MapEntry(:key, :value) in totals.served.entries)
          if (key.startsWith('open from Hive')) key: value,
      };
      expect(notFromStore, isEmpty,
          reason: 'an open from Hive in the store run compares Hive with Hive');
      expect(totals.served['open from the store'], totals.strategies * 2);
      expect(totals.differing, {_Pass.noEdit: 0, _Pass.oneEdit: 0},
          reason: totals.render());
    },
  );
}
