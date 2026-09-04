import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';

void main() {
  test('My Library uses the cloud store when it is reachable', () {
    final container = _container(_cloudReadyState);

    container.read(libraryNavigationProvider).showLibrary();

    expect(container.read(libraryTabProvider), LibraryTab.library);
    expect(container.read(libraryWorkspaceProvider), LibraryWorkspace.cloud);
  });

  test('My Library falls back to the local store when signed out', () {
    final container = _container(_signedOutState);

    container.read(libraryNavigationProvider).showLibrary();

    expect(container.read(libraryTabProvider), LibraryTab.library);
    expect(container.read(libraryWorkspaceProvider), LibraryWorkspace.local);
  });

  test('Shared needs the cloud and reports when it is not there', () {
    final container = _container(_signedOutState);

    final opened = container.read(libraryNavigationProvider).showShared();

    expect(opened, isFalse);
    expect(container.read(libraryTabProvider), LibraryTab.library);
  });

  test('Shared maps to the cloud shared section', () {
    final container = _container(_cloudReadyState);

    final opened = container.read(libraryNavigationProvider).showShared();

    expect(opened, isTrue);
    expect(container.read(libraryTabProvider), LibraryTab.shared);
    expect(
      container.read(cloudLibrarySectionProvider),
      CloudLibrarySection.sharedWithMe,
    );
  });

  test('Community is its own tab', () {
    final container = _container(_cloudReadyState);

    container.read(libraryNavigationProvider).showCommunity();

    expect(container.read(libraryTabProvider), LibraryTab.community);
  });
}

ProviderContainer _container(AppAuthState auth) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(() => _FakeAuthProvider(auth)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

const _signedOutState = AppAuthState(
  isLoading: false,
  isAuthenticated: false,
  isConvexUserReady: false,
  convexAuthStatus: ConvexAuthStatus.signedOut,
  user: null,
);

const _cloudReadyState = AppAuthState(
  isLoading: false,
  isAuthenticated: true,
  isConvexUserReady: true,
  convexAuthStatus: ConvexAuthStatus.ready,
  user: null,
);

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._initial);

  final AppAuthState _initial;

  @override
  AppAuthState build() => _initial;
}
