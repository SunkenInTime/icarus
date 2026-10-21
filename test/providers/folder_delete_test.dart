import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:path/path.dart' as path;

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ProviderContainer container;

  Box<Folder> folders() => Hive.box<Folder>(HiveBoxNames.foldersBox);
  Box<StrategyData> strategies() =>
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

  Future<void> folder(String id, {String? parent}) => folders().put(
        id,
        Folder(
          id: id,
          name: id,
          parentID: parent,
          dateCreated: DateTime.utc(2026),
          iconId: 0,
          color: FolderColor.generic,
        ),
      );

  /// A strategy with an image file in its folder, as the app keeps one.
  Future<void> strategy(String id, {String? folder}) async {
    await strategies().put(
      id,
      StrategyData(
        id: id,
        name: id,
        mapData: MapValue.ascent,
        versionNumber: Settings.versionNumber,
        lastEdited: DateTime.utc(2026),
        folderID: folder,
        pages: const [],
      ),
    );
    final images = Directory(path.join(dir.path, id, 'images'));
    await images.create(recursive: true);
    await File(path.join(images.path, 'picture.png')).writeAsBytes([1]);
  }

  bool hasImages(String strategyId) =>
      Directory(path.join(dir.path, strategyId)).existsSync();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('folder_delete_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => dir.path);
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    container = ProviderContainer(overrides: [
      libraryWorkspaceProvider.overrideWith(_LocalWorkspace.new),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await dir.delete(recursive: true);
  });

  test('deleting a folder deletes its subfolders and their strategies',
      () async {
    await folder('maps');
    await folder('ascent', parent: 'maps');
    await folder('retakes', parent: 'ascent');
    await folder('bind');
    await strategy('maps-notes', folder: 'maps');
    await strategy('a-split', folder: 'ascent');
    await strategy('b-retake', folder: 'retakes');
    await strategy('bind-exec', folder: 'bind');
    await strategy('loose');
    await container.read(pinnedItemsProvider.notifier).togglePin('retakes');

    final result = await container
        .read(folderProvider.notifier)
        .deleteFolder('maps', workspace: LibraryWorkspace.local);

    expect(result.didSucceed, isTrue);
    expect(folders().keys, ['bind']);
    expect(strategies().keys, unorderedEquals(['bind-exec', 'loose']));
    for (final gone in ['maps-notes', 'a-split', 'b-retake']) {
      expect(hasImages(gone), isFalse, reason: gone);
    }
    expect(hasImages('bind-exec'), isTrue);
    expect(container.read(pinnedItemsProvider), isEmpty);
  });

  test('a subfolder moved out while the delete runs is kept', () async {
    await folder('maps');
    await strategy('a-maps-notes', folder: 'maps');
    await folder('ascent', parent: 'maps');
    await folder('retakes', parent: 'ascent');
    await strategy('a-split', folder: 'ascent');
    await strategy('b-retake', folder: 'retakes');
    final firstDelete = Completer<void>();
    final paused = ProviderContainer(overrides: [
      libraryWorkspaceProvider.overrideWith(_LocalWorkspace.new),
      strategyProvider.overrideWith(() => _PausedDelete(firstDelete.future)),
    ]);
    addTearDown(paused.dispose);

    final deleting = paused
        .read(folderProvider.notifier)
        .deleteFolder('maps', workspace: LibraryWorkspace.local);
    // The first strategy goes; while its files are removed, the dialog can
    // close and the user drags ascent to the top.
    final ascent = folders().get('ascent')!..parentID = null;
    await ascent.save();
    firstDelete.complete();

    expect((await deleting).didSucceed, isTrue);
    expect(folders().keys, unorderedEquals(['ascent', 'retakes']));
    expect(strategies().keys, unorderedEquals(['a-split', 'b-retake']));
    expect(hasImages('a-maps-notes'), isFalse);
    expect(hasImages('b-retake'), isTrue);
  });

  test('folders whose parent is gone show again, and nothing is deleted',
      () async {
    // What deleting "maps" used to leave: the folder and the strategies
    // directly in it went, its subfolders stayed.
    await folder('ascent', parent: 'maps');
    await folder('retakes', parent: 'ascent');
    await strategy('a-split', folder: 'ascent');
    await strategy('b-retake', folder: 'retakes');
    // An older import's folder, under a cloud parent that never arrived.
    await folder('imported', parent: 'cloud-folder');
    await strategy('imported-exec', folder: 'imported');
    // What the library already shows stays as it is.
    await folder('bind');
    await folder('sites', parent: 'bind');
    await strategy('bind-exec', folder: 'sites');
    await strategy('top-level', folder: 'maps');
    // No delete makes a parent loop; it is left alone.
    await folder('left', parent: 'right');
    await folder('right', parent: 'left');

    final shown = await showFoldersWithMissingParent(folders());

    expect(shown, 2);
    expect(
      {for (final f in folders().values) f.id: f.parentID},
      {
        'ascent': null,
        'retakes': 'ascent',
        'imported': null,
        'bind': null,
        'sites': 'bind',
        'left': 'right',
        'right': 'left',
      },
    );
    expect(
      strategies().keys,
      unorderedEquals(
        ['a-split', 'b-retake', 'imported-exec', 'bind-exec', 'top-level'],
      ),
    );
    for (final id in strategies().keys) {
      expect(hasImages(id as String), isTrue, reason: id);
    }
    expect(await showFoldersWithMissingParent(folders()), 0);
  });
}

/// Holds after the first strategy delete until [resume] completes, as a
/// slow removal of its image files would.
class _PausedDelete extends StrategyProvider {
  _PausedDelete(this.resume);

  final Future<void> resume;

  @override
  Future<CloudLibraryActionResult> deleteStrategy(
    String strategyID, {
    StrategySource? source,
  }) async {
    final result = await super.deleteStrategy(strategyID, source: source);
    await resume;
    return result;
  }
}

class _LocalWorkspace extends LibraryWorkspaceNotifier {
  @override
  LibraryWorkspace build() => LibraryWorkspace.local;
}
