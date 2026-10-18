import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/replay_capture_queue_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/replay/replay_capture.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

import 'replay_test_support.dart';

ReplayFrame frame({Offset position = const Offset(500, 500)}) => ReplayFrame(
      timeMs: 1000,
      round: null,
      isAttack: false,
      agents: [
        PlacedViewConeAgent(
          id: 'replay-player-a',
          type: AgentType.jett,
          position: position,
          presetType: UtilityType.viewCone180,
          rotation: 1,
          length: 100,
        ),
      ],
      abilities: const [],
      utilities: const [],
    );

void main() {
  late Directory temp;
  late Box<StrategyData> box;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('icarus-replay-capture');
    Hive.init(temp.path);
    registerIcarusAdapters(Hive);
  });

  setUp(() async {
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await box.clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  group('signed out', () {
    ReplayCapture capture() => ReplayCapture(
          newStore: () => LocalReplayCaptureStore(createBlankStrategy),
          map: MapValue.sunset,
          name: 'Sunset replay',
        );

    test('captures fill one strategy, the first replacing its blank page',
        () async {
      final session = capture();
      await session.capture(frame(), pageName: 'Round 1 · 0:10');
      await session.capture(frame(), pageName: 'Round 1 · 0:20');

      final strategy = box.values.single;
      expect(strategy.name, 'Sunset replay');
      expect(strategy.mapData, MapValue.sunset);
      expect(strategy.pages.map((page) => page.name),
          ['Round 1 · 0:10', 'Round 1 · 0:20']);
      expect(strategy.pages.map((page) => page.sortIndex), [0, 1]);
      expect(strategy.pages.last.id, session.strategy!.lastPageId);
      expect(session.strategy!.pageCount, 2);
      final page = strategy.pages.first;
      expect(page.isAttack, isFalse);
      final agent = page.agentData.single as PlacedViewConeAgent;
      expect(agent.id, 'replay-player-a');
      expect(agent.position, const Offset(500, 500));
    });

    test('a deleted or re-mapped strategy is never written to again', () async {
      final session = capture();
      final first = await session.capture(frame(), pageName: 'one');
      await box.delete(first.id);

      final second = await session.capture(frame(), pageName: 'two');
      expect(second.id, isNot(first.id));
      expect(box.get(second.id)!.pages.single.name, 'two');

      await box.put(
        second.id,
        box.get(second.id)!.copyWith(mapData: MapValue.ascent),
      );
      final third = await session.capture(frame(), pageName: 'three');
      expect(third.id, isNot(second.id));
      expect(box.get(second.id)!.pages.single.name, 'two');
    });

    test('a frame off the map is refused before anything is written', () async {
      final session = capture();
      await expectLater(
        session.capture(
          frame(position: const Offset(double.nan, 0)),
          pageName: 'bad',
        ),
        throwsStateError,
      );
      expect(box.isEmpty, isTrue);
    });

    test('a utility turned by a non-finite angle is refused too', () async {
      final spike = PlacedUtility(
        id: 'replay-spike-0',
        type: UtilityType.spike,
        position: const Offset(500, 500),
      )..rotation = double.infinity;
      await expectLater(
        capture().capture(
          ReplayFrame(
            timeMs: 0,
            round: null,
            isAttack: true,
            agents: const [],
            abilities: const [],
            utilities: [spike],
          ),
          pageName: 'bad',
        ),
        throwsStateError,
      );
      expect(box.isEmpty, isTrue);
    });

    test('watching one player, a capture saves only their cone', () async {
      // Jett (Red) and Omen (Blue) standing apart, Omen watched.
      final document = ReplayDocument.fromBytes(icrp(
        {
          ...sampleJson(),
          'movement': {
            'a': {'offset': 0, 'count': 3},
            'b': {'offset': 3 * 24, 'count': 3},
          },
        },
        records: [
          for (var t = 0; t <= 2000; t += 1000) [t, 0, 0, 100, 90, 0],
          for (var t = 0; t <= 2000; t += 1000) [t, 600, 0, 100, 90, 0],
        ],
      ));
      final playback = ReplayPlayback(
        document: document,
        projection: ReplayMapProjection.forMapPath(document.match.mapPath)!,
        perspective: ReplayTeam.red,
      )
        ..seek(1500)
        ..watch('b');
      addTearDown(playback.dispose);

      await capture().capture(playback.freshFrame(), pageName: 'watching');

      final agents = box.values.single.pages.single.agentData;
      expect(agents, hasLength(2));
      expect(
        agents.whereType<PlacedViewConeAgent>().map((agent) => agent.id),
        [ReplayFrameBuilder.agentIdOf('b')],
      );
    });
  });

  group('destination', () {
    ProviderContainer container({
      required bool signedIn,
      List<CloudFolderEntry> folders = const [],
    }) {
      final container = ProviderContainer(overrides: [
        cloudFolderTreeProvider.overrideWith((ref) => Stream.value(folders)),
        isCloudWorkspaceAvailableProvider.overrideWithValue(signedIn),
        authProvider.overrideWith(_SignedOutAuth.new),
        cloudMediaAccountIdProvider
            .overrideWithValue(signedIn ? 'account-1' : null),
        // Offline: nothing is sent, so no server is needed.
        convexConnectionSnapshotProvider.overrideWithValue(false),
        convexConnectionProvider.overrideWith((ref) => Stream.value(false)),
        strategyProvider.overrideWith(_ClosedStrategy.new),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    setUp(() async {
      await (await Hive.openBox<String>(HiveBoxNames.replayCapturesBox))
          .clear();
      // New strategies take the user's default theme and page settings.
      await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    });

    test('signed in, a capture is on its way to the cloud library', () async {
      final signedIn = container(signedIn: true);
      final captured = await ReplayCapture(
        newStore: signedIn.read(replayCaptureStoreProvider),
        map: MapValue.sunset,
        name: 'r',
      ).capture(frame(), pageName: 'one');
      expect(captured.source, StrategySource.cloud);
      expect(
        signedIn.read(replayCaptureQueueProvider).captures.single.strategyId,
        captured.id,
      );
      expect(box.isEmpty, isTrue);
    });

    CloudFolderEntry folder(String id, String role) => (
          folder: Folder(name: id, id: id, dateCreated: DateTime(2026)),
          role: role,
          strategyCount: 0,
          mapPeeks: const [],
          agentTypes: const [],
        );

    Future<String?> folderOfCapture(String openFolder, String role) async {
      final signedIn = container(
        signedIn: true,
        folders: [folder(openFolder, role)],
      );
      final tree = signedIn.listen(cloudFolderTreeProvider, (_, __) {});
      addTearDown(tree.close);
      await signedIn.read(cloudFolderTreeProvider.future);
      signedIn
          .read(folderProvider.notifier)
          .updateWorkspaceFolderId(LibraryWorkspace.cloud, openFolder);
      await ReplayCapture(
        newStore: signedIn.read(replayCaptureStoreProvider),
        map: MapValue.sunset,
        name: 'r',
      ).capture(frame(), pageName: 'one');
      return signedIn.read(replayCaptureQueueProvider).captures.single.folderId;
    }

    test('it goes into the cloud folder open in My Library', () async {
      expect(await folderOfCapture('mine', 'owner'), 'mine');
    });

    test('never into a folder someone shared', () async {
      expect(await folderOfCapture('theirs', 'editor'), isNull);
    });

    test('signed out, it stays on this device', () {
      final store = container(signedIn: false).read(replayCaptureStoreProvider);
      expect(store(), isA<LocalReplayCaptureStore>());
    });
  });
}

class _ClosedStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: null,
        strategyName: null,
        source: StrategySource.local,
        isOpen: false,
      );
}

/// Auth that never asks Supabase; the queue only reads whether the cloud
/// user is ready.
class _SignedOutAuth extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );
}
