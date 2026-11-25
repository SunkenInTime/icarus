import 'dart:async';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/widgets/community/community_link.dart';
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
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

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

    testWidgets('a back whose open gave way does not count as having moved',
        (tester) async {
      final strategies = _RecordingStrategies()..givesWay.add('shared-id');
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
      strategies.show('shared-id', StrategySource.local);
      await tester.pump();
      strategies.show('other-id', StrategySource.local);
      await tester.pump();

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

    testWidgets(
        'a link to a removed post, answered with Don\'t save while the save '
        'dialog of a Home click waits over the editor, ends on the library',
        (tester) async {
      final strategies = _UnsavedStrategies();
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
      container.read(strategySaveStateProvider.notifier).markDirty();
      await tester.pump();

      final home = guardUnsavedStrategyExit(
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

      container.read(communityPostToOpenProvider.notifier).state = 'gone';
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
  Future<void> clearCurrentStrategy() async => state = const StrategyState();

  @override
  StrategyState build() => const StrategyState();

  void show(String id, StrategySource source) {
    state = StrategyState(
      strategyId: id,
      strategyName: id,
      source: source,
      isOpen: true,
    );
  }

  @override
  Future<bool> loadFromHive(String id, {String? pageId}) async {
    opened.add('local:$id');
    if (givesWay.contains(id)) {
      await whileOpening?.call();
      return false;
    }
    show(id, StrategySource.local);
    return true;
  }

  @override
  Future<bool> openCloudStrategy(String id, {String? pageId}) async {
    opened.add('cloud:$id');
    if (fails.contains(id)) throw StateError('could not read $id');
    if (givesWay.contains(id)) return false;
    show(id, StrategySource.cloud);
    return true;
  }
}

class _UnsavedStrategies extends _RecordingStrategies {
  @override
  Future<bool> flushPendingAutosaveBeforeExit() async => false;

  @override
  void cancelPendingSave() {}
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
