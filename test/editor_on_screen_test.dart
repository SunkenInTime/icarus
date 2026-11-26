import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:flutter/gestures.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/agents.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_drawing.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_capture.dart';
import 'package:icarus/providers/collab/replay_capture_queue_provider.dart';
import 'package:icarus/collab/replay_capture_record.dart';
import 'package:icarus/strategy/open_attempt.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:flutter/foundation.dart';
import 'package:icarus/widgets/community/open_community_post.dart';
import 'package:icarus/widgets/community/community_post_view.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy_view.dart';
import 'package:window_manager/window_manager.dart';

import 'editor_on_screen_support.dart';
import 'replay_test_support.dart';
import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _HeldSaves extends StrategyProvider {
  Completer<void>? held;
  var cancels = 0;
  final saved = <String>[];

  @override
  void cancelPendingSave() {
    cancels += 1;
    super.cancelPendingSave();
  }

  @override
  Future<bool> flushPendingAutosaveBeforeExit() async => false;

  @override
  Future<void> forceSaveNow(String id) async {
    saved.add(id);
    if (held case final held?) return held.future;
    return super.forceSaveNow(id);
  }
}

List<bool> _preventClose(List<MethodCall> calls) => [
      for (final call in calls)
        if (call.method == 'setPreventClose')
          (call.arguments as Map)['isPreventClose'] as bool,
    ];

Future<void> _stored(String id) async {
  final strategy = generatedStrategy(Optionals.set).copyWith(id: id, name: id);
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(strategy.id, strategy);
}

final _cloudReady = StateProvider<bool?>((ref) => null);

final class _HeldPost implements CommunityRepository {
  final asked = <String>[];
  final _held = Completer<void>();

  void release() => _held.complete();

  @override
  Future<({CommunityPost post, CommunityPostStatus status})?> fetchPost(
    String postPublicId,
  ) async {
    asked.add(postPublicId);
    await _held.future;
    return (post: _post(postPublicId), status: CommunityPostStatus.listed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final class _CloudCaptures implements ReplayCaptureStore {
  static const captured = (
    id: 'captured-cloud',
    name: 'Captured',
    map: MapValue.ascent,
    source: StrategySource.cloud,
    pageCount: 1,
    lastPageId: 'captured-page',
    lastPageIsAttack: true,
  );

  @override
  Future<CapturedStrategy> create(
    MapValue map,
    String name,
    CapturedPage page,
  ) async =>
      captured;

  @override
  Future<CapturedStrategy?> append(
    CapturedStrategy strategy,
    CapturedPage page,
  ) async =>
      captured;

  @override
  Future<CapturedStrategy?> find(CapturedStrategy strategy) async => captured;
}

final class _LandingCaptures extends ReplayCaptureQueue {
  @override
  ReplayCaptureQueueState build() => const ReplayCaptureQueueState();

  void waitFor(String strategyId, String pageId) =>
      state = ReplayCaptureQueueState(captures: [
        ReplayCaptureRecord(
          id: 'capture',
          accountId: 'account-a',
          strategyId: strategyId,
          clientId: 'client',
          strategyName: 'Captured',
          mapData: 'ascent',
          folderId: null,
          themeProfileId: null,
          index: 0,
          createsStrategy: true,
          createdAt: DateTime(2026, 11, 26),
          pageId: pageId,
          pageName: 'Round 1',
          isAttack: true,
          settings: const {},
          pageOpId: 'op',
          items: const [],
        ),
      ]);

  void land() => state = const ReplayCaptureQueueState();
}

final class _HeldPages extends StrategyPageSessionNotifier {
  final held = <String, Completer<void>>{};
  final fails = <String>{};

  @override
  Future<void> initializeForStrategy({
    required String strategyId,
    required StrategySource source,
    required bool selectFirstPageIfNeeded,
    String? preferredPageId,
    OpenAttempt? attempt,
  }) async {
    if (held[strategyId] case final hold?) await hold.future;
    if (fails.contains(strategyId)) {
      throw StateError('The pages of $strategyId could not be read.');
    }
    return super.initializeForStrategy(
      strategyId: strategyId,
      source: source,
      selectFirstPageIfNeeded: selectFirstPageIfNeeded,
      preferredPageId: preferredPageId,
      attempt: attempt,
    );
  }
}

final class _ReadsItsHeader extends RemoteEditorSnapshotNotifier {
  static final held = <String, Completer<void>>{};

  @override
  Future<RemoteEditorSnapshot?> build() => SynchronousFuture(null);

  @override
  Future<void> openStrategy(
    String strategyPublicId, {
    String? activePagePublicId,
  }) async {
    if (held[strategyPublicId] case final hold?) await hold.future;
    final at = DateTime.utc(2026);
    state = AsyncData(RemoteEditorSnapshot(
      shell: RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: strategyPublicId,
          name: strategyPublicId,
          mapData: Maps.mapNames[MapValue.ascent]!,
          revision: 1,
          createdAt: at,
          updatedAt: at,
        ),
        pages: const [],
      ),
      activePage: null,
    ));
  }

  @override
  void clear() => state = const AsyncData(null);
}

Finder _leaveButton() => find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_LeaveButton');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final strategies = _HeldSaves();
  final posts = _HeldPost();
  final pages = _HeldPages();
  final captures = _LandingCaptures();
  final container = ProviderContainer(overrides: [
    replayCaptureStoreProvider.overrideWithValue(_CloudCaptures.new),
    replayCaptureQueueProvider.overrideWith(() => captures),
    strategyPageSessionProvider.overrideWith(() => pages),
    remoteEditorSnapshotProvider.overrideWith(_ReadsItsHeader.new),
    communityRepositoryProvider.overrideWithValue(posts),
    authProvider.overrideWith(_SignedOut.new),
    strategyProvider.overrideWith(() => strategies),
    cloudWorkspaceOutcomeProvider.overrideWith((ref) => ref.watch(_cloudReady)),
  ]);
  appProviderContainer = container;
  container.read(strategyProvider);
  late Directory disk;
  setUpAll(() async => disk = await openUnitHive());
  tearDown(() => strategies.held = null);
  tearDownAll(Hive.close);

