import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/services/browser_url.dart';
import 'package:icarus/share/current_share_origin.dart';
import 'package:icarus/share/pending_share_code_store.dart';
import 'package:icarus/share/share_link_format.dart';

/// Where a share code waits for sign-in. Overridden in tests.
final pendingShareCodeStoreProvider = Provider<PendingShareCodeStore>(
  (ref) => createPendingShareCodeStore(),
);

/// The page's own URL on web (where a share link arrives), null on native.
/// Overridden in tests.
final sharePageUrlProvider = Provider<Uri?>((ref) => kIsWeb ? Uri.base : null);

/// Replaces the address bar URL without navigating. Overridden in tests.
final replaceBrowserUrlProvider =
    Provider<void Function(Uri url)>((ref) => replaceBrowserUrl);

/// A cloud strategy a redeemed share link asks to open. The navigation layer
/// (MouseNavigation, which owns the unsaved-changes guard) opens it and
/// clears this back to null.
final sharedStrategyToOpenProvider = StateProvider<String?>((ref) => null);

/// A strategy open through a share link nobody has redeemed on this device:
/// the link is the reader's only access, whether they are signed out or
/// signed in without having added it. The editor reads with [token] and
/// offers sign-in or "Add to my library". Cleared once the link is
/// redeemed.
typedef ShareLinkView = ({String strategyPublicId, String token});

