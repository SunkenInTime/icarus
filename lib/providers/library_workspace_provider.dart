import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';

enum LibraryWorkspace {
  local,
  cloud,
  community,
}

enum CloudLibrarySection {
  home,
  sharedWithMe,
}

final isCloudWorkspaceAvailableProvider = Provider<bool>((ref) {
  final auth = ref.watch(authProvider);
  return auth.isAuthenticated && auth.isConvexUserReady;
});

/// Whether cloud mode will be usable: true once the user and Convex are
/// ready, or once a signed-in session finds the cloud out of reach on a
/// computer that keeps a copy of it; false if the session ends signed out
/// or in an auth incident (or offline with no copy); null while sign-in or
/// cloud setup is still settling (as it is right after a web page reload).
final cloudWorkspaceOutcomeProvider = Provider<bool?>((ref) {
  if (ref.watch(isCloudWorkspaceAvailableProvider)) return true;
  final auth = ref.watch(authProvider);
  if (auth.isLoading) return null;
  return switch (auth.convexAuthStatus) {
    ConvexAuthStatus.signedOut || ConvexAuthStatus.incident => false,
    ConvexAuthStatus.offline =>
      ref.watch(cloudLibraryCopyStoreProvider).keepsCopy,
    ConvexAuthStatus.configuring || ConvexAuthStatus.ready => null,
  };
});

/// Signed in, and the cloud isn't ready: still connecting, or out of reach.
/// The library shows the cloud as this computer last saw it meanwhile
/// (see remote_library_provider), and says which of the two it is.
final cloudLibraryShowsCopyProvider = Provider<bool>((ref) {
  // No copy is kept on web, so the library there is exactly as it was.
  if (!ref.watch(cloudLibraryCopyStoreProvider).keepsCopy) return false;
  final mode = ref.watch(cloudCollabModeProvider);
  if (!mode.featureFlagEnabled || mode.forceLocalFallback) return false;
  final auth = ref.watch(authProvider);
  if (!auth.isAuthenticated ||
      auth.user == null ||
      auth.isConvexUserReady ||
      auth.hasActiveAuthIncident) {
    return false;
  }
  return auth.convexAuthStatus == ConvexAuthStatus.configuring ||
      auth.convexAuthStatus == ConvexAuthStatus.offline;
});

/// Whether cloud folders and the Shared tab can be opened: the cloud is
/// ready, or the library is showing this computer's copy of it. Making
/// anything new in the cloud still needs [isCloudWorkspaceAvailableProvider].
final isCloudLibraryBrowsableProvider = Provider<bool>((ref) {
  // Read from auth itself, not isCloudWorkspaceAvailableProvider: a listener
  // of that provider that reads this one must not see the old answer.
  final auth = ref.watch(authProvider);
  return (auth.isAuthenticated && auth.isConvexUserReady) ||
      ref.watch(cloudLibraryShowsCopyProvider);
});

/// True while My Library stays closed because this platform needs the cloud
/// library and it is not reachable yet (signed out, or still signing in).
final librarySignInRequiredProvider = Provider<bool>((ref) {
  return ref.watch(platformPolicyProvider).requiresSignIn &&
      !ref.watch(isCloudWorkspaceAvailableProvider);
});

final libraryWorkspaceProvider =
    NotifierProvider<LibraryWorkspaceNotifier, LibraryWorkspace>(
  LibraryWorkspaceNotifier.new,
);

final isCloudWorkspaceSelectedProvider = Provider<bool>((ref) {
  return ref.watch(libraryWorkspaceProvider) == LibraryWorkspace.cloud;
});

final cloudLibrarySectionProvider =
    NotifierProvider<CloudLibrarySectionNotifier, CloudLibrarySection>(
  CloudLibrarySectionNotifier.new,
);

class LibraryWorkspaceNotifier extends Notifier<LibraryWorkspace> {
  @override
  LibraryWorkspace build() {
    ref.listen<bool>(isCloudLibraryBrowsableProvider, (_, isBrowsable) {
      if (!isBrowsable && state == LibraryWorkspace.cloud) {
        state = LibraryWorkspace.local;
      }
    });
    return LibraryWorkspace.local;
  }

  void select(LibraryWorkspace workspace) {
    if (workspace == LibraryWorkspace.cloud &&
        !ref.read(isCloudLibraryBrowsableProvider)) {
      state = LibraryWorkspace.local;
      return;
    }
    state = workspace;
  }
}

class CloudLibrarySectionNotifier extends Notifier<CloudLibrarySection> {
  @override
  CloudLibrarySection build() {
    ref.listen<LibraryWorkspace>(libraryWorkspaceProvider, (_, workspace) {
      if (workspace != LibraryWorkspace.cloud) {
        state = CloudLibrarySection.home;
      }
    });
    return CloudLibrarySection.home;
  }

  void select(CloudLibrarySection section) {
    state = section;
  }
}

/// The destinations in the library's title strip. `library` is the user's
/// own work from every store; `shared` is what teammates gave them;
/// `community` is the public space; `replays` is the Valorant match
/// recordings on this computer. The active store ([libraryWorkspaceProvider])
/// stays an implementation detail behind the first tab.
enum LibraryTab {
  library,
  shared,
  community,
  replays,
}

/// Whether the Replays tab is open. Replays are files on this computer, not
/// a store, so the tab sits apart from the workspace the others choose.
final replaysTabOpenProvider = StateProvider<bool>((ref) => false);

final libraryTabProvider = Provider<LibraryTab>((ref) {
  if (ref.watch(replaysTabOpenProvider)) return LibraryTab.replays;
  final workspace = ref.watch(libraryWorkspaceProvider);
  if (workspace == LibraryWorkspace.community) {
    return LibraryTab.community;
  }
  final section = ref.watch(cloudLibrarySectionProvider);
  if (workspace == LibraryWorkspace.cloud &&
      section == CloudLibrarySection.sharedWithMe) {
    return LibraryTab.shared;
  }
  return LibraryTab.library;
});