  testWidgets(
      'the window keeps asking before it closes while an editor is on '
      'screen, also after an editor that gave way left', (tester) async {
    await tester.runAsync(() async {
      await _stored('first');
      await _stored('second');
    });
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    final navigator = appNavigatorKey.currentState!;

    for (final id in ['first', 'second']) {
      expect(
        StrategyView.open(
          navigator,
          asked: strategies.askedByTheUserNow(),
          initialStrategyId: id,
          initialStrategyName: id,
        ),
        isA<Pushed>(),
      );
    }
    await settleWithDisk(tester);

    expect(container.read(strategyProvider).strategyId, 'second');
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    expect(_preventClose(windowCalls), [true]);

    await leaveEditors(tester, container);
    expect(_preventClose(windowCalls), [true, false]);
  });

  testWidgets(
      'a window close whose Save ends after another strategy opened asks '
      'again instead of closing over it', (tester) async {
    await tester.runAsync(() async {
      await _stored('asked-about');
      await _stored('opened-since');
    });
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'asked-about',
        initialStrategyName: 'asked-about',
      ),
      isA<Pushed>(),
    );
    await settleWithDisk(tester);
    container.read(strategySaveStateProvider.notifier).markDirty();
    final held = strategies.held = Completer<void>();

    (tester.state(find.byType(StrategyView)) as WindowListener).onWindowClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(
      await tester.runAsync(() => strategies.openLocal('opened-since',
          asked: strategies.askedByTheUserNow())),
      isA<Changed>(),
    );
    container.read(strategySaveStateProvider.notifier).markDirty();
    windowCalls.clear();
    held.complete();
    strategies.held = null;
    await settleWithDisk(tester);

