import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/dialogs/strategy/rename_strategy_dialog.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/library_breadcrumb.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'library_rows/generated_strategies.dart';

Box<StrategyData> get _strategies =>
    Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

Box<Folder> get _folders => Hive.box<Folder>(HiveBoxNames.foldersBox);

Folder _folder(String id, {String? name, String? parent}) => Folder(
      name: name ?? 'Folder $id',
      id: id,
      dateCreated: DateTime.utc(2026),
      parentID: parent,
    );

StrategyData _strategy(String id, {String? folder}) =>
    generatedStrategy(Optionals.unset).copyWith(
      id: id,
      name: 'Strategy $id',
      mapData: MapValue.bind,
      folderID: folder,
    );

enum _Record { live, missing, replaced }

Future<void> _inRealTime(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  await tester.runAsync(() async {
    await action();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _seed() async {
  const library = LocalLibrary();
  for (final id in ['source', 'destination', 'removed']) {
    await library.addFolder(_folder(id));
  }
  await library.addStrategy(_strategy('split'));
}

Future<void> _make(_Record record,
    {String? strategyId, String? folderId}) async {
  const library = LocalLibrary();
  switch (record) {
    case _Record.live:
      return;
    case _Record.missing:
      if (strategyId != null) await library.deleteStrategy(strategyId);
      if (folderId != null) await library.deleteFolder(folderId);
    case _Record.replaced:
      if (strategyId != null) {
        await library.addStrategy(_strategy(strategyId));
      }
      if (folderId != null) await library.addFolder(_folder(folderId));
  }
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ShadApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pump();
}

Future<void> _drag(
  WidgetTester tester, {
  required Folder destination,
  required Future<void> Function() whileHeld,
}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(const ValueKey('drag-source'))),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.moveBy(const Offset(20, 0));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.text(destination.name)));
  await tester.pump();
  await tester.runAsync(whileHeld);
  await tester.pump();
  await _inRealTime(tester, gesture.up);
}

Widget _dragScene(GridItem item, Folder destination) => Column(
      children: [
        Draggable<GridItem>(
          data: item,
          feedback: const SizedBox(width: 10, height: 10),
          child: const SizedBox(
            key: ValueKey('drag-source'),
            width: 80,
            height: 40,
            child: Text('drag me'),
          ),
        ),
        const SizedBox(height: 80),
        FolderTab(
          folder: destination,
          store: LibraryWorkspace.local,
          onOpen: () {},
        ),
      ],
    );

Future<void> _openEditFromCard(WidgetTester tester, String name) async {
  await tester.tap(find.text(name), buttons: kSecondaryButton);
  await _settle(tester);
  await tester.tap(find.text('Edit'));
  await _settle(tester);
  expect(find.byType(FolderEditDialog), findsOneWidget);
}

