import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';

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
    ref.listen<bool>(isCloudWorkspaceAvailableProvider, (_, isAvailable) {
      if (!isAvailable && state == LibraryWorkspace.cloud) {
        state = LibraryWorkspace.local;
      }
    });
    return LibraryWorkspace.local;
  }

  void select(LibraryWorkspace workspace) {
    if (workspace == LibraryWorkspace.cloud &&
        !ref.read(isCloudWorkspaceAvailableProvider)) {
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

/// The three destinations in the library's title strip. `library` is the
/// user's own work from every store; `shared` is what teammates gave them;
/// `community` is the public space. The active store ([libraryWorkspaceProvider])
/// stays an implementation detail behind the first tab.
enum LibraryTab {
  library,
  shared,
  community,
}

final libraryTabProvider = Provider<LibraryTab>((ref) {
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
