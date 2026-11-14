import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/community/community_post_view.dart';

/// Opens [post] over the library: a quick look, or the full view-only
/// editor when [expanded]. A post [underReview] opens full screen with a
/// reviewer's controls.
Future<void> openCommunityPost(
  WidgetRef ref,
  CommunityPost post, {
  bool expanded = false,
  bool underReview = false,
}) async {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) return;
  showCommunityPost(ref, post, underReview: underReview);
  await navigator.push(
    StrategyView.communityRoute(post, expanded: expanded || underReview),
  );
}
