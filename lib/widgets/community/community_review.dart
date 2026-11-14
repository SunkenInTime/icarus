import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/community_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/widgets/dialogs/community/report_post_dialog.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/loading_spinner.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

final _reportsProvider = FutureProvider.autoDispose
    .family<List<CommunityReportGroup>, String>((ref, postPublicId) {
  return ref.read(communityRepositoryProvider).fetchReports(postPublicId);
});

/// What reporters said about a hidden post, for the reviewer looking at it.
class CommunityReportsCard extends ConsumerWidget {
  const CommunityReportsCard({super.key, required this.post});

  final CommunityPost post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = Settings.tacticalVioletTheme;
    final l10n = context.l10n;
    final reports = ref.watch(_reportsProvider(post.publicId));
    final groups = reports.valueOrNull ?? const [];
    final total = groups.fold<int>(0, (sum, group) => sum + group.count);
    return Container(
      width: 316,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: theme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.border, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            reports.hasValue
                ? l10n.communityReviewHiddenAfter(total)
                : l10n.communityReviewReports,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          if (reports.hasError)
            Text(
              l10n.communityReviewReportsFailed,
              style: TextStyle(fontSize: 14, color: theme.mutedForeground),
            )
          else if (!reports.hasValue)
            const Align(
              alignment: Alignment.centerLeft,
              child: SizedBox.square(
                dimension: 16,
                child: LoadingSpinner(strokeWidth: 2),
              ),
            )
          else
            for (final group in groups)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            communityReportReasonLabel(l10n, group.reason),
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        Text(
                          '${group.count}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    for (final note in group.notes.toSet())
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '"$note"',
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.mutedForeground,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// A reviewer's choices for a hidden post: put it back in the feed, remove
/// it, or (under ⋯) remove it and stop its author posting. [onDecided] runs
/// once the server has the decision.
class CommunityReviewActions extends ConsumerStatefulWidget {
  const CommunityReviewActions({
    super.key,
    required this.post,
    required this.onDecided,
  });

  final CommunityPost post;
  final VoidCallback onDecided;

  @override
  ConsumerState<CommunityReviewActions> createState() =>
      _CommunityReviewActionsState();
}

class _CommunityReviewActionsState
    extends ConsumerState<CommunityReviewActions> {
  final _menu = ShadPopoverController();
  CommunityReviewDecision? _sending;

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  Future<void> _decide(CommunityReviewDecision decision) async {
    final l10n = context.l10n;
    if (decision == CommunityReviewDecision.ban) {
      final confirmed = await showShadDialog<bool>(
        context: context,
        builder: (_) => ConfirmAlertDialog(
          title: l10n.communityReviewBanConfirmTitle,
          content: l10n.communityReviewBanConfirmBody,
          confirmText: l10n.communityReviewBan,
          isDestructive: true,
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _sending = decision);
    try {
      await ref
          .read(communityRepositoryProvider)
          .review(widget.post.publicId, decision);
      // The feed was read while the post was out of it.
      final feed = ref.read(communityFeedProvider.notifier);
      if (decision == CommunityReviewDecision.restore) {
        unawaited(feed.refresh());
      } else {
        feed.forget(widget.post.publicId);
      }
      if (!mounted) return;
      Settings.showToast(
        message: switch (decision) {
          CommunityReviewDecision.restore => l10n.communityReviewRestored,
          CommunityReviewDecision.remove => l10n.communityReviewRemoved,
          CommunityReviewDecision.ban => l10n.communityReviewBanned,
        },
        backgroundColor: Settings.tacticalVioletTheme.secondary,
      );
      widget.onDecided();
    } catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'A Community review decision failed.',
        source: 'CommunityReviewActions.decide',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _sending = null);
      Settings.showToast(
        message: l10n.communityReviewFailed,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  static Widget _spinner(Color color) => SizedBox.square(
        dimension: 14,
        child: LoadingSpinner(strokeWidth: 2, color: color),
      );

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final l10n = context.l10n;
    final busy = _sending != null;
    // The buttons stand on the map by themselves, with no card behind them.
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
          popover: (context) => ShadButton.ghost(
            height: 32,
            mainAxisAlignment: MainAxisAlignment.start,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            gap: 8,
            onPressed: () {
              _menu.hide();
              _decide(CommunityReviewDecision.ban);
            },
            leading: Icon(LucideIcons.ban, size: 16, color: theme.destructive),
            child: Text(
              l10n.communityReviewBan,
              style: TextStyle(color: theme.destructive),
            ),
          ),
          child: ShadIconButton.secondary(
            key: const ValueKey('community-review-more'),
            width: 36,
            height: 36,
            enabled: !busy,
            onPressed: _menu.toggle,
            icon: const Icon(LucideIcons.ellipsis, size: 18),
          ),
        ),
        const SizedBox(width: 6),
        ShadButton.secondary(
          key: const ValueKey('community-review-restore'),
          height: 36,
          enabled: !busy,
          onPressed: () => _decide(CommunityReviewDecision.restore),
          leading: _sending == CommunityReviewDecision.restore
              ? _spinner(theme.foreground)
              : null,
          child: Text(l10n.communityReviewRestore),
        ),
        const SizedBox(width: 6),
        ShadButton.destructive(
          key: const ValueKey('community-review-remove'),
          height: 36,
          enabled: !busy,
          onPressed: () => _decide(CommunityReviewDecision.remove),
          leading: _sending == CommunityReviewDecision.remove
              ? _spinner(theme.destructiveForeground)
              : null,
          child: Text(l10n.communityReviewRemove),
        ),
      ],
    );
  }
}
