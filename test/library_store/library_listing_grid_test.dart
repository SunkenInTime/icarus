import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_listing.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/folder_card.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../library_rows/generated_strategies.dart';
import 'gated_engine.dart';

StrategyData _withoutDrawings(StrategyData strategy) => strategy.copyWith(
      pages: [
        for (final page in strategy.pages) page.copyWith(drawingData: const []),
      ],
    );

final class _SignedOutAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );
}

final class _ReadMode {
  _ReadMode(this.tester, this.gate, this.mirror, this.listing);

  final WidgetTester tester;
  final CommitGate gate;
  final StoreMirror mirror;
  final StoreLibraryListing listing;
  Completer<void>? gap;

  List<(String, bool)> tiles() => [
        for (final tile
            in tester.widgetList<StrategyTile>(find.byType(StrategyTile)))
          (
            tile.localStrategy!.name,
            listing.drewFromStore(tile.localStrategy!),
          ),
      ];

  List<(String, bool)> folderCards() => [
        for (final card
            in tester.widgetList<FolderCard>(find.byType(FolderCard)))
          (card.data.folder.name, listing.drewFromStore(card.data.folder)),
      ];

  Future<void> copy() async {
    await tester.runAsync(() async {
      final store = switch (await LibraryStore.open(
        GatedEngine(MemoryEngine(MemoryStorage()), gate),
        canRead: appCanRead,
      )) {
        StoreOpened(:final store) => store,
        StoreNotOpened(:final problem) => fail('$problem'),
      };
      final writes = LibraryBoxWrites();
      await mirror.copyThenFollow(store, writes: writes);
      await writes.stop();
    });
    await tester.pump();
  }

