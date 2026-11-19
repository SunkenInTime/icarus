import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/community_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/community/community_post_view.dart';

/// Opens the post a feed card shows. The card may be minutes old and its
/// author may have updated the post since, which replaces the copy it
/// shows, so the post is read again first: one small read per open, and a
/// post taken down since is said so instead of opening empty.
Future<void> openCommunityPostFromCard(
  WidgetRef ref,
  CommunityPost card,
) async {
  final l10n = ref.read(l10nProvider);
  final feed = ref.read(communityFeedProvider.notifier);
  final ({CommunityPost post, CommunityPostStatus status})? found;
  try {
    found =
        await ref.read(communityRepositoryProvider).fetchPost(card.publicId);
  } catch (error, stackTrace) {
    AppErrorReporter.reportWarning(
      'Reading a Community post to open it failed.',
      source: 'openCommunityPostFromCard',
      error: error,
      stackTrace: stackTrace,
    );
    Settings.showToast(
      message: l10n.communityLoadFailedTitle,
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
    return;
  }
  if (found == null || found.status != CommunityPostStatus.listed) {
    feed.forget(card.publicId);
    Settings.showToast(
      message: l10n.communityPostTakenDown,
      backgroundColor: Settings.tacticalVioletTheme.secondary,
    );
    return;
  }
  // The card left the screen while its post was read: a filter changed.
  if (!ref.context.mounted) return;
  await openCommunityPost(ref, found.post);
}

/// Opens [post] over the library: a quick look, or the full view-only
/// editor when [expanded]. A post [underReview] opens full screen with a
/// reviewer's controls; [stillUp] when reports haven't hidden it.
Future<void> openCommunityPost(
  WidgetRef ref,
  CommunityPost post, {
  bool expanded = false,
  bool underReview = false,
  bool stillUp = false,
}) async {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) return;
  showCommunityPost(ref, post, underReview: underReview, stillUp: stillUp);
  await navigator.push(
    StrategyView.communityRoute(post, expanded: expanded || underReview),
  );
}
