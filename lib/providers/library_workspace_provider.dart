import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';

enum LibraryWorkspace {
  local,
  cloud,
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
