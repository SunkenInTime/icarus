import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/share/share_link_format.dart';

final shareLinkControllerProvider =
    NotifierProvider<ShareLinkController, String?>(ShareLinkController.new);

class ShareLinkController extends Notifier<String?> {
  Future<bool> handleIncomingUri(Uri uri, {required String source}) async {
    if (!isIcarusShareUri(uri)) {
      return false;
    }

    final token = extractIcarusShareCode(uri.toString());
    if (token == null || token.isEmpty) {
      Settings.showToast(
        message: 'That share link is missing a share code.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return true;
    }

    state = token;
    await redeemPendingIfPossible(source: source);
    return true;
  }

  Future<bool> redeemPendingIfPossible({String source = 'pending'}) async {
    final token = state;
    if (token == null || token.isEmpty) {
      return false;
    }

    final auth = ref.read(authProvider);
    if (!auth.isAuthenticated || !auth.isConvexUserReady) {
      Settings.showToast(
        message: 'Sign in to redeem shared links.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
      return false;
    }

    try {
      final response = await ref
          .read(convexStrategyRepositoryProvider)
          .redeemShareLink(token);
      state = null;

      ref
          .read(libraryWorkspaceProvider.notifier)
          .select(LibraryWorkspace.cloud);
      ref
          .read(cloudLibrarySectionProvider.notifier)
          .select(CloudLibrarySection.sharedWithMe);
      ref.read(folderProvider.notifier).updateWorkspaceFolderId(
            LibraryWorkspace.cloud,
            response['folderPublicId'] as String?,
          );

      final targetType = response['targetType'] as String? ?? 'item';
      Settings.showToast(
        message: targetType == 'folder'
            ? 'Shared folder added to your library.'
            : 'Shared strategy added to your library.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
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
      Settings.showToast(
        message: 'Failed to redeem share link.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return false;
    }
  }

  Future<bool> redeemToken(String token) async {
    state = token;
    return redeemPendingIfPossible(source: 'manual');
  }

  @override
  String? build() => null;
}
