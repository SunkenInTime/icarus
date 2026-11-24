import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/drawn_cloud_pages_provider.dart';
import 'package:icarus/providers/community_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/widgets/community/community_link.dart';
import 'package:icarus/widgets/community/community_post_card.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/community/report_post_dialog.dart';
import 'package:icarus/widgets/loading_spinner.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

/// The Community post open in the editor, read through its token, or null.
/// The editor shows it with the post's own controls instead of an editor's.
final communityPostViewProvider = StateProvider<CommunityPost?>((ref) => null);

/// Whether the post open in the editor is hidden by reports and opened by a
/// reviewer to decide on it.
final communityPostUnderReviewProvider = StateProvider<bool>((ref) => false);

/// Whether the post a reviewer has open is still in the feed: they put it
/// back before and it was reported again, which doesn't hide it.
final communityPostStillUpProvider = StateProvider<bool>((ref) => false);

/// Points the editor's reads at [post]'s frozen copy.
void showCommunityPost(
  WidgetRef ref,
  CommunityPost post, {
  bool underReview = false,
  bool stillUp = false,
}) {
  ref.read(communityPostViewProvider.notifier).state = post;
  ref.read(communityPostUnderReviewProvider.notifier).state = underReview;
  ref.read(communityPostStillUpProvider.notifier).state = stillUp;
  ref.read(shareLinkViewProvider.notifier).state = (
    strategyPublicId: post.strategyPublicId,
    token: post.shareToken,
  );
}

/// Lets go of the post open in the editor, if [strategyPublicId] is it.
void forgetCommunityPost(WidgetRef ref, String? strategyPublicId) {
  final post = ref.read(communityPostViewProvider);
  if (post == null) return;
  if (strategyPublicId != null && post.strategyPublicId != strategyPublicId) {
    return;
  }
  ref.read(communityPostViewProvider.notifier).state = null;
  ref.read(communityPostUnderReviewProvider.notifier).state = false;
  ref.read(communityPostStillUpProvider.notifier).state = false;
  if (ref.read(shareLinkViewProvider)?.token == post.shareToken) {
    ref.read(shareLinkViewProvider.notifier).state = null;
  }
}

bool _signedIn(WidgetRef ref) {
  final auth = ref.read(authProvider);
  return auth.isAuthenticated && auth.isConvexUserReady;
}

Future<void> _askToSignIn(BuildContext context) {
  return showShadDialog<void>(
    context: context,
    builder: (_) => const AuthDialog(),
  );
}

