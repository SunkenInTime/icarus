import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';

void main() {
  test('workspace defaults to local', () {
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          () => _FakeAuthProvider(_signedOutState),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(libraryWorkspaceProvider), LibraryWorkspace.local);
  });

  test('cloud cannot be selected when unavailable', () {
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          () => _FakeAuthProvider(_signedOutState),
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(libraryWorkspaceProvider.notifier)
        .select(LibraryWorkspace.cloud);

    expect(container.read(libraryWorkspaceProvider), LibraryWorkspace.local);
  });

  test('workspace falls back to local when cloud becomes unavailable', () {
    final fakeAuth = _FakeAuthProvider(_cloudReadyState);
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(() => fakeAuth),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(libraryWorkspaceProvider.notifier)
        .select(LibraryWorkspace.cloud);
    expect(container.read(libraryWorkspaceProvider), LibraryWorkspace.cloud);

    fakeAuth.setState(_signedOutState);

    expect(container.read(libraryWorkspaceProvider), LibraryWorkspace.local);
  });
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
  _FakeAuthProvider(this._initialState);

  final AppAuthState _initialState;

  @override
  AppAuthState build() {
    return _initialState;
  }

  void setState(AppAuthState nextState) {
    state = nextState;
  }
}
