import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/widgets/loading_spinner.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

String communityReportReasonLabel(
  AppLocalizations l10n,
  CommunityReportReason reason,
) =>
    switch (reason) {
      CommunityReportReason.offensive => l10n.communityReportOffensive,
      CommunityReportReason.picture => l10n.communityReportPicture,
      CommunityReportReason.link => l10n.communityReportLink,
      CommunityReportReason.spam => l10n.communityReportSpam,
      CommunityReportReason.stolen => l10n.communityReportStolen,
    };

/// Reports a post: one reason and, if the reporter wants, where on it the
/// problem is. The author is never told who reported it.
class ReportPostDialog extends ConsumerStatefulWidget {
  const ReportPostDialog({super.key, required this.post});

  final CommunityPost post;

  @override
  ConsumerState<ReportPostDialog> createState() => _ReportPostDialogState();
}

class _ReportPostDialogState extends ConsumerState<ReportPostDialog> {
  final _note = TextEditingController();
  CommunityReportReason? _reason;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    final l10n = context.l10n;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(communityRepositoryProvider).report(
            postPublicId: widget.post.publicId,
            reason: reason,
            note: _note.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      Settings.showToast(
        message: l10n.communityReportSent,
        backgroundColor: Settings.tacticalVioletTheme.secondary,
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'Reporting a Community post failed.',
        source: 'ReportPostDialog.send',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = l10n.communityReportFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final l10n = context.l10n;
    final author = widget.post.authorName;
    return ShadDialog(
      title: Text(l10n.communityReportTitle(widget.post.title)),
      description: Text(
        author == null
            ? l10n.communityReportNotToldAnonymous
            : l10n.communityReportNotTold(author),
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        ShadButton(
          key: const ValueKey('community-report-send'),
          enabled: _reason != null && !_sending,
          onPressed: _send,
          leading: _sending
              ? SizedBox.square(
                  dimension: 14,
                  child: LoadingSpinner(
                    strokeWidth: 2,
                    color: theme.colorScheme.primaryForeground,
                  ),
                )
              : null,
          child: Text(l10n.communityReportSend),
        ),
      ],
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final reason in CommunityReportReason.values)
              _ReasonRow(
                label: communityReportReasonLabel(l10n, reason),
                selected: _reason == reason,
                onTap: () => setState(() => _reason = reason),
              ),
            const SizedBox(height: 16),
            Text(
              l10n.communityReportWhere,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextEditingShortcutScope(
              child: ShadInput(
                controller: _note,
                maxLength: 200,
                placeholder: Text(l10n.communityReportWhereHint),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.destructive),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReasonRow extends StatefulWidget {
  const _ReasonRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ReasonRow> createState() => _ReasonRowState();
}

class _ReasonRowState extends State<_ReasonRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: widget.selected,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Settings.easeOut,
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: widget.selected || _hovered
                  ? theme.secondary
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Settings.easeOut,
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      width: widget.selected ? 5 : 1.5,
                      color: widget.selected
                          ? Settings.accentInk
                          : theme.mutedForeground,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        widget.selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
