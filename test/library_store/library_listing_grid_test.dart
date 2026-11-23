import 'dart:async';
import 'dart:io';

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
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../library_rows/generated_strategies.dart';

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
    final shape = _withoutDrawings(generatedStrategy(Optionals.unset));
    for (final id in ['a-split', 'b-retake', 'c-default']) {
      await const LocalLibrary().addStrategy(
        shape.copyWith(id: id, name: 'Strategy $id'),
      );
    }
    await const LocalLibrary().addFolder(
      Folder(name: 'Plans', id: 'plans', dateCreated: DateTime.utc(2026)),
    );
  });

  tearDownAll(() => directory.deleteSync(recursive: true));

  testWidgets(
      'the mounted grid holds Hive rows until the start-up copy, store rows after it, and an edited tile moves to a store row once the mirror writes it',
      (tester) async {
    Completer<void>? gap;
    final mirror = StoreMirror(
      reads: HiveReads(),
      betweenAnimations: () => gap?.future ?? Future<void>.value(),
    );
    final listing = StoreLibraryListing(
      HiveLibraryListing(),
      clock: () => Duration.zero,
    )..follow(mirror);
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

    List<(String, bool)> tiles() => [
          for (final tile
              in tester.widgetList<StrategyTile>(find.byType(StrategyTile)))
            (
              tile.localStrategy!.name,
              listing.drewFromStore(tile.localStrategy!),
            ),
        ];
    List<bool> folderCards() => [
          for (final card
              in tester.widgetList<FolderCard>(find.byType(FolderCard)))
            listing.drewFromStore(card.data.folder),
        ];

    expect(tiles(), hasLength(3));
    expect(tiles().every((tile) => !tile.$2), isTrue);
    expect(folderCards(), [false]);

    await tester.runAsync(() async {
      final store = switch (await LibraryStore.open(
        MemoryEngine(MemoryStorage()),
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

    expect(listing.source, isA<ListFromStore>());
    expect(tiles(), [
      ('Strategy a-split', true),
      ('Strategy b-retake', true),
      ('Strategy c-default', true),
    ]);
    expect(folderCards(), [true]);

    gap = Completer<void>();
    await tester.runAsync(
      () => const LocalLibrary().renameStrategy('a-split', 'Renamed'),
    );
    await tester.pump();

    expect(tiles(), contains(('Renamed', false)));
    expect(tiles().where((tile) => tile.$1 != 'Renamed').every((t) => t.$2),
        isTrue);

    await tester.runAsync(() async {
      gap!.complete();
      gap = null;
      await mirror.drained();
    });
    await tester.pump();

    expect(tiles(), contains(('Renamed', true)));
    expect(tiles().every((tile) => tile.$2), isTrue);
  });
}