    expect(container.read(strategyProvider).strategyId, 'opened-since');
    expect(container.read(strategySaveStateProvider).isDirty, isTrue);
    expect(_preventClose(windowCalls), isEmpty);
    expect(windowCalls.map((call) => call.method), ['close']);
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a late editor push gives way whether it arrives while the wanted '
      'editor waits for its first frame or after it opened, and the wanted '
      'one opens', (tester) async {
    await tester.runAsync(() async {
      await _stored('wanted');
      await _stored('late');
    });
    await pumpLibraryWithEditors(tester, container);
    final navigator = appNavigatorKey.currentState!;
    final lateAsked = strategies.askedByTheUserNow();

    expect(
      StrategyView.open(
        navigator,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'wanted',
        initialStrategyName: 'wanted',
      ),
      isA<Pushed>(),
    );
    final beforeItsFirstFrame = StrategyView.open(
      navigator,
      asked: lateAsked,
      initialStrategyId: 'late',
      initialStrategyName: 'late',
    );
    await settleWithDisk(tester);

    expect(beforeItsFirstFrame, isA<Refused>());
    expect(container.read(strategyProvider).strategyId, 'wanted');
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);

    final afterItOpened = StrategyView.open(
      navigator,
      asked: lateAsked,
      initialStrategyId: 'late',
      initialStrategyName: 'late',
    );
    await settleWithDisk(tester);