  Future<void> drained() async {
    await tester.runAsync(mirror.drained);
    await tester.pump();
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Box<Folder> get _folders => Hive.box<Folder>(HiveBoxNames.foldersBox);

Future<void> _openEdit(WidgetTester tester, String folder) async {
  await tester.tap(find.text(folder), buttons: kSecondaryButton);
  await _settle(tester);
  await tester.tap(find.text('Edit'));
  await _settle(tester);
  expect(find.byType(FolderEditDialog), findsOneWidget);
}

Folder? _recordInTheDialog(WidgetTester tester) {
  final Object? local =
      tester.widget<FolderEditDialog>(find.byType(FolderEditDialog)).local;
  return switch (local) {
    HiveFolderRecord(:final folder) => folder,
    _ => null,
  };
}

Future<void> _save(WidgetTester tester, String rename) async {
  await tester.enterText(
    find
        .descendant(
          of: find.byType(FolderEditDialog),
          matching: find.byType(EditableText),
        )
        .first,
    rename,
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
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await _settle(tester);
}

void _expectSavedAndClosed(WidgetTester tester) =>
    expect(find.byType(FolderEditDialog), findsNothing);

void _expectRefusedAndOpen(WidgetTester tester) {
  expect(find.byType(FolderEditDialog), findsOneWidget);
  expect(find.text("Couldn't save this folder. Try again."), findsOneWidget);
}

Future<void> _waitUntil(WidgetTester tester, bool Function() done) =>
    tester.runAsync(() async {
      for (var wait = 0; wait < 500 && !done(); wait++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(done(), isTrue);
    });

Folder _folder(String id, String name) =>
    Folder(name: name, id: id, dateCreated: DateTime.utc(2026));

Future<void> _rename(WidgetTester tester, String id, String name) =>
    tester.runAsync(
      () => const LocalLibrary().renameStrategy(
        const LocalLibrary().storedStrategy(id)!,
        name,
      ),
    );

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('icarus-grid-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<_ReadMode> readMode(
    WidgetTester tester, {
    Map<Object, Folder>? folders,
  }) async {
    await tester.runAsync(() async {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();
      await _folders.clear();
      final shape = _withoutDrawings(generatedStrategy(Optionals.unset));
      for (final id in ['a-split', 'b-retake', 'c-default']) {
        await const LocalLibrary().addStrategy(
          shape.copyWith(id: id, name: 'Strategy $id'),
        );
      }
      await _folders.putAll(folders ?? {'plans': _folder('plans', 'Plans')});
    });
    late final _ReadMode mode;
    final gate = CommitGate();
    final mirror = StoreMirror(
      reads: HiveReads(),
      betweenAnimations: () => mode.gap?.future ?? Future<void>.value(),
    );
    final listing = StoreLibraryListing(
      HiveLibraryListing(),
      clock: () => Duration.zero,
    )..follow(mirror);
    mode = _ReadMode(tester, gate, mirror, listing);
    LocalLibrary.follower = mirror;
    addTearDown(() => LocalLibrary.follower = null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_SignedOutAuthProvider.new),
          localLibraryListingProvider.overrideWithValue(listing),
        ],
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: Material(child: FolderContent(onCreateStrategy: () {})),
        ),
      ),
    );
    await tester.pump();
    return mode;
  }

  testWidgets(
      'the mounted grid holds Hive rows until the start-up copy, store rows after it, and an edited tile holds a Hive row while its write waits and while its commit is in flight, then a store row',
      (tester) async {
    final mode = await readMode(tester);

    expect(mode.tiles(), hasLength(3));
    expect(mode.tiles().every((tile) => !tile.$2), isTrue);
    expect(mode.folderCards(), [('Plans', false)]);

    await mode.copy();

    expect(mode.listing.source, isA<ListFromStore>());
    expect(mode.tiles(), [
      ('Strategy a-split', true),
      ('Strategy b-retake', true),
      ('Strategy c-default', true),
    ]);
    expect(mode.folderCards(), [('Plans', true)]);

    mode.gap = Completer<void>();
    mode.gate.hold();
    await _rename(tester, 'a-split', 'Renamed');
    await tester.pump();

    expect(mode.tiles(), contains(('Renamed', false)));
    expect(
      mode.tiles().where((tile) => tile.$1 != 'Renamed').every((t) => t.$2),
      isTrue,
    );

    final commitsBefore = mode.gate.commits;
    mode.gap!.complete();
    mode.gap = null;
    await _waitUntil(tester, () => mode.gate.commits > commitsBefore);
    await _rename(tester, 'b-retake', 'Renamed during the commit');
    await tester.pump();

    expect(mode.tiles(), [
      ('Renamed', false),
      ('Renamed during the commit', false),
      ('Strategy c-default', true),
    ]);

    mode.gate.release();
    await mode.drained();

    expect(mode.tiles(), [
      ('Renamed', true),
      ('Renamed during the commit', true),
      ('Strategy c-default', true),
    ]);
  });

  testWidgets(
      'when the store\'s worker exits while the mirror is idle the grid keeps store rows that equal Hive, and the next save moves the list to Hive with the new value',
      (tester) async {
    final mode = await readMode(tester);
    await mode.copy();
    await mode.drained();

    mode.gate.ended = true;
    await tester.pump();

    expect(mode.tiles(), [
      ('Strategy a-split', true),
      ('Strategy b-retake', true),
      ('Strategy c-default', true),
    ]);
    expect(
      [
        for (final strategy
            in Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values)
          strategy.name,
      ],
      ['Strategy a-split', 'Strategy b-retake', 'Strategy c-default'],
    );

    await _rename(tester, 'a-split', 'Renamed');
    await mode.drained();

    expect(mode.mirror.phase, isA<MirrorStopped>());
    expect(mode.listing.source, isA<ListFromHive>());
    expect(mode.tiles(), [
      ('Renamed', false),
      ('Strategy b-retake', false),
      ('Strategy c-default', false),
    ]);
  });

  testWidgets(
      'Edit on a folder card drawn from the store hands the dialog the Hive record under its id, and Done renames that record',
      (tester) async {
    final mode = await readMode(tester);
    await mode.copy();
    expect(mode.folderCards(), [('Plans', true)]);

    await _openEdit(tester, 'Plans');
    expect(_recordInTheDialog(tester), same(_folders.get('plans')));
    await _save(tester, 'Retakes');

    _expectSavedAndClosed(tester);
    expect(_folders.get('plans')!.name, 'Retakes');
  });

  testWidgets(
      'Edit on a folder card drawn from Hive in read mode hands the dialog the record the card was copied from',
      (tester) async {
    final mode = await readMode(tester);
    expect(mode.folderCards(), [('Plans', false)]);
    final card = tester.widget<FolderCard>(find.byType(FolderCard));
    expect(identical(card.data.folder, _folders.get('plans')), isFalse);

    await _openEdit(tester, 'Plans');
    expect(_recordInTheDialog(tester), same(_folders.get('plans')));
    await _save(tester, 'Retakes');

    _expectSavedAndClosed(tester);
    expect(_folders.get('plans')!.name, 'Retakes');
  });

  testWidgets(
      'Edit on a folder card drawn from the store whose folder Hive removes while the dialog is open fails as main does, with the dialog open',
      (tester) async {
    final mode = await readMode(tester);
    await mode.copy();
    expect(mode.folderCards(), [('Plans', true)]);

    await _openEdit(tester, 'Plans');
    await tester.runAsync(() => const LocalLibrary().deleteFolder('plans'));
    await _save(tester, 'Retakes');

    _expectRefusedAndOpen(tester);
    expect(_folders.containsKey('plans'), isFalse);
  });

  testWidgets(
      'Edit on a folder card drawn from the store whose Hive record is replaced while the dialog is open fails as main does and leaves the replacement alone',
      (tester) async {
    final mode = await readMode(tester);
    await mode.copy();
    expect(mode.folderCards(), [('Plans', true)]);

    await _openEdit(tester, 'Plans');
    await tester.runAsync(
      () => const LocalLibrary().addFolder(_folder('plans', 'Replacement')),
    );
    await _save(tester, 'Retakes');

    _expectRefusedAndOpen(tester);
    expect(_folders.get('plans')!.name, 'Replacement');
  });

  testWidgets(
      'two folders sharing an id, under an integer key and under the id, are drawn from Hive, and Edit on the one under the integer key renames that one',
      (tester) async {
    final mode = await readMode(
      tester,
      folders: {
        0: _folder('plans', 'Under a number'),
        'plans': _folder('plans', 'Under its id'),
      },
    );
    await mode.copy();
    expect(mode.listing.source, isA<ListFromStore>());
    expect(
        mode.folderCards(),
        unorderedEquals([
          ('Under a number', false),
          ('Under its id', false),
        ]));

    await _openEdit(tester, 'Under a number');
    expect(_recordInTheDialog(tester), same(_folders.get(0)));
    await _save(tester, 'Renamed');

    _expectSavedAndClosed(tester);
    expect(_folders.get(0)!.name, 'Renamed');
    expect(_folders.get('plans')!.name, 'Under its id');
  });

  testWidgets(
      'a folder under a key that is not its id, and another folder stored under that id, are drawn from Hive, and Edit on the first renames the first',
      (tester) async {
    final mode = await readMode(
      tester,
      folders: {
        'alternate': _folder('plans', 'Plans elsewhere'),
        'plans': _folder('other', 'Other'),
      },
    );
    await mode.copy();
    expect(mode.listing.source, isA<ListFromStore>());
    expect(
        mode.folderCards(),
        unorderedEquals([
          ('Plans elsewhere', false),
          ('Other', false),
        ]));

    await _openEdit(tester, 'Plans elsewhere');
    expect(_recordInTheDialog(tester), same(_folders.get('alternate')));
    await _save(tester, 'Renamed');

    _expectSavedAndClosed(tester);
    expect(_folders.get('alternate')!.name, 'Renamed');
    expect(_folders.get('plans')!.name, 'Other');
  });

  testWidgets(
      'Edit opened on a card drawn from Hive and saved after the list has moved to the store renames the record the card was copied from',
      (tester) async {
    final mode = await readMode(tester);
    expect(mode.folderCards(), [('Plans', false)]);

    await _openEdit(tester, 'Plans');
    await mode.copy();
    expect(mode.listing.source, isA<ListFromStore>());
    await _save(tester, 'Retakes');

    _expectSavedAndClosed(tester);
    expect(_folders.get('plans')!.name, 'Retakes');
  });

  testWidgets(
      'Edit opened on a card drawn from the store and saved after the list fell back to Hive with the record replaced fails as main does',
      (tester) async {
    final mode = await readMode(tester);
    await mode.copy();
    await mode.drained();
    expect(mode.folderCards(), [('Plans', true)]);

    await _openEdit(tester, 'Plans');
    mode.gate.ended = true;
    await tester.runAsync(
      () => const LocalLibrary().addFolder(_folder('plans', 'Replacement')),
    );
    await mode.drained();
    expect(mode.listing.source, isA<ListFromHive>());
    await _save(tester, 'Retakes');

    _expectRefusedAndOpen(tester);
    expect(_folders.get('plans')!.name, 'Replacement');
  });
}