/// Stars or unstars [post], asking a signed-out reader to sign in first.
Future<void> toggleCommunityStar(
  BuildContext context,
  WidgetRef ref,
  CommunityPost post,
) async {
  if (!_signedIn(ref)) {
    await _askToSignIn(context);
    return;
  }
  final stars = ref.read(communityStarsProvider.notifier);
  final starred = ref.read(communityStarsProvider).isStarred(post.publicId);
  try {
    await stars.setStarred(post, !starred);
  } catch (error, stackTrace) {
    AppErrorReporter.reportWarning(
      'Starring a Community post failed.',
      source: 'toggleCommunityStar',
      error: error,
      stackTrace: stackTrace,
    );
    if (!context.mounted) return;
    Settings.showToast(
      message: context.l10n.communityStarFailed,
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }
}

/// Makes the reader their own copy of [post] to change as they like: in
/// their cloud library when signed in, this computer's when not. On the web
/// with no account there is no library to copy into, so it asks them to
/// sign in. The post itself stays as it is; another copy can always be made.
Future<void> copyCommunityPost(
  BuildContext context,
  WidgetRef ref,
  CommunityPost post,
) async {
  final l10n = context.l10n;
  final signedIn = _signedIn(ref);
  if (!signedIn && !ref.read(platformPolicyProvider).allowsLocalLibrary) {
    await _askToSignIn(context);
    return;
  }
  // Read before the wait: the reader may close the post while it copies.
  final copies = ref.read(communityCopiesProvider.notifier);
  try {
    if (signedIn) {
      final publicId = const Uuid().v4();
      await ref.read(communityRepositoryProvider).copyPost(
            postPublicId: post.publicId,
            publicId: publicId,
          );
      copies.add((strategyPublicId: publicId, postPublicId: post.publicId));
    } else {
      await StrategyImportExportService(ref).importCommunityPost(
        strategyPublicId: post.strategyPublicId,
        shareToken: post.shareToken,
        title: post.title,
      );
    }
    Settings.showToast(
      message: l10n.communityCopiedToast(post.title),
      backgroundColor: Settings.tacticalVioletTheme.secondary,
    );
  } catch (error, stackTrace) {
    AppErrorReporter.reportWarning(
      'Copying a Community post failed.',
      source: 'copyCommunityPost',
      error: error,
      stackTrace: stackTrace,
    );
    Settings.showToast(
      message: isStrategyTooLargeToDuplicateError(error)
          ? l10n.communityCopyTooLarge
          : isRateLimitedError(error)
              ? l10n.communityCopyRateLimited
              : l10n.communityCopyFailed,
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }
}

/// The post's title and author, where the editor puts a strategy's name.
class CommunityPostTitle extends StatelessWidget {
  const CommunityPostTitle({
    super.key,
    required this.post,
    this.height = 30,
    this.hidden = false,
  });

  final CommunityPost post;
  final double height;

  /// Marks a post out of the feed after reports, for its reviewer.
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final author = post.authorName;
    return Container(
      height: height,
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.only(left: 6, right: 12),
      decoration: BoxDecoration(
        color: theme.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CommunityAuthorAvatar(post: post, size: height - 10),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              post.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          if (author != null) ...[
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: theme.mutedForeground),
              ),
            ),
          ],
          if (hidden) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.secondary,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                context.l10n.communityHiddenTag,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The author's Discord picture, or their initial.
class CommunityAuthorAvatar extends StatelessWidget {
  const CommunityAuthorAvatar({super.key, required this.post, this.size = 20});

  final CommunityPost post;
  final double size;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final name = post.authorName?.trim() ?? '';
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final url = post.authorAvatarUrl;
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: theme.secondary,
      foregroundImage: url == null ? null : NetworkImage(url),
      onForegroundImageError: url == null ? null : (_, __) {},
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.5,
          fontWeight: FontWeight.w600,
          color: theme.foreground,
        ),
      ),
    );
  }
}

/// A square raised button for the post's window: open full screen, close.
class CommunityWindowButton extends StatelessWidget {
  const CommunityWindowButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ShadTooltip(
      builder: (context) => Text(tooltip),
      child: ShadButton.secondary(
        width: 40,
        height: 40,
        padding: EdgeInsets.zero,
        decoration: ShadDecoration(
          border: ShadBorder.all(
            color: Settings.tacticalVioletTheme.input,
            radius: BorderRadius.circular(10),
          ),
        ),
        onPressed: onPressed,
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }
}

Future<void> stepCommunityPage(WidgetRef ref, int delta) async {
  final pages = ref.read(drawnCloudPagesProvider)?.pages ?? const [];
  final activeId = ref.read(strategyPageSessionProvider).activePageId;
  final index = pages.indexWhere((page) => page.publicId == activeId);
  final next = index + delta;
  if (index < 0 || next < 0 || next >= pages.length) return;
  await ref.read(strategyProvider.notifier).selectPage(pages[next].publicId);
}

/// Steps through the post's pages: the quick look's pages bar. The quick
/// look binds the left and right arrows to the same steps.
class CommunityPageStepper extends ConsumerWidget {
  const CommunityPageStepper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = Settings.tacticalVioletTheme;
    final pages = ref.watch(drawnCloudPagesProvider)?.pages ?? const [];
    final activeId = ref.watch(
      strategyPageSessionProvider.select((session) => session.activePageId),
    );
    final index = pages.indexWhere((page) => page.publicId == activeId);
    final l10n = context.l10n;
    Future<void> step(int delta) => stepCommunityPage(ref, delta);

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.border, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShadIconButton.ghost(
            width: 32,
            height: 32,
            enabled: index > 0,
            onPressed: () => step(-1),
            icon: const Icon(LucideIcons.chevronLeft, size: 18),
          ),
          const SizedBox(width: 8),
          if (index >= 0) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                pages[index].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              l10n.communityPageOf(index + 1, pages.length),
              style: TextStyle(fontSize: 14, color: theme.mutedForeground),
            ),
          ],
          const SizedBox(width: 8),
          ShadIconButton.ghost(
            width: 32,
            height: 32,
            enabled: index >= 0 && index < pages.length - 1,
            onPressed: () => step(1),
            icon: const Icon(LucideIcons.chevronRight, size: 18),
          ),
        ],
      ),
    );
  }
}

