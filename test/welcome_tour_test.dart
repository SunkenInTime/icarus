import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/release_notes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/desktop_update_provider.dart';
import 'package:icarus/providers/release_notes_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/welcome_tour_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/dialogs/release_notes_dialog.dart';
import 'package:icarus/widgets/dialogs/welcome_tour/welcome_tour_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Writes AppPreferences the way builds before the welcome tour did, so
/// field 20 is absent on disk.
class _PreTourPreferencesAdapter extends TypeAdapter<AppPreferences> {
  @override
  final typeId = 28;

  @override
  AppPreferences read(BinaryReader reader) => throw UnimplementedError();

  @override
  void write(BinaryWriter writer, AppPreferences obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.defaultThemeProfileIdForNewStrategies)
      ..writeByte(19)
      ..write(obj.backgroundDotOpacity);
  }
}

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

class _SignedIn extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

/// Keeps the seen flag in memory: a Hive write started inside a widget
/// test's fake clock never finishes. The first test covers the real write.
class _MemoryPreferences extends AppPreferencesNotifier {
  @override
  AppPreferences build() => AppPreferences(
        defaultThemeProfileIdForNewStrategies:
            MapThemeProfilesProvider.immutableDefaultProfileId,
      );

  @override
  Future<void> markWelcomeTourSeen() async {
    state = state.copyWith(welcomeTourSeen: true);
  }
}

/// Stands in for the library screen: asks for the tour after its first
/// frame, as FolderNavigator does.
class _Library extends StatefulWidget {
  const _Library();

  @override
  State<_Library> createState() => _LibraryState();
}

