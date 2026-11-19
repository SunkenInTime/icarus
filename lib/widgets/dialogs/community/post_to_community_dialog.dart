import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/community_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/widgets/community/community_link.dart';
import 'package:icarus/widgets/community/community_post_card.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/loading_spinner.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

const double _cardWidth = 270;
const double _cardHeight = strategyTileGridMainAxisExtent;
const double _bodyWidth = 610;

/// Room for the card and the words beside it, past the dialog's own cap.
const _dialogConstraints = BoxConstraints(maxWidth: _bodyWidth + 48);

/// Shows [strategyPublicId]'s Community dialog: the form to post it, or,
/// once it is posted, how the post is doing.
Future<void> showPostToCommunityDialog(
  BuildContext context,
  String strategyPublicId,
) {
  return showShadDialog<void>(
    context: context,
    builder: (_) => PostToCommunityDialog(strategyPublicId: strategyPublicId),
  );
}

/// One dialog for posting a strategy and for its post afterwards, so the
/// form turns into the posted view in place when Post lands.
class PostToCommunityDialog extends ConsumerStatefulWidget {
  const PostToCommunityDialog({super.key, required this.strategyPublicId});

  final String strategyPublicId;

  @override
  ConsumerState<PostToCommunityDialog> createState() =>
      _PostToCommunityDialogState();
}

class _PostToCommunityDialogState extends ConsumerState<PostToCommunityDialog> {
  /// Chosen now so the preview's picture is the one the post gets (the
  /// picture is picked from the post's id), and so a retried Post finds the
  /// post the first try made.
  final String _postPublicId = const Uuid().v4();

  /// Set once Post lands, until the signed-in user's posts list it.
  bool _posted = false;

  @override
  Widget build(BuildContext context) {
    final mine = ref.watch(
      myPostsByStrategyProvider.select(
        (posts) => posts[widget.strategyPublicId],
      ),
    );
    if (mine != null) return _PostedView(mine: mine);
    if (_posted) return const _WaitingView();
    return _PostForm(
      strategyPublicId: widget.strategyPublicId,
      postPublicId: _postPublicId,
      onPosted: () => setState(() => _posted = true),
    );
  }
}

class _WaitingView extends StatelessWidget {
  const _WaitingView();

  @override
  Widget build(BuildContext context) {
    return const ShadDialog(
      constraints: _dialogConstraints,
      child: SizedBox(
        width: _bodyWidth,
        height: _cardHeight,
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: LoadingSpinner(strokeWidth: 2),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Posting
// ---------------------------------------------------------------------------

final _postPreviewProvider = FutureProvider.autoDispose
    .family<CommunityPostPreview?, String>((ref, strategyPublicId) {
  return ref
      .read(communityRepositoryProvider)
      .fetchPostPreview(strategyPublicId);
});

class _PostForm extends ConsumerStatefulWidget {
  const _PostForm({
    required this.strategyPublicId,
    required this.postPublicId,
    required this.onPosted,
  });

  final String strategyPublicId;
  final String postPublicId;
  final VoidCallback onPosted;

  @override
  ConsumerState<_PostForm> createState() => _PostFormState();
}

class _PostFormState extends ConsumerState<_PostForm> {
  final _title = TextEditingController();
  bool _titleFilled = false;
  bool _posting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
    // A failed read of who is posting is tried again each time this opens.
    Future.microtask(() {
      if (mounted && ref.read(communityViewerProvider).hasError) {
        ref.invalidate(communityViewerProvider);
      }
    });
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final l10n = context.l10n;
    setState(() {
      _posting = true;
      _error = null;
    });
    // Read before the wait: the dialog may be closed while it posts.
    final feed = ref.read(communityFeedProvider.notifier);
    try {
      await ref.read(communityRepositoryProvider).publish(
            postPublicId: widget.postPublicId,
            strategyPublicId: widget.strategyPublicId,
            title: _title.text,
          );
      // So the author finds their post in the feed straight away.
      unawaited(feed.readAgain());
      if (!mounted) return;
      widget.onPosted();
    } catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'Posting a strategy to Community failed.',
        source: 'PostToCommunityDialog.post',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _posting = false;
        _error = isRateLimitedError(error)
            ? l10n.communityPostRateLimited
            : l10n.communityPostFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = ref.watch(_postPreviewProvider(widget.strategyPublicId));
    final viewer = ref.watch(communityViewerProvider);
    final data = preview.valueOrNull;
    if (data != null && !_titleFilled) {
      _titleFilled = true;
      _title.text = data.name.length > communityMaxTitleLength
          ? data.name.substring(0, communityMaxTitleLength)
          : data.name;
    }
    final canPost = viewer.valueOrNull?.canPost ?? false;
    final title = _title.text.trim();
    final ready = data != null && canPost && title.isNotEmpty && !_posting;
    final theme = ShadTheme.of(context);

    final Widget body;
    if (preview.hasError ||
        viewer.hasError ||
        (preview.hasValue && data == null)) {
      body = _Message(text: l10n.communityPostPreviewFailed);
    } else if (data == null || !viewer.hasValue) {
      body = const _Message(spinner: true);
    } else {
      final authorName = viewer.value!.authorName;
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardFrame(
            child: CommunityPostCard(
              post: CommunityPost(
                publicId: widget.postPublicId,
                title: title.isEmpty ? data.name : title,
                map: data.map,
                side: data.side,
                agents: data.agents,
                authorName: authorName,
                authorAvatarUrl: null,
                starCount: 0,
                pageCount: 0,
                lineupCount: 0,
                publishedAt: DateTime.now(),
                strategyPublicId: widget.strategyPublicId,
                shareToken: '',
              ),
              starred: false,
              starCount: 0,
              onOpen: () {},
              onStar: () {},
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.communityPostTitleLabel,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextEditingShortcutScope(
                  child: ShadInput(
                    key: const ValueKey('community-post-title'),
                    controller: _title,
                    maxLength: communityMaxTitleLength,
                    enabled: !_posting,
                    onSubmitted: (_) {
                      if (ready) _post();
                    },
                  ),
                ),
                const SizedBox(height: 16),
                _Bullet(l10n.communityPostAsItIsNow),
                _Bullet(l10n.communityPostMediaPublic),
                _Bullet(
                  authorName == null
                      ? l10n.communityPostNoName
                      : l10n.communityPostYourName(authorName),
                ),
                if (!canPost)
                  _ErrorText(l10n.communityPostNotAllowed)
                else if (_error case final error?)
                  _ErrorText(error),
              ],
            ),
          ),
        ],
      );
    }

    return ShadDialog(
      constraints: _dialogConstraints,
      title: Text(
        data == null
            ? l10n.communityPostDialogTitleLoading
            : l10n.communityPostDialogTitle(data.name),
      ),
      description: Text(l10n.communityPostDialogSubtitle),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        ShadButton(
          key: const ValueKey('community-post-confirm'),
          enabled: ready,
          onPressed: _post,
          leading: _posting
              ? SizedBox.square(
                  dimension: 14,
                  child: LoadingSpinner(
                    strokeWidth: 2,
                    color: theme.colorScheme.primaryForeground,
                  ),
                )
              : const Icon(LucideIcons.globe, size: 16),
          child: Text(l10n.communityPostConfirm),
        ),
      ],
      child: SizedBox(width: _bodyWidth, child: body),
    );
  }
}

