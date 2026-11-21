import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

StrategyData numbered(int n) => generatedStrategy(Optionals.set).copyWith(
      id: 'strategy-$n',
      name: 'Strategy $n',
      folderID: 'folder-1',
    );

Folder folder() => Folder(
      name: 'Retakes',
      id: 'folder-1',
      dateCreated: DateTime(2025, 2, 3),
      color: FolderColor.red,
    );

Future<LibraryStore> openOn(MemoryStorage storage) =>
    openStoreOn(MemoryEngine(storage));

Future<StoreChecked> checkNow(LibraryStore store) async =>
    switch (await checkFromHive(store)) {
      final StoreChecked checked => checked,
      StoreNotChecked(:final failure) => throw StateError('$failure'),
    };

MemoryStorage edited(
  MemoryStorage storage,
  void Function(Map<String, Map<String, String>> contents) change,
) {
  final contents = {
    for (final MapEntry(:key, :value) in storage.contents.entries)
      key: {...value},
  };
  change(contents);
  return MemoryStorage(contents);
}

Box<StrategyData> get strategyBox =>
    Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-exactness-');
    await openScratchHive(
      directory,
      strategies: [numbered(1), numbered(2)],
      folders: [folder()],
    );
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<MemoryStorage> copied() async {
    final storage = MemoryStorage();
    final store = await openOn(storage);
    await copyFromHive(store);
    expect((await checkNow(store)).isExact, isTrue);
    await store.close();
    return storage;
  }

  test(
      'a row in the library area this build does not know makes the check not exact',
      () async {
    final storage = edited(await copied(), (contents) {
      contents['library']!['from-a-newer-build'] = '{"kept":true}';
    });
    final store = await openOn(storage);
    final check = await checkNow(store);
    expect(check.isExact, isFalse);
    expect(check.foreignNames.map((n) => n.name), ['from-a-newer-build']);
    await store.close();
  });

  test(
      'a field this build does not know on a stored folder makes the check not exact',
      () async {
    final storage = edited(await copied(), (contents) {
      final name = 'folder/${digestOf('folder-1')}';
      final row =
          jsonDecode(contents['library']![name]!) as Map<String, Object?>;
      contents['library']![name] = jsonEncode({...row, 'fromNewerBuild': 1});
    });
    final store = await openOn(storage);
    final check = await checkNow(store);
    expect(check.isExact, isFalse);
    expect(
        check.folderProblems.single,
        isA<FolderDiffers>()
            .having((f) => f.fields, 'fields', ['fromNewerBuild']));
    await store.close();
  });

  test(
      'a name this build does not know inside an otherwise identical strategy makes the check not exact',
      () async {
    final storage = edited(await copied(), (contents) {
      contents[strategyArea('strategy-1')]!['from-a-newer-build'] = '{}';
    });
    final store = await openOn(storage);
    final check = await checkNow(store);
    expect(check.isExact, isFalse);
    expect(
        check.notMirrored.single,
        isA<StrategyUnreadableInStore>().having(
            (c) => '${c.stored}', 'stored', contains('from-a-newer-build')));
    await store.close();
  });

  test(
      'a strategy put back in Hive while the copy runs is not removed from the store',
      () async {
    final storage = await copied();
    final gone = strategyBox.get('strategy-2')!;
    await strategyBox.delete('strategy-2');
    final store = await openOn(storage);
    var restored = false;
    final copy = await copyFromHive(
      store,
      breathe: () async {
        if (restored) return;
        restored = true;
        await strategyBox.put(gone.id, gone.copyWith());
      },
    );
    expect(
        copy, isA<ShadowCopyRaced>().having((c) => c.hiveWrites, 'writes', 1));
    expect(copy.strategies.whereType<StrategyRemovedWithHive>(), isEmpty);
    expect((await checkNow(store)).isExact, isTrue);
    await store.close();
  });
}