class _LibraryState extends State<_Library> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => showWelcomeTourAtLaunch(context),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  late Directory tempDir;

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-welcome-tour-');
    Hive.init(tempDir.path);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('preferences saved before the tour existed have not seen it', () async {
    await Hive.close();
    Hive.registerAdapter(_PreTourPreferencesAdapter(), override: true);
    var box =
        await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await box.put(
      MapThemeProfilesProvider.appPreferencesSingletonKey,
      AppPreferences(
        defaultThemeProfileIdForNewStrategies: 'profile-from-old-build',
        backgroundDotOpacity: 0.4,
      ),
    );
    await Hive.close();

    Hive.registerAdapter(AppPreferencesAdapter(), override: true);
    box = await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    final restored =
        box.get(MapThemeProfilesProvider.appPreferencesSingletonKey)!;
    expect(restored.defaultThemeProfileIdForNewStrategies,
        'profile-from-old-build');
    expect(restored.backgroundDotOpacity, 0.4);
    expect(restored.welcomeTourSeen, isFalse);

    // Once marked, it stays seen across a restart.
    var container = ProviderContainer();
    await container.read(appPreferencesProvider.notifier).markWelcomeTourSeen();
    container.dispose();
    await Hive.close();
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(appPreferencesProvider).welcomeTourSeen, isTrue);
  });

  ProviderContainer containerFor({
    bool signedIn = false,
    bool updateAvailable = false,
    bool launchOpensFile = false,
  }) {
    final container = ProviderContainer(overrides: [
      authProvider.overrideWith(signedIn ? _SignedIn.new : _SignedOut.new),
      appUpdateStatusProvider.overrideWith(
        (ref) async => UpdateCheckResult(
          isSupported: true,
          isUpdateAvailable: updateAvailable,
          source: 'test',
        ),
      ),
      desktopUpdateControllerProvider.overrideWithValue(null),
      appPreferencesProvider.overrideWith(_MemoryPreferences.new),
      releaseNotesProvider.overrideWith((ref) async => <ReleaseNotesEntry>[]),
    ]);
    container.read(launchOpensFileOrLinkProvider.notifier).state =
        launchOpensFile;
    return container;
  }

  Future<void> pumpApp(
    WidgetTester tester,
    ProviderContainer container,
    Widget home,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A fresh tree, so the stand-in library mounts again as at a launch.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder button(String label) => find.widgetWithText(ShadButton, label);

  testWidgets('first launch on an empty library shows the two-step tour, once',
      (tester) async {
    final container = containerFor();
    addTearDown(container.dispose);
    await pumpApp(tester, container, const _Library());

    expect(find.byKey(const ValueKey('welcome-tour')), findsOneWidget);
    // Nothing to reassure about, so it opens on the account step.
    expect(button('Sign in'), findsOneWidget);
    expect(button('Not now'), findsOneWidget);
    expect(button('Back'), findsNothing);
    expect(find.bySemanticsLabel('Step 2 of 2'), findsOneWidget);
    expect(container.read(appPreferencesProvider).welcomeTourSeen, isTrue);

    await tester.tap(button('Not now'));
    await tester.pumpAndSettle();
    expect(button('Open Replays'), findsOneWidget);
    expect(button('Back'), findsOneWidget);

    await tester.tap(button('Done'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('welcome-tour')), findsNothing);

    // The library screen built again in the same run asks nothing twice.
    await pumpApp(tester, container, const _Library());
    expect(find.byKey(const ValueKey('welcome-tour')), findsNothing);
  });

  testWidgets('a seen tour, a waiting update, or an opened file put it off',
      (tester) async {
    for (final container in [
      containerFor(updateAvailable: true),
      containerFor(launchOpensFile: true),
    ]) {
      addTearDown(container.dispose);
      await pumpApp(tester, container, const _Library());
      expect(find.byKey(const ValueKey('welcome-tour')), findsNothing);
      // Not seen, so the next plain launch still shows it.
      expect(container.read(appPreferencesProvider).welcomeTourSeen, isFalse);

      // The library built again later in the same run doesn't change that:
      // the tour waits for a launch of its own.
      container.read(launchOpensFileOrLinkProvider.notifier).state = false;
      await pumpApp(tester, container, const _Library());
      expect(find.byKey(const ValueKey('welcome-tour')), findsNothing);
    }

    final seen = containerFor();
    addTearDown(seen.dispose);
    seen.read(appPreferencesProvider.notifier).markWelcomeTourSeen();
    await pumpApp(tester, seen, const _Library());
    expect(find.byKey(const ValueKey('welcome-tour')), findsNothing);
  });

  testWidgets(
      'with existing work it opens on the library step; signed in, '
      'the account step only offers Next', (tester) async {
    await tester.runAsync(() async {
      await Hive.box<Folder>(HiveBoxNames.foldersBox).put(
        'f1',
        Folder(name: 'Scrims', id: 'f1', dateCreated: DateTime(2026)),
      );
    });
    final container = containerFor(signedIn: true);
    addTearDown(container.dispose);
    await pumpApp(tester, container, const _Library());

    expect(find.bySemanticsLabel('Step 1 of 3'), findsOneWidget);
    expect(button('Back'), findsNothing);
    await tester.tap(button('Next'));
    await tester.pumpAndSettle();
    expect(button('Back'), findsOneWidget);
    expect(button('Sign in'), findsNothing);
    expect(button('Not now'), findsNothing);
    expect(button('Next'), findsOneWidget);

    // Dots jump straight to a step.
    await tester.tap(find.bySemanticsLabel('Step 1 of 3'));
    await tester.pumpAndSettle();
    expect(button('Back'), findsNothing);
  });

  testWidgets("What's new leads back to the tour", (tester) async {
    final container = containerFor();
    addTearDown(container.dispose);
    container.read(appPreferencesProvider.notifier).markWelcomeTourSeen();
    await pumpApp(
      tester,
      container,
      Builder(
        builder: (context) => Center(
          child: ShadButton(
            onPressed: () => ReleaseNotesDialog.show(context),
            child: const Text('open notes'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show the welcome tour'));
    await tester.pumpAndSettle();

    expect(find.text("What's new"), findsNothing);
    expect(find.byKey(const ValueKey('welcome-tour')), findsOneWidget);
  });
}