/// The post's own controls, at the foot of the map opposite the pages:
/// more (copy link, report), its star, and Save to My Library.
class CommunityPostActions extends ConsumerStatefulWidget {
  const CommunityPostActions({
    super.key,
    required this.post,
    required this.onOpenCopy,
  });

  final CommunityPost post;

  /// Leaves the post and opens the reader's copy [strategyPublicId].
  final ValueChanged<String> onOpenCopy;

  @override
  ConsumerState<CommunityPostActions> createState() =>
      _CommunityPostActionsState();
}

class _CommunityPostActionsState extends ConsumerState<CommunityPostActions> {
  final _menu = ShadPopoverController();
  bool _copying = false;

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    setState(() => _copying = true);
    try {
      await copyCommunityPost(context, ref, widget.post);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<void> _report() async {
    if (!_signedIn(ref)) {
      await _askToSignIn(context);
      return;
    }
    if (!mounted) return;
    await showShadDialog<void>(
      context: context,
      builder: (_) => ReportPostDialog(post: widget.post),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final post = widget.post;
    final stars = ref.watch(communityStarsProvider);
    final copy = ref.watch(
      communityCopyByPostProvider.select((byPost) => byPost[post.publicId]),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShadPopover(
          controller: _menu,
          padding: const EdgeInsets.all(6),
          anchor: const ShadAnchor(
            offset: Offset(0, -8),
            childAlignment: Alignment.bottomLeft,
            overlayAlignment: Alignment.topLeft,
          ),
          popover: (context) => ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 168),
            child: IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MenuButton(
                    icon: LucideIcons.link,
                    label: l10n.communityCopyLink,
                    onPressed: () {
                      _menu.hide();
                      copyCommunityPostLink(context, post);
                    },
                  ),
                  if (copy != null)
                    _MenuButton(
                      icon: LucideIcons.copy,
                      label: l10n.communityMakeAnotherCopy,
                      onPressed: () {
                        _menu.hide();
                        unawaited(_copy());
                      },
                    ),
                  _MenuButton(
                    icon: LucideIcons.flag,
                    label: l10n.communityReport,
                    onPressed: () {
                      _menu.hide();
                      unawaited(_report());
                    },
                  ),
                ],
              ),
            ),
          ),
          child: ShadIconButton.secondary(
            key: const ValueKey('community-post-more'),
            width: 36,
            height: 36,
            onPressed: _menu.toggle,
            icon: const Icon(LucideIcons.ellipsis, size: 18),
          ),
        ),
        const SizedBox(width: 6),
        CommunityStarButton(
          height: 36,
          starred: stars.isStarred(post.publicId),
          count: stars.countFor(post),
          onPressed: () => toggleCommunityStar(context, ref, post),
        ),
        const SizedBox(width: 6),
        // Starring keeps a post; this makes the reader's own copy to
        // change, and once they have one, takes them to it.
        ShadButton(
          key: const ValueKey('community-copy'),
          height: 36,
          enabled: !_copying,
          onPressed: copy == null ? _copy : () => widget.onOpenCopy(copy),
          leading: _copying
              ? const SizedBox.square(
                  dimension: 16,
                  child: LoadingSpinner(strokeWidth: 2),
                )
              : Icon(
                  copy == null ? LucideIcons.copy : LucideIcons.arrowUpRight,
                  size: 16,
                ),
          child: Text(
            copy == null ? l10n.communityMakeCopy : l10n.communityOpenYourCopy,
          ),
        ),
      ],
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ShadButton.ghost(
      height: 32,
      mainAxisAlignment: MainAxisAlignment.start,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      gap: 8,
      onPressed: onPressed,
      leading: Icon(
        icon,
        size: 16,
        color: Settings.tacticalVioletTheme.mutedForeground,
      ),
      child: Text(
        label,
        style: TextStyle(color: Settings.tacticalVioletTheme.foreground),
      ),
    );
  }
}
