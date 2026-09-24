import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/share/pending_share_code_store.dart';

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

class _FailingRepository extends Fake implements ConvexStrategyRepository {
  @override
  Future<ShareRedemption> redeemShareLink(String token) async {
    throw Exception('Share link revoked');
  }
}
