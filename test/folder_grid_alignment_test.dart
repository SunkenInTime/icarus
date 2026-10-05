import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/folder_card.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('icarus_grid_alignment');
    Hive.init(hiveDir.path);
    registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);

    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
    final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    for (var i = 0; i < 9; i++) {
      final folder = Folder(
        name: 'Folder $i',
        id: 'folder-$i',
        dateCreated: DateTime.utc(2026, 1, 1 + i),
      );
      await folders.put(folder.id, folder);
      final strategy = StrategyData(
        id: 'strategy-$i',
        name: 'Strategy $i',
        mapData: MapValue.ascent,
        versionNumber: 1,
        lastEdited: DateTime.utc(2026, 2, 1 + i),
        folderID: null,
      );
      await strategies.put(strategy.id, strategy);
    }
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
    await hiveDir.delete(recursive: true);
  });

  for (final width in [1100.0, 1916.0]) {
    testWidgets('folders share the strategy grid columns at ${width}px',
        (tester) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authProvider.overrideWith(_SignedOutAuthProvider.new)],
          child: ShadApp(
            themeMode: ThemeMode.dark,
            darkTheme: ShadThemeData(
              brightness: Brightness.dark,
              colorScheme: Settings.tacticalVioletTheme,
            ),
            home: Material(
              child: FolderContent(onCreateStrategy: () {}),
            ),
          ),
        ),
      );
      await tester.pump();

      Set<(double, double)> columns(Finder cards) => {
            for (final element in cards.evaluate())
              (
                tester.getRect(find.byWidget(element.widget)).left,
                tester.getRect(find.byWidget(element.widget)).right,
              ),
          };

      final folderColumns = columns(find.byType(FolderCard));
      final strategyColumns = columns(find.byType(StrategyTile));

      expect(folderColumns, isNotEmpty);
      expect(folderColumns, strategyColumns);
    });
  }
}

/// Signed out: the library shows only what is on this computer.
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