// ---------------------------------------------------------------------------
// Posted
// ---------------------------------------------------------------------------

/// Whether the strategy changed since its post was last updated: null while
/// unknown, and [_SourceState.deleted] once the strategy is gone.
enum _SourceState { same, changed, deleted }

final _sourceStateProvider = FutureProvider.autoDispose
    .family<_SourceState, String>((ref, postPublicId) async {
  final changed = await ref
      .read(communityRepositoryProvider)
      .fetchSourceChanged(postPublicId);
  return switch (changed) {
    null => _SourceState.deleted,
    true => _SourceState.changed,
    false => _SourceState.same,
  };
});

class _PostedView extends ConsumerStatefulWidget {
  const _PostedView({required this.mine});

  final MyCommunityPost mine;

  @override
  ConsumerState<_PostedView> createState() => _PostedViewState();
}

class _PostedViewState extends ConsumerState<_PostedView> {
  bool _updating = false;
  bool _takingDown = false;
  String? _error;

  CommunityPost get _post => widget.mine.post;

  Future<void> _update() async {
    final l10n = context.l10n;
    setState(() {
      _updating = true;
      _error = null;
    });
    final feed = ref.read(communityFeedProvider.notifier);
    try {
      await ref
          .read(communityRepositoryProvider)
          .updatePost(postPublicId: _post.publicId, refresh: true);
      unawaited(feed.readAgain());
      if (!mounted) return;
      ref.invalidate(_sourceStateProvider(_post.publicId));
      Settings.showToast(
        message: l10n.communityPostUpdated,
        backgroundColor: Settings.tacticalVioletTheme.secondary,
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'Updating a Community post failed.',
        source: 'PostToCommunityDialog.update',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _error = l10n.communityPostUpdateFailed);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _takeDown() async {
    final l10n = context.l10n;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (_) => ConfirmAlertDialog(
        title: l10n.communityTakeDownConfirmTitle,
        content: l10n.communityTakeDownConfirmBody,
        confirmText: l10n.communityTakeDown,
        isDestructive: true,
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _takingDown = true;
      _error = null;
    });
    final feed = ref.read(communityFeedProvider.notifier);
    try {
      await ref.read(communityRepositoryProvider).takeDown(_post.publicId);
      feed.forget(_post.publicId);
      if (!mounted) return;
      Navigator.of(context).pop();
      Settings.showToast(
        message: l10n.communityTakenDown,
        backgroundColor: Settings.tacticalVioletTheme.secondary,
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'Taking down a Community post failed.',
        source: 'PostToCommunityDialog.takeDown',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _takingDown = false;
        _error = l10n.communityTakeDownFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const theme = Settings.tacticalVioletTheme;
    final post = _post;
    final source = ref.watch(_sourceStateProvider(post.publicId));
    final busy = _updating || _takingDown;
    final author = post.authorName;
    final when = _whenInSentence(l10n, post.publishedAt);
    final updatedWhen = _whenInSentence(l10n, widget.mine.updatedAt);

    return ShadDialog(
      constraints: _dialogConstraints,
      title: Text(l10n.communityPostedTitle(post.title)),
      description: Text(
        author == null
            ? l10n.communityPostedSubtitleAnonymous(when)
            : l10n.communityPostedSubtitle(when, author),
      ),
      child: SizedBox(
        width: _bodyWidth,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardFrame(
              child: CommunityPostCard(
                post: post,
                starred: false,
                starCount: post.starCount,
                onOpen: () {},
                onStar: () {},
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _Stat(
                          value: post.starCount,
                          label: l10n.communityStarsLabel,
                        ),
                        const SizedBox(width: 24),
                        _Stat(
                          value: widget.mine.copyCount,
                          label: l10n.communityCopiesSavedLabel,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Divider(height: 1, color: theme.border),
                    const SizedBox(height: 14),
                    if (widget.mine.status == CommunityPostStatus.hidden) ...[
                      _Note(l10n.communityPostedHidden),
                      const SizedBox(height: 14),
                    ],
                    switch (widget.mine.status == CommunityPostStatus.hidden
                        ? null
                        : source.valueOrNull) {
                      _SourceState.changed => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Note(l10n.communityPostedChanged(updatedWhen)),
                            const SizedBox(height: 14),
                            ShadButton(
                              key: const ValueKey('community-post-update'),
                              enabled: !busy,
                              onPressed: _update,
                              leading: _updating
                                  ? SizedBox.square(
                                      dimension: 14,
                                      child: LoadingSpinner(
                                        strokeWidth: 2,
                                        color: theme.primaryForeground,
                                      ),
                                    )
                                  : null,
                              child: Text(l10n.communityUpdatePost),
                            ),
                            const SizedBox(height: 14),
                          ],
                        ),
                      _SourceState.deleted => Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: _Note(l10n.communityPostedSourceDeleted),
                        ),
                      // A hidden post can't be changed, so it offers no update.
                      null
                          when widget.mine.status ==
                              CommunityPostStatus.hidden =>
                        const SizedBox.shrink(),
                      _SourceState.same || null => Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: _Note(l10n.communityPostedSame(updatedWhen)),
                        ),
                    },
                    // A hidden post's link is off and it can't be taken down
                    // until a reviewer decides, so it offers neither.
                    if (widget.mine.status != CommunityPostStatus.hidden)
                      Row(
                        children: [
                          Expanded(
                            child: ShadButton.secondary(
                              key: const ValueKey('community-post-copy-link'),
                              onPressed: () =>
                                  copyCommunityPostLink(context, post),
                              leading: const Icon(LucideIcons.link, size: 16),
                              child: Text(l10n.communityCopyLink),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ShadButton.secondary(
                              key: const ValueKey('community-post-take-down'),
                              enabled: !busy,
                              onPressed: _takeDown,
                              child: Text(
                                l10n.communityTakeDown,
                                style: TextStyle(color: theme.destructive),
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_error case final error?) _ErrorText(error),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Parts
// ---------------------------------------------------------------------------

/// How long ago [time] was, inside a sentence: the cards' "Just now" starts
/// a label, not a clause.
String _whenInSentence(AppLocalizations l10n, DateTime time) =>
    DateTime.now().difference(time).inMinutes < 1
        ? l10n.communityJustNow
        : StrategyTileViewData.timeAgo(l10n, time);

/// The card as the feed would show it, framed, and not something to press.
class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _cardWidth,
      height: _cardHeight,
      child: ExcludeSemantics(child: IgnorePointer(child: child)),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          NumberFormat.decimalPattern(
            Localizations.localeOf(context).toLanguageTag(),
          ).format(value),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Settings.tacticalVioletTheme.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2, right: 10),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: theme.mutedForeground,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 14, color: theme.mutedForeground),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 14,
        color: Settings.tacticalVioletTheme.mutedForeground,
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          color: Settings.tacticalVioletTheme.destructive,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({this.text, this.spinner = false});

  final String? text;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _cardHeight,
      child: Center(
        child: spinner
            ? const SizedBox.square(
                dimension: 20,
                child: LoadingSpinner(strokeWidth: 2),
              )
            : Text(
                text ?? '',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Settings.tacticalVioletTheme.mutedForeground,
                ),
              ),
      ),
    );
  }
}