final shareLinkViewProvider = StateProvider<ShareLinkView?>((ref) => null);

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
  ///
  /// A signed-in person who opens a view link for a strategy they can't
  /// open yet reads it through the link first, and adds it with
  /// [addViewedLinkToLibrary]. [explicit] is set when they already asked
  /// to add it (the Add button, or pasting the link into Add Shared Item).
  Future<bool> redeemPendingIfPossible({
    String source = 'pending',
    bool showFailureToasts = true,
    bool explicit = false,
  }) async {
    final token = state;
    final generation = _generation;
    if (token == null || token.isEmpty) {
      return false;
    }

    final auth = ref.read(authProvider);
    if (!auth.isAuthenticated && !auth.isLoading) {
      return _viewWithoutAccount(token, generation);
    }
    if (!auth.isAuthenticated || !auth.isConvexUserReady) {
      // The code stays held in the pending store; the app redeems it once
      // the cloud is ready: right after a page load a saved session is
      // restored but its cloud setup is still running, and an auth incident
      // has its own prompt.
      return false;
    }

    if (!explicit) {
      final readOnly = await _viewSignedInIfNew(token, generation);
      if (readOnly != null) return readOnly;
    }

    try {
      final response = await ref
          .read(convexStrategyRepositoryProvider)
          .redeemShareLink(token);
      _release(generation);
      ref.read(shareLinkViewProvider.notifier).state = null;

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

  /// Opens a strategy link for a reader with no account, read-only. The code
  /// stays held, and the page keeps its /share/<code> URL, so a reload opens
  /// it again. Signing in joins an edit link; a view link stays read-only
  /// until the reader adds it (see [_viewSignedInIfNew]).
  Future<bool> _viewWithoutAccount(String token, int generation) async {
    if (ref.read(shareLinkViewProvider)?.token == token) {
      return true; // Already open; an auth update asked again.
    }

    try {
      final strategyPublicId = await ref
          .read(convexStrategyRepositoryProvider)
          .resolveSharedStrategy(token);
      if (_superseded(token, generation)) return false;
      if (strategyPublicId == null) {
        // Browsing a folder needs the cloud library, which needs an account.
        Settings.showToast(
          message: 'Sign in to open this shared folder.',
          backgroundColor: Settings.tacticalVioletTheme.primary,
        );
        return false;
      }
      ref.read(shareLinkViewProvider.notifier).state =
          (strategyPublicId: strategyPublicId, token: token);
      ref.read(sharedStrategyToOpenProvider.notifier).state = strategyPublicId;
      return true;
    } catch (error) {
      if (_superseded(token, generation)) return false;
      final revoked = isShareLinkRevokedError(error);
      if (revoked || isTypedConvexNotFoundError(error)) {
        _release(generation);
        Settings.showToast(
          message: revoked
              ? 'This share link was disabled by its owner.'
              : 'This share link does not exist.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return false;
      }
      // Most likely offline. The code stays held for a reload to retry.
      Settings.showToast(
        message: 'Could not open the shared strategy. Check your connection '
            'and reload.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return false;
    }
  }

  /// For a signed-in person, opens a strategy view link read-only when it
  /// would give them something new, the way it opens for someone signed
  /// out; they add it to their library from the editor. Returns null when
  /// the link should be redeemed right away instead: an edit link, a
  /// folder (a folder can only be browsed by its members), or a strategy
  /// they can already open.
  Future<bool?> _viewSignedInIfNew(String token, int generation) async {
    final SharePreview preview;
    try {
      preview =
          await ref.read(convexStrategyRepositoryProvider).previewShareLink(
                token,
              );
    } catch (error, stackTrace) {
      // A failed look is never a reason to join: the person asked to open
      // a link, not to add it.
      if (_superseded(token, generation)) return false;
      if (isConvexUnauthenticatedError(error)) {
        await ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'share_link:preview',
              error: error,
              stackTrace: stackTrace,
            );
        return false;
      }
      final revoked = isShareLinkRevokedError(error);
      if (revoked || isTypedConvexNotFoundError(error)) {
        _release(generation);
        Settings.showToast(
          message: revoked
              ? 'This share link was disabled by its owner.'
              : 'This share link does not exist.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return false;
      }
      // Most likely offline. The code stays held, so a reload or the next
      // sign-in update tries again.
      Settings.showToast(
        message: 'Could not open the shared link. Check your connection and '
            'try again.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return false;
    }
    if (_superseded(token, generation)) return false;
    if (preview.targetType != 'strategy' ||
        preview.linkRole != 'viewer' ||
        preview.myRole != null) {
      return null;
    }
    if (ref.read(shareLinkViewProvider)?.token == token) {
      return true; // Already open; an auth update asked again.
    }
    ref.read(shareLinkViewProvider.notifier).state =
        (strategyPublicId: preview.publicId, token: token);
    ref.read(sharedStrategyToOpenProvider.notifier).state = preview.publicId;
    return true;
  }

  /// Adds the strategy open through a view link to the reader's library.
  Future<bool> addViewedLinkToLibrary() async {
    final view = ref.read(shareLinkViewProvider);
    if (view == null) return false;
    if (state != view.token) {
      _hold(view.token);
    }
    return redeemPendingIfPossible(source: 'add_to_library', explicit: true);
  }

  /// Whether [token]'s attempt is stale: a newer code arrived, or sign-in
  /// redeemed this one while the attempt was waiting on the server.
  bool _superseded(String token, int generation) =>
      generation != _generation || state != token;

  /// Drops the link a signed-out reader was viewing through, once it stopped
  /// working: there is nothing left to open or to redeem.
  void forgetViewedLink() {
    final view = ref.read(shareLinkViewProvider);
    ref.read(shareLinkViewProvider.notifier).state = null;
    if (view != null && state == view.token) {
      _release(_generation);
    }
  }

  Future<bool> redeemToken(String token) async {
    _hold(token);
    return redeemPendingIfPossible(
      source: 'manual',
      showFailureToasts: false,
      explicit: true,
    );
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
    _dropSharePathFromPageUrl();
  }

  /// Once a code is done with, the page must not keep its /share/<code> URL,
  /// or every reload would redeem it again (and, after the link is disabled,
  /// report a failure to someone who still has access). The fragment stays:
  /// Flutter's router keeps the open route there.
  void _dropSharePathFromPageUrl() {
    final page = ref.read(sharePageUrlProvider);
    if (page == null ||
        !isIcarusShareUri(page, currentOrigin: currentShareOrigin())) {
      return;
    }
    ref.read(replaceBrowserUrlProvider)(Uri(
      scheme: page.scheme,
      host: page.host,
      port: page.hasPort ? page.port : null,
      path: '/',
      fragment: page.fragment.isEmpty ? null : page.fragment,
    ));
  }

  /// Starts with any code a previous page load left waiting: on web, the one
  /// opened before a Discord sign-in navigated the tab away.
  @override
  String? build() => ref.read(pendingShareCodeStoreProvider).read();
}
