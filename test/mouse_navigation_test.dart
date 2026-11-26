import 'dart:async';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/widgets/community/community_link.dart';
import 'package:icarus/widgets/community/community_post_view.dart';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';
import 'opens_now_support.dart';

import 'library_rows/generated_strategies.dart';

void main() {
  testWidgets('mouse back does not navigate under an open Shad popover',
      (tester) async {
    final popoverController = ShadPopoverController();
    final unrelatedFocusNode = FocusNode();
    addTearDown(popoverController.dispose);
    addTearDown(unrelatedFocusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: ShadApp(
          navigatorKey: appNavigatorKey,
          navigatorObservers: [mouseNavigationRouteObserver],
          builder: (_, child) => MouseNavigation(child: child!),
          home: const Scaffold(body: Text('library')),
        ),
      ),
    );

    appNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/auxiliary'),
        builder: (_) => Scaffold(
          body: Stack(
            children: [
              TextField(focusNode: unrelatedFocusNode),
              ShadPopover(
                controller: popoverController,
                popover: (_) => const Text('menu'),
                child: const SizedBox.expand(child: Text('auxiliary')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    popoverController.show();
    await tester.pumpAndSettle();
    expect(find.text('menu'), findsOneWidget);
    unrelatedFocusNode.requestFocus();
    await tester.pump();
    expect(unrelatedFocusNode.hasFocus, isTrue);

    await tester.sendEventToBinding(
      const PointerDownEvent(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
        position: Offset(400, 300),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('auxiliary'), findsOneWidget);
    expect(find.text('library'), findsNothing);
  });

  testWidgets('mouse back does not navigate under an open Shad context menu',
      (tester) async {
    final menuController = ShadContextMenuController();
    final unrelatedFocusNode = FocusNode();
    addTearDown(menuController.dispose);
    addTearDown(unrelatedFocusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: ShadApp(
          navigatorKey: appNavigatorKey,
          navigatorObservers: [mouseNavigationRouteObserver],
          builder: (_, child) => MouseNavigation(child: child!),
          home: const Scaffold(body: Text('library')),
        ),
      ),
    );

    appNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/auxiliary'),
        builder: (_) => Scaffold(
          body: Stack(
            children: [
              TextField(focusNode: unrelatedFocusNode),
              ShadContextMenu(
                controller: menuController,
                items: const [ShadContextMenuItem(child: Text('menu item'))],
                child: const SizedBox.expand(child: Text('auxiliary')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    menuController.show();
    await tester.pumpAndSettle();
    expect(find.text('menu item'), findsOneWidget);
    unrelatedFocusNode.requestFocus();
    await tester.pump();
    expect(unrelatedFocusNode.hasFocus, isTrue);

    await tester.sendEventToBinding(
      const PointerDownEvent(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
        position: Offset(400, 300),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('auxiliary'), findsOneWidget);
    expect(find.text('library'), findsNothing);
  });

  group('a local and a cloud strategy sharing an id', () {
    late Directory tempDir;

    setUpAll(() => registerIcarusAdapters(Hive));

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('icarus-mouse-nav-');
      Hive.init(tempDir.path);
      final box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
      // Leaving a strategy resets the agent filter and checks the outboxes.
      await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
      await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
      await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
      // The local copy an upload leaves behind keeps the cloud strategy's id.
      await box.put(
        'shared-id',
        StrategyData(
          id: 'shared-id',
          name: 'Local copy',
          mapData: MapValue.ascent,
          versionNumber: 1,
          folderID: null,
          pages: const [],
          lastEdited: DateTime.utc(2026, 1, 1),
        ),
      );
    });

    tearDown(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    // The strategy open when back is pressed is local in both cases: leaving
    // a cloud strategy runs the outbox guard, which needs a live Convex
    // client.
    for (final (recorded, then) in const [
      (StrategySource.cloud, StrategySource.local),
      (StrategySource.local, StrategySource.local),
    ]) {
      testWidgets('back reopens the ${recorded.name} one it came from',
          (tester) async {
        final strategies = _RecordingStrategies();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
              isCloudWorkspaceAvailableProvider.overrideWithValue(true),
              strategyProvider.overrideWith(() => strategies),
            ],
            child: ShadApp(
              navigatorKey: appNavigatorKey,
              navigatorObservers: [mouseNavigationRouteObserver],
              builder: (_, child) => MouseNavigation(child: child!),
              home: const Scaffold(body: Text('library')),
            ),
          ),
        );

        strategies.show('shared-id', recorded);
        await tester.pump();
        strategies.show('other-id', then);
        await tester.pump();
        unawaited(appNavigatorKey.currentState!.push(MaterialPageRoute<void>(
          settings: RouteSettings(
            name: Routes.strategyView,
            arguments: EditorClaim.showing(strategies.askedByTheUserNow()),
          ),
          builder: (_) => const Scaffold(body: Text('editor')),
        )));
        await tester.pumpAndSettle();

        await tester.sendEventToBinding(
          const PointerDownEvent(
            kind: PointerDeviceKind.mouse,
            buttons: kBackMouseButton,
            position: Offset(400, 300),
          ),
        );
        await tester.pumpAndSettle();

        expect(strategies.opened, ['${recorded.name}:shared-id']);
      });
    }

    testWidgets(
        'a share link opens its cloud strategy in place of the open one',
        (tester) async {
      final strategies = _RecordingStrategies();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
            isCloudWorkspaceAvailableProvider.overrideWithValue(true),
            strategyProvider.overrideWith(() => strategies),
          ],
          child: ShadApp(
            navigatorKey: appNavigatorKey,
            navigatorObservers: [mouseNavigationRouteObserver],
            builder: (context, child) {
              container = ProviderScope.containerOf(context);
              return MouseNavigation(child: child!);
            },
            home: const Scaffold(body: Text('library')),
          ),
        ),
      );
      strategies.show('other-id', StrategySource.local);
      await tester.pump();

      container.read(sharedStrategyToOpenProvider.notifier).state = 'shared-id';
      await tester.pumpAndSettle();

      expect(strategies.opened, ['cloud:shared-id']);
      expect(container.read(strategyProvider).strategyId, 'shared-id');
    });

    testWidgets(
        'a back whose open gave way does not count as having moved, and '
        "leaves the editor's tool as it was", (tester) async {
      final strategies = _RecordingStrategies()..givesWay.add('shared-id');
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
            isCloudWorkspaceAvailableProvider.overrideWithValue(true),
            strategyProvider.overrideWith(() => strategies),
          ],
          child: ShadApp(
            navigatorKey: appNavigatorKey,
            navigatorObservers: [mouseNavigationRouteObserver],
            builder: (context, child) {
              container = ProviderScope.containerOf(context);
              return MouseNavigation(child: child!);
            },
            home: const Scaffold(body: Text('library')),
          ),
        ),
      );
      strategies.show('shared-id', StrategySource.local);
      await tester.pump();
      strategies.show('other-id', StrategySource.local);
      await tester.pump();
      container
          .read(interactionStateProvider.notifier)
          .update(InteractionState.drawing);

      Future<void> back(int pointer) async {
        await tester.sendEventToBinding(
          PointerDownEvent(
            pointer: pointer,
            kind: PointerDeviceKind.mouse,
            buttons: kBackMouseButton,
            position: const Offset(400, 300),
          ),
        );
        await tester.pumpAndSettle();
      }

      await back(1);
      expect(strategies.state.strategyId, 'other-id');
      expect(container.read(interactionStateProvider), InteractionState.drawing);
      // Still one step back from where the reader is: back tries it again.
      await back(2);
      expect(strategies.opened, ['local:shared-id', 'local:shared-id']);
    });

    Future<_RecordingStrategies> openOtherAfterShared(
      WidgetTester tester,
      StrategySource shared,
    ) async {
      final strategies = _RecordingStrategies();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
            isCloudWorkspaceAvailableProvider.overrideWithValue(true),
            strategyProvider.overrideWith(() => strategies),
          ],
          child: ToastificationWrapper(
            child: ShadApp(
              navigatorKey: appNavigatorKey,
              navigatorObservers: [mouseNavigationRouteObserver],
              builder: (_, child) => MouseNavigation(child: child!),
              home: const Scaffold(body: Text('library')),
            ),
          ),
        ),
      );
      strategies.show('shared-id', shared);
      await tester.pump();
      strategies.show('other-id', StrategySource.local);
      await tester.pump();
      return strategies;
    }

    Future<void> pressBack(WidgetTester tester, int pointer) async {
      await tester.sendEventToBinding(
        PointerDownEvent(
          pointer: pointer,
          kind: PointerDeviceKind.mouse,
          buttons: kBackMouseButton,
          position: const Offset(400, 300),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('going home while a back is loading is where history is',
        (tester) async {
      final strategies =
          await openOtherAfterShared(tester, StrategySource.local);
      strategies.givesWay.add('shared-id');
      strategies.whileOpening = strategies.clearCurrentStrategy;

      await pressBack(tester, 1);
      expect(strategies.state.strategyId, isNull);

      strategies.show('third-id', StrategySource.local);
      await tester.pump();
      await pressBack(tester, 2);

      expect(strategies.state.strategyId, isNull);
      expect(strategies.opened, ['local:shared-id']);
    });

    testWidgets(
        'a cloud strategy that fails to open over another leaves the editor',
        (tester) async {
      // The open has let go of the strategy on screen by the time its read
      // fails. Staying would show that strategy with its edits going to the
      // one that failed.
      final strategies =
          await openOtherAfterShared(tester, StrategySource.cloud);
      strategies.fails.add('shared-id');

      await pressBack(tester, 1);

      expect(strategies.state.strategyId, isNull);
      expect(find.text('Could not load strategy.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('leaving an editor its own save dialog covers', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('icarus-mouse-nav-');
      Hive.init(tempDir.path);
      await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
      await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
      await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
    });

    tearDown(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    Future<ProviderContainer> pumpLibrary(
      WidgetTester tester,
      _UnsavedStrategies strategies,
    ) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
            isCloudWorkspaceAvailableProvider.overrideWithValue(true),
            strategyProvider.overrideWith(() => strategies),
            authProvider.overrideWith(_SignedOut.new),
            communityRepositoryProvider.overrideWithValue(_RemovedPosts()),
          ],
          child: ToastificationWrapper(
            child: ShadApp(
              navigatorKey: appNavigatorKey,
              navigatorObservers: [mouseNavigationRouteObserver],
              builder: (context, child) {
                container = ProviderScope.containerOf(context);
                return MouseNavigation(child: child!);
              },
              home: const Scaffold(body: Text('library')),
            ),
          ),
        ),
      );
      return container;
    }

    Future<(ProviderContainer, WidgetRef)> pumpLibraryReading(
      WidgetTester tester,
      _UnsavedStrategies strategies,
      CommunityRepository posts,
    ) async {
      late WidgetRef libraryRef;
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
            isCloudWorkspaceAvailableProvider.overrideWithValue(true),
            strategyProvider.overrideWith(() => strategies),
            authProvider.overrideWith(_SignedOut.new),
            communityRepositoryProvider.overrideWithValue(posts),
          ],
          child: ToastificationWrapper(
            child: ShadApp(
              navigatorKey: appNavigatorKey,
              navigatorObservers: [mouseNavigationRouteObserver],
              builder: (context, child) {
                container = ProviderScope.containerOf(context);
                return MouseNavigation(child: child!);
              },
              home: Scaffold(
                body: Consumer(builder: (context, ref, _) {
                  libraryRef = ref;
                  return const Text('library');
                }),
              ),
            ),
          ),
        ),
      );
      return (container, libraryRef);
    }

    Future<(BuildContext, WidgetRef)> openEditor(
      WidgetTester tester,
      _UnsavedStrategies strategies,
    ) async {
      late BuildContext editor;
      late WidgetRef editorRef;
      unawaited(appNavigatorKey.currentState!.push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: Routes.strategyView),
        builder: (_) => Scaffold(
          body: Consumer(builder: (context, ref, _) {
            editor = context;
            editorRef = ref;
            return const Text('editor');
          }),
        ),
      )));
      await tester.pumpAndSettle();
      strategies.show('editor-id', StrategySource.local);
      await tester.pump();
      return (editor, editorRef);
    }

    testWidgets(
        'a link to a removed post, answered with Don\'t save while the save '
        'dialog of a Home click waits over the editor, ends on the library',
        (tester) async {
      final strategies = _UnsavedStrategies();
      final container = await pumpLibrary(tester, strategies);
      final (editor, editorRef) = await openEditor(tester, strategies);
      container.read(strategySaveStateProvider.notifier).markDirty();
      await tester.pump();

      final home = guardThenIgnoringWhatItSaw(
        context: editor,
        ref: editorRef,
        source: 'mouse-navigation-test-home',
        onContinue: () async {
          Navigator.pop(editor);
          await strategies.clearCurrentStrategy();
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsOneWidget);

      container.read(communityPostToOpenProvider.notifier).state =
          const PostLinkArrived('gone');
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsNWidgets(2));
      await tester.tap(find.text("Don't save").last);
      await tester.pumpAndSettle();

      expect(await home, isFalse);
      expect(find.text('Save changes?'), findsNothing);
      expect(find.text('editor', skipOffstage: false), findsNothing);
      expect(find.text('library'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    for (final tapped in [true, false]) {
      testWidgets(
          tapped
              ? 'a post tapped in the app whose read comes back after a '
                  'strategy opened gives way to that strategy'
              : 'a post linked from outside whose read comes back after a '
                  'strategy opened leaves that strategy for the post',
          (tester) async {
        final strategies = _UnsavedStrategies();
        final posts = _HeldPost();
        final (container, _) =
            await pumpLibraryReading(tester, strategies, posts);

        container.read(communityPostToOpenProvider.notifier).state = tapped
            ? PostTapped('linked-post', strategies.askedByTheUserNow())
            : const PostLinkArrived('linked-post');
        await tester.pump();
        expect(posts.asked, ['linked-post']);
        await openEditor(tester, strategies);
        final editorRoute = mouseNavigationRouteObserver.topRoute;

        posts.release();
        await tester.pump();
        await tester.pump();

        if (tapped) {
          expect(mouseNavigationRouteObserver.topRoute, same(editorRoute));
          expect(strategies.state.strategyId, 'editor-id');
          expect(container.read(communityPostViewProvider), isNull);
        } else {
          expect(strategies.state.strategyId, isNot('editor-id'));
          expect(container.read(communityPostViewProvider)?.publicId,
              'linked-post');
          final top = mouseNavigationRouteObserver.topRoute;
          expect(top, isNot(same(editorRoute)));
          expect(top?.settings.name, Routes.strategyView);
          expect(
            tester
                .widget<StrategyView>(
                    find.byType(StrategyView, skipOffstage: false))
                .communityPost
                ?.publicId,
            'linked-post',
          );
        }
      });
    }

    testWidgets(
        'a Back to a post whose read comes back after another strategy '
        'opened is not recorded as a move, and the next Back goes from that '
        'strategy to the one before it', (tester) async {
      await tester.runAsync(() async {
        if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
        final stored = await Hive.openBox<StrategyData>(
          HiveBoxNames.strategiesBox,
        );
        await stored.put(
          'strategy-a',
          generatedStrategy(Optionals.set)
              .copyWith(id: 'strategy-a', name: 'strategy-a'),
        );
      });
      final strategies = _UnsavedStrategies();
      final posts = _HeldPost();
      final (container, _) =
          await pumpLibraryReading(tester, strategies, posts);
      final post = _post('history-post');
      container.read(communityPostViewProvider.notifier).state = post;
      strategies.show(post.strategyPublicId, StrategySource.cloud);
      await tester.pump();
      container.read(communityPostViewProvider.notifier).state = null;
      strategies.show('strategy-a', StrategySource.local);
      await tester.pump();

      Future<void> back(int pointer) async {
        await tester.sendEventToBinding(PointerDownEvent(
          pointer: pointer,
          kind: PointerDeviceKind.mouse,
          buttons: kBackMouseButton,
          position: const Offset(400, 300),
        ));
        await tester.pump();
        await tester.pump();
      }

      await back(1);
      expect(posts.asked, ['history-post']);
      strategies.show('strategy-b', StrategySource.local);
      unawaited(appNavigatorKey.currentState!.push(MaterialPageRoute<void>(
        settings: RouteSettings(
          name: Routes.strategyView,
          arguments: EditorClaim.showing(strategies.askedByTheUserNow()),
        ),
        builder: (_) => const Scaffold(body: Text('strategy-b')),
      )));
      await tester.pump();
      posts.release();
      await tester.pumpAndSettle();
      expect(strategies.state.strategyId, 'strategy-b');

      await back(2);
      await tester.pumpAndSettle();
      expect(strategies.state.strategyId, 'strategy-a');
      expect(strategies.opened.last, 'local:strategy-a');
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets(
        'a link to a removed post that arrives while a dialog is open over '
        'the editor closes that dialog with the editor', (tester) async {
      final strategies = _UnsavedStrategies();
      await pumpLibrary(tester, strategies);
      final (editor, _) = await openEditor(tester, strategies);
      var closed = false;
      unawaited(showDialog<void>(
        context: editor,
        builder: (_) => const Dialog(child: Text('screenshot')),
      ).whenComplete(() => closed = true));
      await tester.pumpAndSettle();
      expect(find.text('screenshot'), findsOneWidget);

      ProviderScope.containerOf(editor)
          .read(communityPostToOpenProvider.notifier)
          .state = const PostLinkArrived('gone');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));

      expect(closed, isTrue);
      expect(find.text('screenshot', skipOffstage: false), findsNothing);
      expect(find.text('editor', skipOffstage: false), findsNothing);
      expect(find.text('library'), findsOneWidget);
      expect(mouseNavigationRouteObserver.topRoute?.settings.name, '/');
    });
  });
}

/// Records which store each open goes through, without touching either.
class _RecordingStrategies extends StrategyProvider {
  final opened = <String>[];

  /// Strategies whose open gives way before it finishes.
  final givesWay = <String>{};

  /// Cloud strategies whose open throws.
  final fails = <String>{};

  /// What the reader does while a strategy that gives way is loading.
  Future<void> Function()? whileOpening;

  @override
  CloseChange closeStrategy({required OpenSeen asked}) {
    if (!asked.isNow(askedByTheUserNow())) return const GaveWay();
    ref.read(strategyOpeningProvider.notifier).endAll();
    state = const StrategyState();
    return Changed(askedByTheUserNow());
  }

  @override
  StrategyState build() => const StrategyState();

  void show(String id, StrategySource source) {
    ref.read(strategyOpeningProvider.notifier).endAll();
    state = StrategyState(
      strategyId: id,
      strategyName: id,
      source: source,
      isOpen: true,
    );
  }

  @override
  Future<OpenChange> openLocal(
    String id, {
    String? pageId,
    required OpenSeen asked,
    void Function()? whenShown,
  }) async {
    if (!asked.isNow(askedByTheUserNow())) return const GaveWay();
    opened.add('local:$id');
    if (givesWay.contains(id)) {
      await whileOpening?.call();
      return const GaveWay();
    }
    show(id, StrategySource.local);
    return Changed(askedByTheUserNow());
  }

  @override
  Future<OpenChange> openCloud(
    String id, {
    String? pageId,
    required OpenSeen asked,
    void Function()? whenShown,
  }) async {
    if (!asked.isNow(askedByTheUserNow())) return const GaveWay();
    opened.add('cloud:$id');
    if (fails.contains(id)) {
      ref
          .read(strategyOpeningProvider.notifier)
          .begin(id, source: StrategySource.cloud);
      throw StateError('could not read $id');
    }
    if (givesWay.contains(id)) return const GaveWay();
    show(id, StrategySource.cloud);
    return Changed(askedByTheUserNow());
  }
}

class _UnsavedStrategies extends _RecordingStrategies {
  @override
  Future<bool> flushPendingAutosaveBeforeExit() async => false;

  @override
  void cancelPendingSave() {}
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

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _RemovedPosts implements CommunityRepository {
  @override
  Future<({CommunityPost post, CommunityPostStatus status})?> fetchPost(
    String postPublicId,
  ) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
