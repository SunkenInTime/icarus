import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/folder_card.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('icarus_empty_states');
    Hive.init(hiveDir.path);
    registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  });

  setUp(() async {
    await Hive.box<Folder>(HiveBoxNames.foldersBox).clear();
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
    await hiveDir.delete(recursive: true);
  });

  Future<void> pumpRoot(WidgetTester tester, VoidCallback onCreate) {
    return tester.pumpWidget(
      ProviderScope(
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: Material(child: FolderContent(onCreateStrategy: onCreate)),
        ),
      ),
    );
  }

  testWidgets('a view with only folders shows just the folders',
      (tester) async {
    await tester.runAsync(() async {
      final folder = Folder(
        name: 'Team',
        id: 'team',
        dateCreated: DateTime.utc(2026, 1, 1),
      );
      await Hive.box<Folder>(HiveBoxNames.foldersBox).put(folder.id, folder);
    });

    await pumpRoot(tester, () {});
    await tester.pump();

    expect(find.byType(FolderCard), findsOneWidget);
    expect(find.text('No strategies in this folder'), findsNothing);
    expect(find.text('No strategies yet'), findsNothing);
  });

  testWidgets('an empty view offers to create a strategy', (tester) async {
    var created = 0;
    await pumpRoot(tester, () => created++);
    await tester.pump();

    expect(find.text('No strategies yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-empty-new-strategy')));
    expect(created, 1);
  });
}
