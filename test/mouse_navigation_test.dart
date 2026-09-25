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
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
  });
}

/// Records which store each open goes through, without touching either.
class _RecordingStrategies extends StrategyProvider {
  final opened = <String>[];

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
  Future<void> loadFromHive(String id) async {
    opened.add('local:$id');
    show(id, StrategySource.local);
  }

  @override
  Future<void> openCloudStrategy(String id) async {
    opened.add('cloud:$id');
    show(id, StrategySource.cloud);
  }
}
