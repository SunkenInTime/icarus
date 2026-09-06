import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';

final libraryNavigationProvider = Provider<LibraryNavigation>((ref) {
  return LibraryNavigation(ref);
});

/// Moves between the title-strip tabs. Each call lands at the tab's root.
class LibraryNavigation {
  LibraryNavigation(this._ref);

  final Ref _ref;

  /// Opens My Library. The cloud is the active store when it is reachable so
  /// new strategies and folders land online; otherwise the local library is.
  void showLibrary() {
    final cloudAvailable = _ref.read(isCloudWorkspaceAvailableProvider);
    _ref.read(libraryWorkspaceProvider.notifier).select(
          cloudAvailable ? LibraryWorkspace.cloud : LibraryWorkspace.local,
        );
    _ref
        .read(cloudLibrarySectionProvider.notifier)
        .select(CloudLibrarySection.home);
    final folders = _ref.read(folderProvider.notifier);
    folders.updateWorkspaceFolderId(LibraryWorkspace.local, null);
    folders.updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
  }

  /// Opens Shared. Returns false, and changes nothing, when the cloud is not
  /// reachable so the caller can ask the user to sign in.
  bool showShared() {
    if (!_ref.read(isCloudWorkspaceAvailableProvider)) {
      return false;
    }
    _ref.read(libraryWorkspaceProvider.notifier).select(LibraryWorkspace.cloud);
    _ref
        .read(cloudLibrarySectionProvider.notifier)
        .select(CloudLibrarySection.sharedWithMe);
    _ref
        .read(folderProvider.notifier)
        .updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
    return true;
  }

  void showCommunity() {
    _ref
        .read(libraryWorkspaceProvider.notifier)
        .select(LibraryWorkspace.community);
    _ref.read(folderProvider.notifier).updateID(null);
  }
}
