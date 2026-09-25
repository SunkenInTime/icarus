import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/share/pending_share_code_store.dart';
import 'package:icarus/share/share_link_format.dart';
import 'package:toastification/toastification.dart';

const _code = 'ICR-2345-6789-ABCD-EFGH';

void main() {
  group('MemoryPendingShareCodeStore', () {
    test('stores, restores, and clears a code', () {
      final store = MemoryPendingShareCodeStore();
      expect(store.read(), isNull);

      store.write(_code);
      expect(store.read(), _code);

      store.write('ICR-XXXX-XXXX-XXXX-XXXX');
      expect(store.read(), 'ICR-XXXX-XXXX-XXXX-XXXX', reason: 'latest wins');

      store.clear();
      expect(store.read(), isNull);
    });

    test('native builds keep the code in memory', () {
      expect(createPendingShareCodeStore(), isA<MemoryPendingShareCodeStore>());
    });
  });

  group('ShareLinkController pending code', () {
    ProviderContainer containerWith(
      PendingShareCodeStore store, {
      required bool signedIn,
      ConvexStrategyRepository? repository,
    }) {
      final container = ProviderContainer(
        overrides: [
          pendingShareCodeStoreProvider.overrideWithValue(store),
          authProvider.overrideWith(
            () => _FixedAuthProvider(signedIn: signedIn),
          ),
          if (repository != null)
            convexStrategyRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a code held while signed out survives into the next page load',
        () async {
      // Shared by both containers, like sessionStorage across a Discord
      // round trip.
      final store = MemoryPendingShareCodeStore();

      final beforeSignIn = containerWith(store, signedIn: false);
      final redeemed = await beforeSignIn
          .read(shareLinkControllerProvider.notifier)
          .redeemToken(_code);
      expect(redeemed, isFalse);
      expect(store.read(), _code);

      final afterSignIn = containerWith(store, signedIn: false);
      expect(afterSignIn.read(shareLinkControllerProvider), _code);
    });

    test('a late failure of an older attempt keeps the newer pending code',
        () async {
      const newer = 'ICR-XXXX-XXXX-XXXX-XXXX';
      final store = MemoryPendingShareCodeStore();
      final repository = _ControlledRepository();
      final container = containerWith(
        store,
        signedIn: true,
        repository: repository,
      );
      final controller = container.read(shareLinkControllerProvider.notifier);

      // Attempt A is in flight when code B becomes pending.
      final attemptA = controller.redeemToken(_code);
      final attemptB = controller.redeemToken(newer);
      expect(container.read(shareLinkControllerProvider), newer);

      repository.fail(_code);
      expect(await attemptA, isFalse);
      expect(container.read(shareLinkControllerProvider), newer);
      expect(store.read(), newer);

      // B's own failure is the one that clears B.
      repository.fail(newer);
      expect(await attemptB, isFalse);
      expect(container.read(shareLinkControllerProvider), isNull);
      expect(store.read(), isNull);
    });

    test('a failed redemption the user was told about clears the code',
        () async {
      final store = MemoryPendingShareCodeStore()..write(_code);
      final container = containerWith(
        store,
        signedIn: true,
        repository: _FailingRepository(),
      );

      expect(container.read(shareLinkControllerProvider), _code);
      final redeemed = await container
          .read(shareLinkControllerProvider.notifier)
          .redeemPendingIfPossible(showFailureToasts: false);

      expect(redeemed, isFalse);
      expect(container.read(shareLinkControllerProvider), isNull);
      expect(store.read(), isNull);
    });
  });

  group('opening a share link', () {
    final link = icarusProductionShareOrigin.replace(path: '/share/$_code');

    Future<ProviderContainer> pumpApp(
      WidgetTester tester, {
      required AppAuthState auth,
      PendingShareCodeStore? store,
      ConvexStrategyRepository? repository,
    }) async {
      final container = ProviderContainer(overrides: [
        pendingShareCodeStoreProvider
            .overrideWithValue(store ?? MemoryPendingShareCodeStore()),
        authProvider.overrideWith(() => _SettableAuthProvider(auth)),
        if (repository != null)
          convexStrategyRepositoryProvider.overrideWithValue(repository),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const ToastificationWrapper(
          child: ShadApp(home: Scaffold()),
        ),
      ));
      return container;
    }

    Future<void> settleToasts(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    // toastification is a global: clear it and let every auto-close timer
    // run out, so no toast outlives its test or lands in the next one.
    Future<void> clearToasts(WidgetTester tester) async {
      toastification.dismissAll(delayForAnimation: false);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    }

    testWidgets('while a saved session is still restoring, it waits quietly',
        (tester) async {
      final store = MemoryPendingShareCodeStore();
      // Already accessible, so redeeming shows no toast of its own.
      final repository = _RedeemingRepository(const ShareRedemption(
        targetType: 'strategy',
        strategyPublicId: 'strategy-1',
        role: 'viewer',
        alreadyHadAccess: true,
      ));
      final container = await pumpApp(
        tester,
        auth: _auth(session: true, cloudReady: false),
        store: store,
        repository: repository,
      );

      await container
          .read(shareLinkControllerProvider.notifier)
          .handleIncomingUri(link, source: 'test');
      await settleToasts(tester);

      expect(toast('Sign in to redeem shared links.'), findsNothing);
      expect(store.read(), _code, reason: 'held until the cloud is ready');
      expect(repository.redeemed, isEmpty);

      // The app redeems it once the cloud is ready (main.dart's listener).
      (container.read(authProvider.notifier) as _SettableAuthProvider)
          .set(_auth(session: true, cloudReady: true));
      await container
          .read(shareLinkControllerProvider.notifier)
          .redeemPendingIfPossible();
      expect(repository.redeemed, [_code]);
      expect(store.read(), isNull);
      await clearToasts(tester);
    });

    testWidgets('while signed out, it asks the user to sign in',
        (tester) async {
      final store = MemoryPendingShareCodeStore();
      final container = await pumpApp(
        tester,
        auth: _auth(session: false, cloudReady: false),
        store: store,
      );

      await container
          .read(shareLinkControllerProvider.notifier)
          .handleIncomingUri(link, source: 'test');
      await settleToasts(tester);

      expect(toast('Sign in to redeem shared links.'), findsOneWidget);
      expect(store.read(), _code);
      await clearToasts(tester);
    });

    testWidgets(
        'the owner of the strategy is taken to it, with no "added" toast',
        (tester) async {
      final container = await pumpApp(
        tester,
        auth: _auth(session: true, cloudReady: true),
        repository: _RedeemingRepository(const ShareRedemption(
          targetType: 'strategy',
          strategyPublicId: 'strategy-1',
          folderPublicId: 'folder-1',
          role: 'owner',
          alreadyHadAccess: true,
        )),
      );

      await container
          .read(shareLinkControllerProvider.notifier)
          .handleIncomingUri(link, source: 'test');
      await settleToasts(tester);

      expect(toast('Shared strategy added to your library.'), findsNothing);
      expect(
        container.read(cloudLibrarySectionProvider),
        CloudLibrarySection.home,
      );
      expect(container.read(sharedStrategyToOpenProvider), 'strategy-1');
      await clearToasts(tester);
    });

    testWidgets('a newly shared strategy is added to Shared, then opened',
        (tester) async {
      final container = await pumpApp(
        tester,
        auth: _auth(session: true, cloudReady: true),
        repository: _RedeemingRepository(const ShareRedemption(
          targetType: 'strategy',
          strategyPublicId: 'strategy-2',
          role: 'viewer',
        )),
      );

      await container
          .read(shareLinkControllerProvider.notifier)
          .handleIncomingUri(link, source: 'test');
      await settleToasts(tester);

      expect(
        toast('Shared strategy added to your library.'),
        findsOneWidget,
      );
      expect(
        container.read(cloudLibrarySectionProvider),
        CloudLibrarySection.sharedWithMe,
      );
      expect(container.read(sharedStrategyToOpenProvider), 'strategy-2');
      await clearToasts(tester);
    });
  });
}

/// A toast's text. Toasts sit in an overlay entry that is still animating
/// in when these tests look, so offstage widgets count.
Finder toast(String text) => find.byWidgetPredicate(
      (widget) => widget is Text && widget.data == text,
      skipOffstage: false,
    );

AppAuthState _auth({required bool session, required bool cloudReady}) {
  return AppAuthState(
    isLoading: false,
    isAuthenticated: session,
    isConvexUserReady: session && cloudReady,
    convexAuthStatus: !session
        ? ConvexAuthStatus.signedOut
        : cloudReady
            ? ConvexAuthStatus.ready
            : ConvexAuthStatus.configuring,
    user: null,
  );
}

class _SettableAuthProvider extends AuthProvider {
  _SettableAuthProvider(this._initial);

  final AppAuthState _initial;

  @override
  AppAuthState build() => _initial;

  void set(AppAuthState next) => state = next;
}

class _RedeemingRepository extends Fake implements ConvexStrategyRepository {
  _RedeemingRepository(this.response);

  final ShareRedemption response;
  final List<String> redeemed = [];

  @override
  Future<ShareRedemption> redeemShareLink(String token) async {
    redeemed.add(token);
    return response;
  }
}

class _FixedAuthProvider extends AuthProvider {
  _FixedAuthProvider({required this.signedIn});

  final bool signedIn;

  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: signedIn,
        isConvexUserReady: signedIn,
        convexAuthStatus:
            signedIn ? ConvexAuthStatus.ready : ConvexAuthStatus.signedOut,
        user: null,
      );
}

/// Holds each redemption open until the test fails it.
class _ControlledRepository extends Fake implements ConvexStrategyRepository {
  final _pending = <String, Completer<ShareRedemption>>{};

  void fail(String token) =>
      _pending[token]!.completeError(Exception('Share link revoked'));

  @override
  Future<ShareRedemption> redeemShareLink(String token) =>
      (_pending[token] = Completer<ShareRedemption>()).future;
}

class _FailingRepository extends Fake implements ConvexStrategyRepository {
  @override
  Future<ShareRedemption> redeemShareLink(String token) async {
    throw Exception('Share link revoked');
  }
}
