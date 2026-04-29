import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';

final shareLinkControllerProvider =
    NotifierProvider<ShareLinkController, String?>(ShareLinkController.new);

class ShareLinkController extends Notifier<String?> {
  Future<bool> handleIncomingUri(Uri uri, {required String source}) async {
    final isShareLink = uri.scheme.toLowerCase() == 'icarus' &&
        (uri.host.toLowerCase() == 'share' ||
            uri.pathSegments.contains('share'));
    if (!isShareLink) {
      return false;
    }

    final token = uri.queryParameters['token'];
    if (token == null || token.isEmpty) {
      Settings.showToast(
        message: 'That share link is missing a token.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return true;
    }

    state = token;
    await redeemPendingIfPossible(source: source);
    return true;
  }

  Future<void> redeemPendingIfPossible({String source = 'pending'}) async {
    final token = state;
    if (token == null || token.isEmpty) {
      return;
    }

    final auth = ref.read(authProvider);
    if (!auth.isAuthenticated || !auth.isConvexUserReady) {
      Settings.showToast(
        message: 'Sign in to redeem shared links.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
      return;
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
    } catch (error, stackTrace) {
      if (isConvexUnauthenticatedError(error)) {
        await ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'share_link:$source',
              error: error,
              stackTrace: stackTrace,
            );
        return;
      }
      Settings.showToast(
        message: 'Failed to redeem share link.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  Future<void> redeemToken(String token) async {
    state = token;
    await redeemPendingIfPossible(source: 'manual');
  }

  @override
  String? build() => null;
}
