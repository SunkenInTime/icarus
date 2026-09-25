import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/share/current_share_origin.dart';
import 'package:icarus/share/pending_share_code_store.dart';
import 'package:icarus/share/share_link_format.dart';

/// Where a share code waits for sign-in. Overridden in tests.
final pendingShareCodeStoreProvider = Provider<PendingShareCodeStore>(
  (ref) => createPendingShareCodeStore(),
);

/// A cloud strategy a redeemed share link asks to open. The navigation layer
/// (MouseNavigation, which owns the unsaved-changes guard) opens it and
/// clears this back to null.
final sharedStrategyToOpenProvider = StateProvider<String?>((ref) => null);

final shareLinkControllerProvider =
    NotifierProvider<ShareLinkController, String?>(ShareLinkController.new);

class ShareLinkController extends Notifier<String?> {
  Future<bool> handleIncomingUri(Uri uri, {required String source}) async {
    final currentOrigin = currentShareOrigin();
    if (!isIcarusShareUri(uri, currentOrigin: currentOrigin)) {
      return false;
    }

    final token = extractIcarusShareCode(
      uri.toString(),
      currentOrigin: currentOrigin,
    );
    if (token == null || token.isEmpty) {
      Settings.showToast(
        message: 'That share link is missing a share code.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return true;
    }

    _hold(token);
    await redeemPendingIfPossible(source: source);
    return true;
  }

  /// Set [showFailureToasts] to false when the caller (e.g. a dialog)
  /// presents failures inline itself; success toasts always show.
  Future<bool> redeemPendingIfPossible({
    String source = 'pending',
    bool showFailureToasts = true,
  }) async {
    final token = state;
    final generation = _generation;
    if (token == null || token.isEmpty) {
      return false;
    }

    final auth = ref.read(authProvider);
    if (!auth.isAuthenticated || !auth.isConvexUserReady) {
      // The code stays held in the pending store; the app redeems it once
      // the cloud is ready. Only a user with no session at all needs telling:
      // right after a page load a saved session is restored but its cloud
      // setup is still running, and an auth incident has its own prompt.
      final signedOut = !auth.isAuthenticated && !auth.isLoading;
      if (signedOut && showFailureToasts) {
        Settings.showToast(
          message: 'Sign in to redeem shared links.',
          backgroundColor: Settings.tacticalVioletTheme.primary,
        );
      }
      return false;
    }

    try {
      final response = await ref
          .read(convexStrategyRepositoryProvider)
          .redeemShareLink(token);
      _release(generation);

      // The library lands where the target now lives: the owner's own
      // library, or Shared for anyone the link was shared with.
      ref
          .read(libraryWorkspaceProvider.notifier)
          .select(LibraryWorkspace.cloud);
      ref.read(cloudLibrarySectionProvider.notifier).select(
            response.isOwner
                ? CloudLibrarySection.home
                : CloudLibrarySection.sharedWithMe,
          );
      ref.read(folderProvider.notifier).updateWorkspaceFolderId(
            LibraryWorkspace.cloud,
            response.folderPublicId,
          );

      // Only a link that granted something is news; one for a strategy or
      // folder the user could already open just takes them there.
      if (!response.alreadyHadAccess) {
        Settings.showToast(
          message: response.targetType == 'folder'
              ? 'Shared folder added to your library.'
              : 'Shared strategy added to your library.',
          backgroundColor: Settings.tacticalVioletTheme.primary,
        );
      }
      final strategyPublicId = response.strategyPublicId;
      if (response.targetType == 'strategy' && strategyPublicId != null) {
        ref.read(sharedStrategyToOpenProvider.notifier).state =
            strategyPublicId;
      }
      return true;
    } catch (error, stackTrace) {
      if (isConvexUnauthenticatedError(error)) {
        await ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'share_link:$source',
              error: error,
              stackTrace: stackTrace,
            );
        return false;
      }
      // The user is told (here, or inline by the dialog), so the code is done
      // with. Keeping it would replay the failure on every web page reload.
      _release(generation);
      if (showFailureToasts) {
        Settings.showToast(
          message: 'Failed to redeem share link.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
      }
      return false;
    }
  }

  Future<bool> redeemToken(String token) async {
    _hold(token);
    return redeemPendingIfPossible(source: 'manual', showFailureToasts: false);
  }

  /// Bumped each time a code becomes pending. A redeem attempt remembers the
  /// generation it started with and only clears that one, so a slow attempt
  /// finishing late cannot clear a newer code that arrived meanwhile.
  int _generation = 0;

  void _hold(String token) {
    _generation += 1;
    state = token;
    ref.read(pendingShareCodeStoreProvider).write(token);
  }

  void _release(int generation) {
    if (generation != _generation) {
      return;
    }
    state = null;
    ref.read(pendingShareCodeStoreProvider).clear();
  }

  /// Starts with any code a previous page load left waiting: on web, the one
  /// opened before a Discord sign-in navigated the tab away.
  @override
  String? build() => ref.read(pendingShareCodeStoreProvider).read();
}