Future<void> _saveEdit(WidgetTester tester, String name) async {
  await tester.enterText(
    find
        .descendant(
          of: find.byType(FolderEditDialog),
          matching: find.byType(EditableText),
        )
        .first,
    name,
  );
  await tester.runAsync(
    () => tester.tap(find.byKey(const ValueKey('folder-edit-submit'))),
  );
  bool answered() =>
      find.byType(FolderEditDialog).evaluate().isEmpty ||
      find.text("Couldn't save this folder. Try again.").evaluate().isNotEmpty;
  for (var wait = 0; wait < 250 && !answered(); wait++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await _inRealTime(tester, () async {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late ProviderContainer container;
  setUpAll(() async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    directory = await Directory.systemTemp.createTemp('icarus-actions-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => directory.path,
    );
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOutAuthProvider.new)],
    );
    appProviderContainer = container;
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> start(WidgetTester tester,
      [Future<void> Function() seed = _seed]) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await _strategies.clear();
      await _folders.clear();
      await seed();
    });
  }

  Future<void> pumpLibrary(WidgetTester tester) => _pump(
        tester,
        container,
        FolderContent(onCreateStrategy: () {}),
      );

  for (final record in _Record.values) {
    testWidgets('renaming a strategy from its dialog, ${record.name} record',
        (tester) async {
      await start(tester);
      await _pump(
        tester,
        container,
        const RenameStrategyDialog(
          strategyId: 'split',
          currentName: 'Strategy split',
          source: StrategySource.local,
        ),
      );
      await tester.runAsync(() => _make(record, strategyId: 'split'));
      await tester.enterText(find.byType(EditableText), 'B split');
      await _inRealTime(tester, () => tester.tap(find.text('Rename')));

      expect(
        _strategies.get('split')?.name,
        switch (record) {
          _Record.live || _Record.replaced => 'B split',
          _Record.missing => null,
        },
      );
    });

    testWidgets(
        'dragging a strategy onto a folder crumb, ${record.name} record',
        (tester) async {
      await start(tester);
      final destination = _folders.get('destination')!;
      await _pump(
        tester,
        container,
        _dragScene(StrategyItem.local('split'), destination),
      );
      await _drag(
        tester,
        destination: destination,
        whileHeld: () => _make(record, strategyId: 'split'),
      );

      expect(
        _strategies.get('split')?.folderID,
        switch (record) {
          _Record.live || _Record.replaced => 'destination',
          _Record.missing => null,
        },
      );
    });

    testWidgets('dragging a folder onto a folder crumb, ${record.name} record',
        (tester) async {
      await start(tester);
      final source = _folders.get('source')!;
      final destination = _folders.get('destination')!;
      await _pump(
        tester,
        container,
        _dragScene(
            FolderItem(source, store: LibraryWorkspace.local), destination),
      );
      await _drag(
        tester,
        destination: destination,
        whileHeld: () => _make(record, folderId: 'source'),
      );

      expect(
        _folders.get('source')?.parentID,
        switch (record) {
          _Record.live || _Record.replaced => 'destination',
          _Record.missing => null,
        },
      );
      expect(_folders.containsKey('source'), record != _Record.missing);
    });

    testWidgets(
        'saving a folder from its card\'s Edit dialog, ${record.name} record',
        (tester) async {
      await start(tester);
      await pumpLibrary(tester);
      await _openEditFromCard(tester, 'Folder source');
      await tester.runAsync(() => _make(record, folderId: 'source'));
      await _saveEdit(tester, 'Retakes');

      switch (record) {
        case _Record.live:
          expect(_folders.get('source')!.name, 'Retakes');
          expect(find.byType(FolderEditDialog), findsNothing);
        case _Record.missing:
          expect(_folders.containsKey('source'), isFalse);
          expect(find.byType(FolderEditDialog), findsOneWidget);
          expect(find.text("Couldn't save this folder. Try again."),
              findsOneWidget);
        case _Record.replaced:
          expect(_folders.get('source')!.name, 'Folder source');
          expect(find.byType(FolderEditDialog), findsOneWidget);
          expect(find.text("Couldn't save this folder. Try again."),
              findsOneWidget);
      }
    });
  }

  testWidgets(
      'a folder edit dialog handed an object Hive has already replaced fails and stays open',
      (tester) async {
    await start(tester);
    final stale = _folders.get('source')!;
    await tester.runAsync(() => _make(_Record.replaced, folderId: 'source'));
    await _pump(tester, container, FolderEditDialog(folder: stale));
    await _saveEdit(tester, 'Retakes');

    expect(_folders.get('source')!.name, 'Folder source');
    expect(find.byType(FolderEditDialog), findsOneWidget);
    expect(find.text("Couldn't save this folder. Try again."), findsOneWidget);
  });

  testWidgets(
      'a strategy dropped on a crumb whose folder is removed while it is held is filed under the removed folder, as main does (#708)',
      (tester) async {
    await start(tester);
    final removed = _folders.get('removed')!;
    await _pump(
        tester, container, _dragScene(StrategyItem.local('split'), removed));
    await _drag(
      tester,
      destination: removed,
      whileHeld: () => const LocalLibrary().deleteFolder('removed'),
    );

    expect(_folders.containsKey('removed'), isFalse);
    expect(_strategies.get('split')!.folderID, 'removed');
  });

  testWidgets(
      'a folder dropped on a crumb whose folder is removed while it is held is moved under the removed folder, as main does (#708)',
      (tester) async {
    await start(tester);
    final source = _folders.get('source')!;
    final removed = _folders.get('removed')!;
    await _pump(
      tester,
      container,
      _dragScene(FolderItem(source, store: LibraryWorkspace.local), removed),
    );
    await _drag(
      tester,
      destination: removed,
      whileHeld: () => const LocalLibrary().deleteFolder('removed'),
    );

    expect(_folders.containsKey('removed'), isFalse);
    expect(_folders.get('source')!.parentID, 'removed');
  });

  group('two folders sharing an id under different keys', () {
    Future<void> seed() async {
      await _folders.put('destination', _folder('destination'));
      await _folders.put('shared', _folder('shared', name: 'Under its id'));
      await _folders.put('elsewhere', _folder('shared', name: 'Elsewhere'));
    }

    testWidgets('Edit from the card stored under the other key saves that one',
        (tester) async {
      await start(tester, seed);
      await pumpLibrary(tester);
      await _openEditFromCard(tester, 'Elsewhere');
      await _saveEdit(tester, 'Renamed');

      expect(_folders.get('elsewhere')!.name, 'Renamed');
      expect(_folders.get('shared')!.name, 'Under its id');
      expect(find.byType(FolderEditDialog), findsNothing);
    });

    testWidgets(
        'dragging the one stored under the other key moves the one stored under its id',
        (tester) async {
      await start(tester, seed);
      final elsewhere = _folders.get('elsewhere')!;
      final destination = _folders.get('destination')!;
      await _pump(
        tester,
        container,
        _dragScene(
          FolderItem(elsewhere, store: LibraryWorkspace.local),
          destination,
        ),
      );
      await _drag(tester, destination: destination, whileHeld: () async {});

      expect(_folders.get('elsewhere')!.parentID, isNull);
      expect(_folders.get('shared')!.parentID, 'destination');
    });
  });

  group('records under integer keys', () {
    late int folderKey;
    late int strategyKey;

    Future<void> seed() async {
      await _folders.put('destination', _folder('destination'));
      folderKey = await _folders.add(_folder('numbered', name: 'Numbered'));
      strategyKey = await _strategies.add(_strategy('numbered-strategy'));
    }

    testWidgets('Edit from the card saves the folder under its integer key',
        (tester) async {
      await start(tester, seed);
      await pumpLibrary(tester);
      await _openEditFromCard(tester, 'Numbered');
      await _saveEdit(tester, 'Renamed');

      expect(_folders.get(folderKey)!.name, 'Renamed');
      expect(_folders.containsKey('numbered'), isFalse);
      expect(find.byType(FolderEditDialog), findsNothing);
    });

    testWidgets('dragging the folder onto a crumb moves nothing',
        (tester) async {
      await start(tester, seed);
      final numbered = _folders.get(folderKey)!;
      final destination = _folders.get('destination')!;
      await _pump(
        tester,
        container,
        _dragScene(
          FolderItem(numbered, store: LibraryWorkspace.local),
          destination,
        ),
      );
      await _drag(tester, destination: destination, whileHeld: () async {});

      expect(_folders.get(folderKey)!.parentID, isNull);
      expect(_folders.containsKey('numbered'), isFalse);
    });

    testWidgets('renaming the strategy from its dialog renames nothing',
        (tester) async {
      await start(tester, seed);
      await _pump(
        tester,
        container,
        const RenameStrategyDialog(
          strategyId: 'numbered-strategy',
          currentName: 'Strategy numbered-strategy',
          source: StrategySource.local,
        ),
      );
      await tester.enterText(find.byType(EditableText), 'Renamed');
      await _inRealTime(tester, () => tester.tap(find.text('Rename')));

      expect(_strategies.get(strategyKey)!.name, 'Strategy numbered-strategy');
      expect(_strategies.containsKey('numbered-strategy'), isFalse);
    });

    testWidgets('dragging the strategy onto a crumb moves nothing',
        (tester) async {
      await start(tester, seed);
      final destination = _folders.get('destination')!;
      await _pump(
        tester,
        container,
        _dragScene(StrategyItem.local('numbered-strategy'), destination),
      );
      await _drag(tester, destination: destination, whileHeld: () async {});

      expect(_strategies.get(strategyKey)!.folderID, isNull);
      expect(_strategies.containsKey('numbered-strategy'), isFalse);
    });

    for (final stringKeyTaken in [false, true]) {
      testWidgets(
          'the start-up repair puts records under integer keys whose parent is gone at the top level, ${stringKeyTaken ? 'with another folder under the key\'s string form' : 'with nothing under the key\'s string form'}',
          (tester) async {
        late int orphanKey;
        late int strategyKey;
        await start(tester, () async {
          await _folders.put('destination', _folder('destination'));
          orphanKey = await _folders.add(
            _folder('orphan', name: 'Orphan', parent: 'gone'),
          );
          strategyKey = await _strategies.add(
            _strategy('orphan-strategy', folder: 'gone'),
          );
          if (stringKeyTaken) {
            await _folders.put(
              '$orphanKey',
              _folder('other', name: 'Other', parent: 'destination'),
            );
          }
        });

        final moved = await tester.runAsync(
          () => moveOrphansToTopLevel(),
        );

        expect(moved, (folders: 1, strategies: 1));
        expect(_folders.get(orphanKey)!.parentID, isNull);
        expect(_strategies.get(strategyKey)!.folderID, isNull);
        if (stringKeyTaken) {
          expect(_folders.get('$orphanKey')!.parentID, 'destination');
        } else {
          expect(_folders.containsKey('$orphanKey'), isFalse);
        }
      });
    }
  });
}

class _SignedOutAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );
}
