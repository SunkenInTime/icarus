import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/desktop_update_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/welcome_tour_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

class _EmptyDrawingProvider extends DrawingProvider {
  @override
  DrawingState build() => DrawingState(elements: const []);

  @override
  void rebuildAllPaths(CoordinateSystem coordinateSystem) {}
}

class _FixedPenProvider extends PenProvider {
  @override
  PenState build() => PenState(
        listOfColors: const [],
        color: Colors.white,
        hasArrow: false,
        isDotted: false,
        opacity: 1,
        thickness: 1,
        penMode: PenMode.freeDraw,
        traversalTimeEnabled: false,
        activeTraversalSpeedProfile: TraversalSpeedProfile.running,
        drawingCursor: null,
        erasingCursor: null,
      );
}

/// The editor's geometry: StrategyView's 40px window strip over the canvas.
class _Editor extends StatelessWidget {
  const _Editor();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Column(
          children: [
            SizedBox(height: 40),
            Expanded(child: InteractiveMap()),
          ],
        ),
      );
}

/// The editor opens on top of the library, so the library stays mounted
/// underneath and rebuilds whenever something it watches changes: a cloud
/// folder list update, a token refresh. Every placed item, lineup line and
/// stroke converts through [CoordinateSystem.instance]; a rebuild there must
/// not change the size they convert with.
void main() {
  late Directory tempDir;

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-coordinates-');
    Hive.init(tempDir.path);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
    await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  testWidgets('the library rebuilding under the editor keeps its coordinates',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
          authProvider.overrideWith(_SignedOut.new),
          appUpdateStatusProvider.overrideWith(
            (ref) async => const UpdateCheckResult(
              isSupported: false,
              isUpdateAvailable: false,
              source: 'test',
            ),
          ),
          desktopUpdateControllerProvider.overrideWithValue(null),
          welcomeTourLaunchCheckedProvider.overrideWith((ref) => true),
          cloudFolderTreeProvider.overrideWith(
            (_) => Stream.value(const <CloudFolderEntry>[]),
          ),
          cloudStrategiesProvider.overrideWith((_) => Stream.value(const [])),
          mapProvider.overrideWith(_FixedMapProvider.new),
          drawingProvider.overrideWith(_EmptyDrawingProvider.new),
          penProvider.overrideWith(_FixedPenProvider.new),
          effectiveMapThemePaletteProvider.overrideWith(
            (ref) => MapThemeProfilesProvider.immutableDefaultPalette,
          ),
        ],
        child: const ToastificationWrapper(
          child: ShadApp(home: FolderNavigator()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => const _Editor()));
    await tester.pumpAndSettle();

    final canvas = tester.getSize(find.byType(InteractiveMap));
    final editorSize = Size(canvas.height * 16 / 9, canvas.height);
    expect(CoordinateSystem.instance.playAreaSize, editorSize);

    tester
        .element(find.byType(FolderNavigator, skipOffstage: false))
        .markNeedsBuild();
    await tester.pump();

    expect(CoordinateSystem.instance.playAreaSize, editorSize);

    navigator.pop();
    await tester.pumpAndSettle();
  });
}
