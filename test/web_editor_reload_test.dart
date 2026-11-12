import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/open_cloud_strategy_store.dart';
import 'package:icarus/share/pending_share_code_store.dart';
import 'package:icarus/share/share_link_format.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/strategy_save_icon_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  group('reloading on the editor route', () {
    testWidgets('reopens the cloud strategy the tab had open', (tester) async {
      final route = StrategyView.restoredRoute(
        openCloudStrategyId: 'cloud-strategy',
        allowsLocalLibrary: false,
      )! as PageRouteBuilder<void>;

      await tester.pumpWidget(const SizedBox());
      final editor = route.pageBuilder(
        tester.element(find.byType(SizedBox)),
        kAlwaysCompleteAnimation,
        kAlwaysCompleteAnimation,
      ) as StrategyView;

      expect(route.settings.name, Routes.strategyView);
      expect(editor.initialStrategyId, 'cloud-strategy');
      expect(editor.initialStrategySource, StrategySource.cloud);
    });

    test('opens an empty editor only where a local library exists', () {
      expect(
        StrategyView.restoredRoute(
          openCloudStrategyId: null,
          allowsLocalLibrary: true,
        ),
        isNotNull,
      );
      expect(
        StrategyView.restoredRoute(
          openCloudStrategyId: null,
          allowsLocalLibrary: false,
        ),
        isNull,
      );
    });

    testWidgets('with nothing to reopen on the web beta, lands on the library',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        initialRoute: Routes.strategyView,
        home: const Text('library'),
        onGenerateRoute: (settings) => settings.name == Routes.strategyView
            ? StrategyView.restoredRoute(
                openCloudStrategyId: null,
                allowsLocalLibrary: PlatformPolicy.webBeta.allowsLocalLibrary,
              )
            : null,
      ));
      // Debug builds report the ignored initial route; release builds do not.
      final report = tester.takeException();
      expect('$report', contains('Could not navigate to initial route'));
      await tester.pumpAndSettle();

      expect(find.text('library'), findsOneWidget);
      expect(find.byType(StrategyView), findsNothing);
    });
  });

  group('cloudWorkspaceOutcomeProvider', () {
    bool? outcomeFor(AppAuthState auth) {
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(() => _FixedAuth(auth)),
      ]);
      addTearDown(container.dispose);
      return container.read(cloudWorkspaceOutcomeProvider);
    }

    test('is true once the user and Convex are ready', () {
      expect(outcomeFor(_auth(ConvexAuthStatus.ready, ready: true)), isTrue);
    });

    test('waits while sign-in or cloud setup is settling', () {
      expect(outcomeFor(_auth(ConvexAuthStatus.configuring)), isNull);
      expect(
        outcomeFor(_auth(ConvexAuthStatus.signedOut, isLoading: true)),
        isNull,
      );
    });

    test('is false when signed out or in an auth incident', () {
      expect(outcomeFor(_auth(ConvexAuthStatus.signedOut)), isFalse);
      expect(outcomeFor(_auth(ConvexAuthStatus.incident)), isFalse);
    });
  });

  test('the open cloud strategy is recorded while the editor is open',
      () async {
    final store = MemoryOpenCloudStrategyStore();
    final strategy = _SettableStrategy();
    final container = ProviderContainer(overrides: [
      openCloudStrategyStoreProvider.overrideWithValue(store),
      strategyProvider.overrideWith(() => strategy),
    ]);
    addTearDown(container.dispose);

    final editor =
        container.listen(openCloudStrategyRecorderProvider, (_, __) {});
    expect(store.read(), isNull);

    strategy.open('cloud-a', StrategySource.cloud);
    expect(store.read(), 'cloud-a');

    // Switching in place (quick switcher, back/forward) follows along.
    strategy.open('cloud-b', StrategySource.cloud);
    expect(store.read(), 'cloud-b');

    strategy.open('local-a', StrategySource.local);
    expect(store.read(), isNull);

    strategy.open('cloud-c', StrategySource.cloud);
    editor.close();
    await Future<void>.delayed(Duration.zero);
    expect(store.read(), isNull, reason: 'leaving the editor clears it');
  });

  test('a reload reopens the strategy that is open, not a link left behind',
      () async {
    // A reader opened a view link, then their own strategy, in one tab. Both
    // used to stay set for the reload: the link in the address and the held
    // code, their own strategy in the store. The reload opened two editors
    // and one was left on its loading screen.
    const code = 'ICR-2345-6789-ABCD-EFGH';
    var page = icarusProductionShareOrigin.replace(
      path: '/share/$code',
      fragment: '/strategy_view',
    );
    final open = MemoryOpenCloudStrategyStore();
    final heldCode = MemoryPendingShareCodeStore()..write(code);
    final strategy = _SettableStrategy();
    final container = ProviderContainer(overrides: [
      openCloudStrategyStoreProvider.overrideWithValue(open),
      pendingShareCodeStoreProvider.overrideWithValue(heldCode),
      sharePageUrlProvider.overrideWithValue(() => page),
      replaceBrowserUrlProvider.overrideWithValue((url) => page = url),
      strategyProvider.overrideWith(() => strategy),
      // Signed in, the cloud not ready yet: a new code waits, held.
      authProvider.overrideWith(
        () => _FixedAuth(_auth(ConvexAuthStatus.configuring)),
      ),
    ]);
    addTearDown(container.dispose);
    container.read(shareLinkViewProvider.notifier).state =
        (strategyPublicId: 'shared', token: code);
    container.listen(openCloudStrategyRecorderProvider, (_, __) {});

    strategy.open('shared', StrategySource.cloud);
    expect(open.read(), isNull);
    expect(heldCode.read(), code);
    expect(page.path, '/share/$code');

    strategy.open('mine', StrategySource.cloud);
    expect(open.read(), 'mine');
    expect(heldCode.read(), isNull, reason: 'a reload must not reopen it');
    expect(page.path, '/', reason: 'the address follows what is open');
    expect(page.fragment, '/strategy_view', reason: 'the route stays');

    // Back to the shared strategy in the same tab: the link still reads it,
    // and it is what a reload reopens again.
    strategy.open('shared', StrategySource.cloud);
    expect(open.read(), isNull);
    expect(heldCode.read(), code);
    expect(page.path, '/share/$code');

    // A second link arrived and has not opened yet (the cloud was not
    // ready). The address names it from then on, with the stored code, so
    // a reload retries that link and not the older one.
    const waiting = 'ICR-XXXX-XXXX-XXXX-XXXX';
    await container
        .read(shareLinkControllerProvider.notifier)
        .redeemToken(waiting);
    expect(heldCode.read(), waiting);
    expect(page.path, '/share/$waiting');

    // It is not left behind when a strategy opens: the reload is its retry.
    strategy.open('mine', StrategySource.cloud);
    expect(heldCode.read(), waiting);
    expect(page.path, '/share/$waiting');
    expect(open.read(), 'mine');
  });

  testWidgets('the web beta toolbar never offers a local Save', (tester) async {
    for (final (policy, expected) in [
      (PlatformPolicy.webBeta, findsNothing),
      (PlatformPolicy.desktop, findsOneWidget),
    ]) {
      final container = ProviderContainer(overrides: [
        platformPolicyProvider.overrideWithValue(policy),
        strategyProvider.overrideWith(_SettableStrategy.new),
      ]);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const ShadApp(home: Scaffold(body: EditorToolbar())),
      ));

      expect(find.byType(AutoSaveButton), expected, reason: '$policy');
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    }
  });

  testWidgets('the global shortcuts node is never part of focus traversal',
      (tester) async {
    // On web, the navigator's initial-route focus reaches the page before the
    // first frame, and Flutter answers by sorting the view's focus nodes by
    // position (flutter/flutter#191508). With the app-wide shortcuts node in
    // that sort beside the navigator, its unlaid-out box was measured and
    // threw "RenderBox was not laid out" on every page load. flutter_test
    // cannot replay web's build-then-layout startup order, so this checks
    // the property that keeps the node out of the sort.
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        builder: (context, child) => GlobalShortcuts(child: child!),
        home: Scaffold(
          body: Row(children: [
            TextButton(onPressed: () {}, child: const Text('one')),
            TextButton(onPressed: () {}, child: const Text('two')),
          ]),
        ),
      ),
    ));

    final shortcutsNode = FocusManager.instance.rootScope.descendants
        .singleWhere((node) => node.debugLabel == 'global-shortcuts');
    final viewScope = FocusManager.instance.rootScope.descendants
        .whereType<FocusScopeNode>()
        .firstWhere((node) => node.debugLabel == 'View Scope');

    expect(shortcutsNode.skipTraversal, isTrue);
    expect(viewScope.traversalDescendants, isNot(contains(shortcutsNode)));
    // It still holds focus, so app-wide shortcuts keep working.
    expect(shortcutsNode.hasFocus, isTrue);
  });
}

AppAuthState _auth(
  ConvexAuthStatus status, {
  bool ready = false,
  bool isLoading = false,
}) {
  return AppAuthState(
    isLoading: isLoading,
    isAuthenticated: status != ConvexAuthStatus.signedOut,
    isConvexUserReady: ready,
    convexAuthStatus: status,
    user: null,
  );
}

class _FixedAuth extends AuthProvider {
  _FixedAuth(this.auth);

  final AppAuthState auth;

  @override
  AppAuthState build() => auth;
}

class _SettableStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState();

  void open(String id, StrategySource source) {
    state = StrategyState(
      strategyId: id,
      strategyName: id,
      source: source,
      isOpen: true,
    );
  }
}