    expect(afterItOpened, isA<Refused>());
    expect(container.read(strategyProvider).strategyId, 'wanted');
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    await leaveEditors(tester, container);
  });

  for (final staleBeforeItsFirstFrame in [true, false]) {
    testWidgets(
        staleBeforeItsFirstFrame
            ? 'a cloud editor whose answer went stale before its first frame '
                'leaves at once, while the cloud is not ready yet'
            : 'a cloud editor whose answer went stale while it waited for the '
                'cloud leaves without saying the strategy failed to load',
        (tester) async {
      container.read(_cloudReady.notifier).state = null;
      await pumpLibraryWithEditors(tester, container);
      expect(
        StrategyView.open(
          appNavigatorKey.currentState!,
          asked: strategies.askedByTheUserNow(),
          initialStrategyId: 'cloud-strategy',
          initialStrategyName: 'cloud-strategy',
          initialStrategySource: StrategySource.cloud,
        ),
        isA<Pushed>(),
      );
      if (!staleBeforeItsFirstFrame) await tester.pump();
      expect(strategies.closeStrategy(asked: strategies.askedByTheUserNow()),
          isA<Changed>());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      if (!staleBeforeItsFirstFrame) {
        container.read(_cloudReady.notifier).state = true;
        await settleWithDisk(tester);
      }

      expect(find.byType(StrategyView, skipOffstage: false), findsNothing);
      expect(find.text('Could not load strategy.'), findsNothing);
      container.read(_cloudReady.notifier).state = null;
      await leaveEditors(tester, container);
    });
  }

  testWidgets(
      'a quick switch whose Save ends after another strategy opened leaves '
      'that strategy open, with its tool and its edit, and the edit saves',
      (tester) async {
    await tester.runAsync(() async {
      await _stored('asked-about');
      await _stored('opened-since');
      await _stored('switch-target');
    });
    await pumpLibraryWithEditors(tester, container);
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'asked-about',
        initialStrategyName: 'asked-about',
      ),
      isA<Pushed>(),
    );
    await settleWithDisk(tester);
    container.read(strategySaveStateProvider.notifier).markDirty();
    final held = strategies.held = Completer<void>();

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('strategy-quick-switcher-control')),
      matching: find.byType(ShadIconButton),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('switch-target'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(
      await tester.runAsync(() => strategies.openLocal('opened-since',
          asked: strategies.askedByTheUserNow())),
      isA<Changed>(),
    );
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.drawing);
    container.read(agentProvider.notifier).addAgent(PlacedAgent(
          id: 'placed-on-opened-since',
          type: AgentType.jett,
          position: const Offset(500, 500),
        ));
    held.complete();
    strategies.held = null;
    await settleWithDisk(tester);

    expect(container.read(strategyProvider).strategyId, 'opened-since');
    expect(container.read(interactionStateProvider), InteractionState.drawing);
    expect(
      container.read(agentProvider).map((agent) => agent.id),
      contains('placed-on-opened-since'),
    );
    await tester.runAsync(() => strategies.forceSaveNow('opened-since'));
    final saved =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get('opened-since')!;
    expect(
      saved.pages.expand((page) => page.agentData).map((agent) => agent.id),
      contains('placed-on-opened-since'),
    );
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a Community post push moves the count at once, and a second post '
      'asked about what was open before it is refused and adds no route',
      (tester) async {
    container.read(_cloudReady.notifier).state = null;
    await pumpLibraryWithEditors(tester, container);
    final navigator = appNavigatorKey.currentState!;
    final asked = strategies.askedByTheUserNow();

    expect(
      StrategyView.openPost(navigator, _post('first-post'), asked: asked),
      isA<Pushed>(),
    );
    expect(asked.isNow(strategies.askedByTheUserNow()), isFalse);
    final top = mouseNavigationRouteObserver.topRoute;
    expect(
      StrategyView.openPost(navigator, _post('second-post'), asked: asked),
      isA<Refused>(),
    );
    expect(mouseNavigationRouteObserver.topRoute, same(top));

    await tester.pump();
    await leaveEditors(tester, container);
  });

  Future<void> openWithAnEdit(WidgetTester tester, String id) async {
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: id,
        initialStrategyName: id,
      ),
      isA<Pushed>(),
    );
    await settleWithDisk(tester);
    expect(container.read(strategyProvider).strategyId, id);
    container.read(agentProvider.notifier).addAgent(PlacedAgent(
          id: 'placed-on-$id',
          type: AgentType.jett,
          position: const Offset(500, 500),
        ));
  }

  Future<void> expectItsEditSaves(WidgetTester tester, String id) async {
    expect(container.read(strategyProvider).strategyId, id);
    expect(container.read(agentProvider).map((agent) => agent.id),
        contains('placed-on-$id'));
    await tester.runAsync(() => strategies.forceSaveNow(id));
    expect(
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .get(id)!
          .pages
          .expand((page) => page.agentData)
          .map((agent) => agent.id),
      contains('placed-on-$id'),
    );
  }

  testWidgets(
      'a share link whose Save is still running when the Home prompt under '
      'it is answered and another strategy opens leaves that strategy open '
      'with its edit, and the edit saves', (tester) async {
    await tester.runAsync(() async {
      await _stored('asked-about');
      await _stored('opened-next');
    });
    await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'asked-about');
    final held = strategies.held = Completer<void>();

    await tester.tap(_leaveButton());
    await tester.pumpAndSettle();
    container.read(sharedStrategyToOpenProvider.notifier).state = 'linked';
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsNWidgets(2));
    await tester.tap(find.text('Save').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text("Don't save"));
    await settleWithDisk(tester);
    expect(find.byType(StrategyView, skipOffstage: false), findsNothing);

    await openWithAnEdit(tester, 'opened-next');
    final cancels = strategies.cancels;
    held.complete();
    strategies.held = null;
    await settleWithDisk(tester);

    expect(strategies.cancels, cancels);
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    await expectItsEditSaves(tester, 'opened-next');
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a post whose card was tapped before another strategy opened does not '
      'open over that strategy when its read comes back, and the strategy '
      'keeps its edit, which saves', (tester) async {
    await tester.runAsync(() => _stored('opened-meanwhile'));
    await pumpLibraryWithEditors(tester, container);

    unawaited(openCommunityPostFromCard(libraryRef, _post('card-post')));
    await tester.pump();
    expect(posts.asked, ['card-post']);
    await openWithAnEdit(tester, 'opened-meanwhile');
    final editorRoute = mouseNavigationRouteObserver.topRoute;
    final cancels = strategies.cancels;

    posts.release();
    await settleWithDisk(tester);

    expect(mouseNavigationRouteObserver.topRoute, same(editorRoute));
    expect(container.read(communityPostViewProvider), isNull);
    expect(strategies.cancels, cancels);
    await expectItsEditSaves(tester, 'opened-meanwhile');
    await leaveEditors(tester, container);
  });

  testWidgets(
      "a tile's Export whose open gives way to a strategy opened meanwhile "
      'exports nothing and leaves that strategy with its edit, which saves',
      (tester) async {
    await tester.runAsync(() async {
      await _stored('tile-strategy');
      await _stored('opened-meanwhile');
    });
    final summary =
        container.read(localLibraryViewProvider).strategy('tile-strategy')!;
    await pumpLibraryWithEditors(
      tester,
      container,
      library: SizedBox(
        width: 400,
        height: 300,
        child: StrategyTile.local(localStrategy: summary),
      ),
    );
    final reached = Completer<void>();
    final held = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (call) async {
      if (!reached.isCompleted) {
        reached.complete();
        await held.future;
      }
      return disk.path;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (call) async => disk.path));

    await tester.tap(find.byType(StrategyTile), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    for (var turn = 0; turn < 20 && !reached.isCompleted; turn++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(reached.isCompleted, isTrue);

    await openWithAnEdit(tester, 'opened-meanwhile');
    final cancels = strategies.cancels;
    held.complete();
    await settleWithDisk(tester);

    expect(strategies.saved, isNot(contains('tile-strategy')));
    expect(strategies.cancels, cancels);
    await expectItsEditSaves(tester, 'opened-meanwhile');
    await leaveEditors(tester, container);
  });

  Future<void> untilOpen(WidgetTester tester, String id) async {
    for (var turn = 0;
        turn < 40 && container.read(strategyProvider).strategyId != id;
        turn++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(container.read(strategyProvider).strategyId, id);
  }

  for (final inPlace in [true, false]) {
    testWidgets(
        inPlace
            ? 'an editor whose first load gives way to an open in its place '
                'stays and shows that open'
            : 'an editor whose first load gives way to an open in an editor '
                'of its own leaves', (tester) async {
      await tester.runAsync(() async {
        await _stored('slow-a');
        await _stored('local-b');
      });
      await pumpLibraryWithEditors(tester, container);
      final slowA = pages.held['slow-a'] = Completer<void>();
      final b = inPlace ? 'cloud-b' : 'local-b';
      final heldB = Completer<void>();
      if (inPlace) {
        _ReadsItsHeader.held[b] = heldB;
      } else {
        pages.held[b] = heldB;
      }
      addTearDown(() {
        pages.held.clear();
        _ReadsItsHeader.held.clear();
      });
      expect(
        StrategyView.open(
          appNavigatorKey.currentState!,
          asked: strategies.askedByTheUserNow(),
          initialStrategyId: 'slow-a',
          initialStrategyName: 'slow-a',
        ),
        isA<Pushed>(),
      );
      await untilOpen(tester, 'slow-a');
      final editorA = mouseNavigationRouteObserver.topRoute;

      if (inPlace) {
        container.read(sharedStrategyToOpenProvider.notifier).state = b;
      } else {
        expect(
          StrategyView.open(
            appNavigatorKey.currentState!,
            asked: strategies.askedByTheUserNow(),
            initialStrategyId: b,
            initialStrategyName: b,
          ),
          isA<Pushed>(),
        );
      }
      await settleWithDisk(tester);
      slowA.complete();
      await settleWithDisk(tester);
      heldB.complete();
      await untilOpen(tester, b);
      await settleWithDisk(tester);

      expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
      expect(mouseNavigationRouteObserver.topRoute?.settings.name,
          Routes.strategyView);
      if (inPlace) {
        expect(mouseNavigationRouteObserver.topRoute, same(editorA));
      } else {
        expect(mouseNavigationRouteObserver.topRoute, isNot(same(editorA)));
      }
      await leaveEditors(tester, container);
    });
  }

  testWidgets(
      'a window close already answered asks again when an edit comes while '
      'it waits for the platform, and Cancel then keeps the window open',
      (tester) async {
    await tester.runAsync(() => _stored('closing-edit'));
    await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'closing-edit');
    final calls = <String>[];
    final platformReplies = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'),
            (call) async {
      final allows = call.method == 'setPreventClose' &&
          (call.arguments as Map)['isPreventClose'] == false;
      calls.add(allows
          ? 'allow close'
          : call.method == 'setPreventClose'
              ? 'prevent close'
              : call.method);
      if (allows && !platformReplies.isCompleted) {
        await platformReplies.future;
      }
      return null;
    });
    final editor = tester.state(find.byType(StrategyView)) as WindowListener;

    editor.onWindowClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text("Don't save"));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, ['allow close']);
    container.read(agentProvider.notifier).addAgent(PlacedAgent(
          id: 'placed-while-closing',
          type: AgentType.jett,
          position: const Offset(400, 400),
        ));
    platformReplies.complete();
    await tester.pump();
    await tester.pump();

    expect(calls, ['allow close', 'prevent close', 'close']);
    editor.onWindowClose();
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, ['allow close', 'prevent close', 'close']);
    expect(container.read(agentProvider).map((agent) => agent.id),
        contains('placed-while-closing'));
    await leaveEditors(tester, container);
  });

  testWidgets(
      'an editor for a local strategy that is not stored leaves and says it '
      'could not load', (tester) async {
    await pumpLibraryWithEditors(tester, container);
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'never-stored',
        initialStrategyName: 'never-stored',
      ),
      isA<Pushed>(),
    );
    await settleWithDisk(tester);

    expect(find.byType(StrategyView, skipOffstage: false), findsNothing);
    expect(find.text('Could not load strategy.'), findsOneWidget);
    expect(container.read(strategyProvider).strategyId, isNull);
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a cloud editor whose open fails after it put the strategy on screen '
      'closes it, leaves and says it could not load', (tester) async {
    container.read(_cloudReady.notifier).state = true;
    pages.fails.add('broken-cloud');
    addTearDown(() {
      pages.fails.clear();
      container.read(_cloudReady.notifier).state = null;
    });
    await pumpLibraryWithEditors(tester, container);
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'broken-cloud',
        initialStrategyName: 'broken-cloud',
        initialStrategySource: StrategySource.cloud,
      ),
      isA<Pushed>(),
    );
    await settleWithDisk(tester);

    expect(find.byType(StrategyView, skipOffstage: false), findsNothing);
    expect(find.text('Could not load strategy.'), findsOneWidget);
    expect(container.read(strategyProvider).strategyId, isNull);
    await leaveEditors(tester, container);
  });

  testWidgets(
      "a replay card's Open whose captured page lands after another strategy "
      'opened gives way to it: that strategy keeps its edit, which saves, and '
      'the replay keeps playing', (tester) async {
    await tester.runAsync(() => _stored('opened-meanwhile'));
    final document = ReplayDocument.fromBytes(icrp(sampleJson()));
    final playback = ReplayPlayback(
      document: document,
      projection: ReplayMapProjection.forMapPath(document.match.mapPath)!,
      perspective: ReplayTeam.red,
    );
    addTearDown(playback.dispose);
    await pumpLibraryWithEditors(
      tester,
      container,
      library: SizedBox(
        width: 420,
        height: 700,
        child: ReplayMatchCard(
          playback: playback,
          drawing: ReplayDrawing(playback),
          map: MapValue.ascent,
          onReturnFromEditor: () {},
        ),
      ),
    );
    await tester.tap(find.text('Capture'));
    await settleWithDisk(tester);
    captures.waitFor('captured-cloud', 'captured-page');
    await tester.pump();
    await tester.tap(find.text('Open'));
    await tester.pump();

    playback.play();
    await openWithAnEdit(tester, 'opened-meanwhile');
    final cancels = strategies.cancels;
    captures.land();
    await settleWithDisk(tester);

    expect(playback.playing, isTrue);
    expect(strategies.cancels, cancels);
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    await expectItsEditSaves(tester, 'opened-meanwhile');
    playback.pause();
    await leaveEditors(tester, container);
  });
}

CommunityPost _post(String id) => CommunityPost(
      publicId: id,
      title: id,
      map: MapValue.ascent,
      side: CommunitySide.attack,
      agents: const [],
      authorName: null,
      authorAvatarUrl: null,
      starCount: 0,
      pageCount: 1,
      lineupCount: 0,
      publishedAt: DateTime.utc(2026, 1, 1),
      strategyPublicId: '$id-strategy',
      shareToken: '$id-token',
    );
