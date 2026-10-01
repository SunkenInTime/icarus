import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/config/cloud_startup.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/desktop_update_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/startup/cloud_bootstrap.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

void main() {
  setUpAll(() {
    appProviderContainer = ProviderContainer();
    registerIcarusAdapters(Hive);
  });

  tearDownAll(() => appProviderContainer.dispose());

  group('startCloud', () {
    test('an outbox that will not open leaves the cloud off, unstarted',
        () async {
      var clientsStarted = false;
      final startup = await startCloud(
        openOutboxes: () async => throw HiveError('Wrong checksum'),
        initializeClients: () async => clientsStarted = true,
      );

      expect(startup.isAvailable, isFalse);
      expect(startup.unavailableReason, cloudOutboxUnavailableReason);
      expect(clientsStarted, isFalse);
    });

    test('clients that fail to start leave the cloud off', () async {
      final startup = await startCloud(
        openOutboxes: () async {},
        initializeClients: () async =>
            throw StateError('Failed to load the Convex library'),
      );

      expect(startup.isAvailable, isFalse);
      expect(startup.unavailableReason, cloudClientsUnavailableReason);
    });

    test('the cloud is up when every step succeeds', () async {
      final startup = await startCloud(
        openOutboxes: () async {},
        initializeClients: () async {},
      );

      expect(startup.isAvailable, isTrue);
    });
  });

  group('openCloudOutboxes', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('icarus-outbox-open-');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // A box that fails to open keeps its file handles until the process
        // exits, and Windows will not delete an open file.
      }
    });

    test('a corrupt outbox is kept byte for byte, not recovered', () async {
      // Two saved ops; the first one's bytes go bad on disk. Hive's crash
      // recovery would truncate the file there and drop both.
      final box = await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
      await box.put('first-op', 'x' * 200);
      await box.put('second-op', 'still unsent');
      await box.close();
      final file =
          File('${tempDir.path}/${HiveBoxNames.strategyOutboxBox}.hive');
      final bytes = file.readAsBytesSync();
      final firstValue = String.fromCharCodes(bytes).indexOf('x' * 200);
      expect(firstValue, isNonNegative);
      bytes[firstValue + 100] = 'y'.codeUnitAt(0);
      file.writeAsBytesSync(bytes);

      await expectLater(openCloudOutboxes(), throwsA(isA<HiveError>()));

      expect(file.readAsBytesSync(), bytes);
      expect(Hive.isBoxOpen(HiveBoxNames.strategyOutboxBox), isFalse);
    });
  });

  group('with the cloud off', () {
    late Directory tempDir;

    setUp(() async {
      AuthProvider.resetTestOverrides();
      tempDir = await Directory.systemTemp.createTemp('icarus-cloud-off-');
      Hive.init(tempDir.path);
      // The local library opened; the cloud outboxes did not.
      final strategies =
          await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
      await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
      await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
      await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      await MapThemeProfilesProvider.bootstrap();
      final at = DateTime(2026, 9, 1);
      await strategies.put(
        'local-plan',
        StrategyData(
          id: 'local-plan',
          name: 'Local Plan',
          mapData: MapValue.ascent,
          versionNumber: 1,
          folderID: null,
          pages: const [],
          createdAt: at,
          lastEdited: at,
        ),
      );
    });

    tearDown(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    testWidgets(
        'the local library opens and sign-in says why it is unavailable',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Real auth and queues: none of them may reach Supabase, Convex, or an
      // outbox box, since none of those exist in this run.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cloudStartupProvider.overrideWith(
              (ref) => const CloudStartup.unavailable(
                cloudOutboxUnavailableReason,
              ),
            ),
            platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
            appUpdateStatusProvider.overrideWith(
              (ref) async => const UpdateCheckResult(
                isSupported: false,
                isUpdateAvailable: false,
                source: 'test',
              ),
            ),
            desktopUpdateControllerProvider.overrideWithValue(null),
          ],
          child: const ToastificationWrapper(
            child: ShadApp(home: FolderNavigator()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // What MyApp reads at startup comes up without throwing.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FolderNavigator)),
      );
      expect(container.read(strategyOpQueueProvider).durableLoaded, isTrue);
      expect(container.read(cloudMediaUploadQueueProvider).jobs, isEmpty);
      expect(container.read(authProvider).isAuthenticated, isFalse);

      expect(find.text('Local Plan'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('library-account-action')));
      await tester.pumpAndSettle();
      expect(find.byType(AuthDialog), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('auth-discord-button')));
      await tester.pumpAndSettle();
      expect(find.text(cloudOutboxUnavailableReason), findsOneWidget);
    });
  });
}
