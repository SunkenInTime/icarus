import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:icarus/strategy/autosave_before_exit.dart';
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
import 'package:icarus/widgets/community/community_link.dart';
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
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/strategy_view_skeleton.dart';

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
  Future<AutosaveBeforeExit> flushPendingAutosaveBeforeExit() async =>
      const NotAutosaved(NotAutosavedBecause.autosaveIsOff);

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

Future<void> _stored(String id, {DateTime? lastEdited}) async {
  final strategy = generatedStrategy(Optionals.set)
      .copyWith(id: id, name: id, lastEdited: lastEdited);
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
  static final notKept = <String>{};

  @override
  Future<RemoteEditorSnapshot?> build() => SynchronousFuture(null);

  @override
  Future<void> openStrategy(
    String strategyPublicId, {
    String? activePagePublicId,
  }) async {
    if (held[strategyPublicId] case final hold?) await hold.future;
    if (notKept.contains(strategyPublicId)) {
      state = AsyncError(
        StrategyNotKeptOffline(strategyPublicId),
        StackTrace.current,
      );
      return;
    }
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
    await settleUntilOpen(tester, container, 'second');

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

    closeTheWindow(tester);
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
    await settleUntilOpen(tester, container, 'opened-since');

    expect(container.read(strategyProvider).strategyId, 'opened-since');
    expect(container.read(strategySaveStateProvider).isDirty, isTrue);
    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(windowCalls, isEmpty);
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
    await settleUntilOpen(tester, container, 'opened-since');

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
    await settleUntilOpen(tester, container, id);
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
      'a share link that joined the Home prompt, whose Save is still running '
      'when another strategy opens, leaves that strategy open with its edit, '
      'and the edit saves', (tester) async {
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
    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await openWithAnEdit(tester, 'opened-next');
    final cancels = strategies.cancels;
    held.complete();
    strategies.held = null;
    await settleWithDisk(tester);

    expect(strategies.cancels, cancels);
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
      'a window close sends its release and its close together, so the '
      'window is never left released while it waits, and a second close '
      'meanwhile is no new question', (tester) async {
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
      if (allows) await platformReplies.future;
      return null;
    });

    closeTheWindow(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text("Don't save"));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, ['allow close', 'close']);

    closeTheWindow(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Save changes?'), findsNothing);
    expect(calls, ['allow close', 'close']);
    platformReplies.complete();
    await tester.pump();
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

  testWidgets(
      "an editor that leaves while the close question's Save writes ends "
      'with the window closed once, with no second press', (tester) async {
    await tester.runAsync(() => _stored('leaves-during-close'));
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'leaves-during-close');
    final editor = mouseNavigationRouteObserver.topRoute!;

    final held = strategies.held = Completer<void>();
    closeTheWindow(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(strategies.closeStrategy(asked: strategies.askedByTheUserNow()),
        isA<Changed>());
    appNavigatorKey.currentState!.removeRoute(editor);
    await tester.pumpAndSettle();
    held.complete();
    strategies.held = null;
    await settleWithDisk(tester);

    expect(windowCalls.where((call) => call.method == 'close'), hasLength(1));
    await leaveEditors(tester, container);
  });

  testWidgets('one close with two editors on screen asks once', (tester) async {
    await tester.runAsync(() async {
      await _stored('under');
      await _stored('over');
    });
    await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'under');
    await openWithAnEdit(tester, 'over');
    expect(find.byType(StrategyView, skipOffstage: false), findsNWidgets(2));

    closeTheWindow(tester);
    await tester.pumpAndSettle();

    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a second close while the close question is up is no new question, and '
      'Cancel closes nothing', (tester) async {
    await tester.runAsync(() => _stored('closed-twice'));
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'closed-twice');
    windowCalls.clear();

    closeTheWindow(tester);
    await tester.pumpAndSettle();
    closeTheWindow(tester);
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(windowCalls, isEmpty);
    expect(container.read(strategyProvider).strategyId, 'closed-twice');
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a share link that arrives while a cloud open with no editor holds its '
      'first page opens in an editor of its own', (tester) async {
    await pumpLibraryWithEditors(tester, container);
    container.read(_cloudReady.notifier).state = true;
    final firstPage = pages.held['header-shown'] = Completer<void>();
    addTearDown(() {
      pages.held.clear();
      container.read(_cloudReady.notifier).state = null;
    });
    OpenChange? headerOpened;
    unawaited(strategies
        .openCloud('header-shown', asked: strategies.askedByTheUserNow())
        .then((change) => headerOpened = change));
    await untilOpen(tester, 'header-shown');
    expect(find.byType(StrategyView, skipOffstage: false), findsNothing);

    container.read(sharedStrategyToOpenProvider.notifier).state =
        'linked-cloud';
    await settleWithDisk(tester);
    firstPage.complete();
    await untilOpen(tester, 'linked-cloud');
    await settleWithDisk(tester);
    expect(headerOpened, isA<GaveWay>());
    await settleWithDisk(tester);

    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    expect(mouseNavigationRouteObserver.topRoute?.settings.name,
        Routes.strategyView);
    await leaveEditors(tester, container);
  });

  testWidgets(
      'an editor whose first load throws after a newer open took it in place '
      'shows that open, not its loading screen', (tester) async {
    await tester.runAsync(() => _stored('throws-a'));
    await pumpLibraryWithEditors(tester, container);
    final readA = pages.held['throws-a'] = Completer<void>();
    pages.fails.add('throws-a');
    final readB = _ReadsItsHeader.held['cloud-b'] = Completer<void>();
    addTearDown(() {
      pages.held.clear();
      pages.fails.clear();
      _ReadsItsHeader.held.clear();
    });
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'throws-a',
        initialStrategyName: 'throws-a',
      ),
      isA<Pushed>(),
    );
    await untilOpen(tester, 'throws-a');
    final editor = mouseNavigationRouteObserver.topRoute;

    container.read(sharedStrategyToOpenProvider.notifier).state = 'cloud-b';
    await settleWithDisk(tester);
    readA.complete();
    await settleWithDisk(tester);
    readB.complete();
    await untilOpen(tester, 'cloud-b');
    await settleWithDisk(tester);

    expect(mouseNavigationRouteObserver.topRoute, same(editor));
    expect(find.byType(StrategyViewSkeleton), findsNothing);
    await leaveEditors(tester, container);
  });

  void viewThroughALink(String strategyId) {
    container.read(shareLinkViewProvider.notifier).state =
        (strategyPublicId: strategyId, token: '$strategyId-token');
    addTearDown(
        () => container.read(shareLinkViewProvider.notifier).state = null);
  }

  Future<void> expectOpenInItsOwnEditor(
    WidgetTester tester,
    String id, {
    required Route<dynamic> notIn,
  }) async {
    await untilOpen(tester, id);
    await settleUntilOpen(tester, container, id);
    expect(container.read(strategyProvider).strategyId, id);
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    final editor = tester
        .widget<StrategyView>(find.byType(StrategyView, skipOffstage: false));
    expect(editor.initialStrategyId, id);
    expect(editor.communityPost, isNull);
    expect(mouseNavigationRouteObserver.editorRoute, isNot(same(notIn)));
    expect(notIn.isActive, isFalse);
  }

  testWidgets(
      'a share link that arrives before a pushed editor drew its first frame '
      'opens in an editor of its own, and the pushed one leaves',
      (tester) async {
    await tester.runAsync(() => _stored('pushed-first'));
    await pumpLibraryWithEditors(tester, container);
    viewThroughALink('linked-cloud');
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'pushed-first',
        initialStrategyName: 'pushed-first',
      ),
      isA<Pushed>(),
    );
    final first = mouseNavigationRouteObserver.editorRoute!;
    container.read(sharedStrategyToOpenProvider.notifier).state =
        'linked-cloud';

    await expectOpenInItsOwnEditor(tester, 'linked-cloud', notIn: first);
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a share link that arrives while a cloud editor waits for the cloud '
      'opens in an editor of its own, which stays when that wait ends '
      'without the cloud', (tester) async {
    container.read(_cloudReady.notifier).state = null;
    addTearDown(() => container.read(_cloudReady.notifier).state = null);
    await pumpLibraryWithEditors(tester, container);
    viewThroughALink('linked-cloud');
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'waits-for-cloud',
        initialStrategyName: 'waits-for-cloud',
        initialStrategySource: StrategySource.cloud,
      ),
      isA<Pushed>(),
    );
    final first = mouseNavigationRouteObserver.editorRoute!;
    await tester.pump();
    container.read(sharedStrategyToOpenProvider.notifier).state =
        'linked-cloud';
    await untilOpen(tester, 'linked-cloud');
    container.read(_cloudReady.notifier).state = false;

    await expectOpenInItsOwnEditor(tester, 'linked-cloud', notIn: first);
    await leaveEditors(tester, container);
  });

  testWidgets(
      "a share link that arrives while a Community post's header is still "
      'being read opens in a plain editor, never in the post', (tester) async {
    container.read(_cloudReady.notifier).state = true;
    final header =
        _ReadsItsHeader.held['held-post-strategy'] = Completer<void>();
    addTearDown(() {
      _ReadsItsHeader.held.clear();
      container.read(_cloudReady.notifier).state = null;
    });
    await pumpLibraryWithEditors(tester, container);
    viewThroughALink('linked-cloud');
    expect(
      StrategyView.openPost(
        appNavigatorKey.currentState!,
        _post('held-post'),
        asked: strategies.askedByTheUserNow(),
      ),
      isA<Pushed>(),
    );
    final post = mouseNavigationRouteObserver.editorRoute!;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    container.read(sharedStrategyToOpenProvider.notifier).state =
        'linked-cloud';

    await expectOpenInItsOwnEditor(tester, 'linked-cloud', notIn: post);
    header.complete();
    await expectOpenInItsOwnEditor(tester, 'linked-cloud', notIn: post);
    await leaveEditors(tester, container);
  });

  testWidgets('a route with no editor claim is never claimed in place',
      (tester) async {
    await pumpLibraryWithEditors(tester, container);
    final asked = strategies.askedByTheUserNow();

    expect(
      StrategyView.claimInPlace(
          ModalRoute.of(libraryContext)!, strategies, asked),
      isNull,
    );
    expect(asked.isNow(strategies.askedByTheUserNow()), isTrue);
  });

  testWidgets(
      'a window close sent while the app stays open leaves the next close '
      'free to ask, once an editor is on screen again', (tester) async {
    await tester.runAsync(() async {
      await _stored('closed-once');
      await _stored('opened-after');
    });
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'closed-once');
    closeTheWindow(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text("Don't save"));
    await tester.pumpAndSettle();
    expect(windowCalls.map((call) => call.method), contains('close'));
    expect(strategies.closeStrategy(asked: strategies.askedByTheUserNow()),
        isA<Changed>());
    appNavigatorKey.currentState!.popUntil((route) => route.isFirst);
    await settleWithDisk(tester);
    expect(StrategyView.onScreen.value, 0);

    await openWithAnEdit(tester, 'opened-after');
    closeTheWindow(tester);
    await tester.pumpAndSettle();

    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a cloud editor whose strategy is not kept on this device says it needs '
      'a connection, not that it failed to load', (tester) async {
    container.read(_cloudReady.notifier).state = true;
    _ReadsItsHeader.notKept.add('not-kept');
    addTearDown(() {
      _ReadsItsHeader.notKept.clear();
      container.read(_cloudReady.notifier).state = null;
    });
    await pumpLibraryWithEditors(tester, container);
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'not-kept',
        initialStrategyName: 'not-kept',
        initialStrategySource: StrategySource.cloud,
      ),
      isA<Pushed>(),
    );
    await settleWithDisk(tester);

    expect(find.byType(StrategyView, skipOffstage: false), findsNothing);
    expect(
      find.text('This strategy needs a connection the first time you open it.'),
      findsOneWidget,
    );
    expect(find.text('Could not load strategy.'), findsNothing);
    await leaveEditors(tester, container);
  });

  for (final (name, first, second) in [
    ('two closes', 'close', 'close'),
    ('a close, then a link', 'close', 'link'),
    ('a link, then a close', 'link', 'close'),
  ]) {
    testWidgets(
        "$name answered Don't save close the window once, and open no link",
        (tester) async {
      await tester.runAsync(() => _stored('closing'));
      final windowCalls = await pumpLibraryWithEditors(tester, container);
      await openWithAnEdit(tester, 'closing');
      void ask(String exit) {
        if (exit == 'close') {
          closeTheWindow(tester);
        } else {
          container.read(communityPostToOpenProvider.notifier).state =
              const PostLinkArrived('linked-post');
        }
      }

      ask(first);
      await tester.pumpAndSettle();
      ask(second);
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsOneWidget);
      windowCalls.clear();
      await tester.tap(find.text("Don't save"));
      await settleWithDisk(tester);

      expect(
        windowCalls.map((call) => call.method),
        ['setPreventClose', 'close'],
      );
      expect(posts.asked, isNot(contains('linked-post')));
      await leaveEditors(tester, container);
    });
  }

  testWidgets(
      'an exit question whose editor leaves the screen while its prompt is '
      'up ends, and everyone waiting on it stays', (tester) async {
    await tester.runAsync(() => _stored('leaves-the-screen'));
    await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'leaves-the-screen');
    LeaveAnswer? answer;
    unawaited(guardUnsavedStrategyExit(
      context: tester.element(find.byType(StrategyView)),
      ref: libraryRef,
      source: 'editor-test-editor-leaves',
    ).then((answered) => answer = answered));
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsOneWidget);

    appNavigatorKey.currentState!
        .removeRoute(mouseNavigationRouteObserver.editorRoute!);
    await tester.pumpAndSettle();

    expect(find.byType(StrategyView, skipOffstage: false), findsNothing);
    expect(find.text('Save changes?'), findsNothing);
    expect(answer, isA<Superseded>());
    await leaveEditors(tester, container);
  });

  Future<Completer<void>> holdTheNextStorageDirectory() async {
    final held = Completer<void>();
    var holding = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (call) async {
      if (holding) {
        holding = false;
        await held.future;
      }
      return disk.path;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (call) async => disk.path));
    return held;
  }

  testWidgets(
      'a window close asked while a quick switch is still opening its '
      'strategy, whose prompt is answered after that strategy opened, saves '
      'nothing for the strategy left and asks about the one open now',
      (tester) async {
    await tester.runAsync(() async {
      await _stored('switched-from');
      await _stored('switched-to', lastEdited: DateTime(2100));
    });
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'switched-from');
    final opening = await holdTheNextStorageDirectory();

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('strategy-quick-switcher-control')),
      matching: find.byType(ShadIconButton),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('switched-to'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text("Don't save"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(container.read(strategyProvider).strategyId, 'switched-from');
    expect(container.read(strategySaveStateProvider).isDirty, isTrue);

    closeTheWindow(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Save changes?'), findsOneWidget);
    opening.complete();
    for (var turn = 0;
        turn < 40 &&
            container.read(strategyProvider).strategyId != 'switched-to';
        turn++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      for (var task = 0; task < 20; task++) {
        await Future<void>.value();
      }
    }
    expect(container.read(strategyProvider).strategyId, 'switched-to');
    await tester.tap(find.text('Save'), warnIfMissed: false);
    await settleWithDisk(tester);

    expect(strategies.saved, isNot(contains('switched-from')));
    expect(windowCalls.map((call) => call.method), contains('close'));
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a window close that joined a question another strategy then took over '
      'is asked again once, about that strategy, and Cancel closes nothing',
      (tester) async {
    await tester.runAsync(() async {
      await _stored('asked-first');
      await _stored('took-over');
    });
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'asked-first');
    final editor = mouseNavigationRouteObserver.topRoute!;

    await tester.tap(_leaveButton());
    await tester.pumpAndSettle();
    closeTheWindow(tester);
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsOneWidget);

    final claimed = StrategyView.claimInPlace(
        editor, strategies, strategies.askedByTheUserNow())!;
    expect(
      await tester
          .runAsync(() => strategies.openLocal('took-over', asked: claimed)),
      isA<Changed>(),
    );
    container.read(agentProvider.notifier).addAgent(PlacedAgent(
          id: 'placed-on-took-over',
          type: AgentType.jett,
          position: const Offset(500, 500),
        ));
    windowCalls.clear();
    await tester.pumpAndSettle();

    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsNothing);
    expect(windowCalls.map((call) => call.method), isNot(contains('close')));
    expect(container.read(strategyProvider).strategyId, 'took-over');
    expect(mouseNavigationRouteObserver.topRoute, same(editor));
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a window close whose Save ends after a quick switch opened another '
      'strategy and the user went Home closes the window once, with no second '
      'press', (tester) async {
    await tester.runAsync(() async {
      await _stored('saved-on-close');
      await _stored('went-home-from', lastEdited: DateTime(2100));
    });
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'saved-on-close');
    final opening = await holdTheNextStorageDirectory();

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('strategy-quick-switcher-control')),
      matching: find.byType(ShadIconButton),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('went-home-from'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text("Don't save"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final saving = strategies.held = Completer<void>();
    closeTheWindow(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    opening.complete();
    await untilOpen(tester, 'went-home-from');
    await settleWithDisk(tester);
    await tester.tap(_leaveButton());
    await settleWithDisk(tester);
    expect(find.byType(StrategyView, skipOffstage: false), findsNothing);
    expect(windowCalls.map((call) => call.method), isNot(contains('close')));

    saving.complete();
    strategies.held = null;
    await settleWithDisk(tester);

    expect(strategies.saved, contains('saved-on-close'));
    expect(windowCalls.where((call) => call.method == 'close'), hasLength(1));
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a window close whose prompt is up when the last editor leaves closes '
      'the window once, with no second press', (tester) async {
    await tester.runAsync(() => _stored('last-editor-leaves'));
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'last-editor-leaves');
    closeTheWindow(tester);
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsOneWidget);

    appNavigatorKey.currentState!
        .removeRoute(mouseNavigationRouteObserver.editorRoute!);
    await settleWithDisk(tester);

    expect(StrategyView.onScreen.value, 0);
    expect(find.text('Save changes?'), findsNothing);
    expect(windowCalls.where((call) => call.method == 'close'), hasLength(1));
    await leaveEditors(tester, container);
  });

  testWidgets(
      "a Community link whose question another strategy took over gives way: "
      "the link's post is not read or opened", (tester) async {
    await tester.runAsync(() async {
      await _stored('asked-for-the-link');
      await _stored('took-the-link-over');
    });
    await pumpLibraryWithEditors(tester, container);
    await openWithAnEdit(tester, 'asked-for-the-link');
    final editor = mouseNavigationRouteObserver.topRoute!;
    container.read(communityPostToOpenProvider.notifier).state =
        const PostLinkArrived('superseded-post');
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsOneWidget);

    final claimed = StrategyView.claimInPlace(
        editor, strategies, strategies.askedByTheUserNow())!;
    expect(
      await tester.runAsync(
          () => strategies.openLocal('took-the-link-over', asked: claimed)),
      isA<Changed>(),
    );
    await settleWithDisk(tester);

    expect(find.text('Save changes?'), findsNothing);
    expect(posts.asked, isNot(contains('superseded-post')));
    expect(container.read(strategyProvider).strategyId, 'took-the-link-over');
    expect(mouseNavigationRouteObserver.topRoute, same(editor));
    await leaveEditors(tester, container);
  });

  testWidgets(
      'a cloud editor that opened its strategy is claimed by the next open in '
      'its place, and no second editor is pushed', (tester) async {
    container.read(_cloudReady.notifier).state = true;
    addTearDown(() => container.read(_cloudReady.notifier).state = null);
    await pumpLibraryWithEditors(tester, container);
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'opened-in-the-cloud',
        initialStrategyName: 'opened-in-the-cloud',
        initialStrategySource: StrategySource.cloud,
      ),
      isA<Pushed>(),
    );
    final editor = mouseNavigationRouteObserver.editorRoute!;
    await untilOpen(tester, 'opened-in-the-cloud');
    await settleWithDisk(tester);
    expect(container.read(strategyOpeningProvider), isNull);

    final claimed = StrategyView.claimInPlace(
        editor, strategies, strategies.askedByTheUserNow());
    expect(claimed, isNotNull);
    expect(
      await tester
          .runAsync(() => strategies.openCloud('opened-next', asked: claimed!)),
      isA<Changed>(),
    );
    await settleUntilOpen(tester, container, 'opened-next');

    expect(container.read(strategyProvider).strategyId, 'opened-next');
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    expect(mouseNavigationRouteObserver.editorRoute, same(editor));
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
