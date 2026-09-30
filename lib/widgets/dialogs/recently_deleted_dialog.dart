import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The cloud strategy's deleted pages that can still be restored: who
/// deleted each and when, how long it has left, and Restore, which puts it
/// back where it was with everything on it.
class RecentlyDeletedDialog extends ConsumerStatefulWidget {
  const RecentlyDeletedDialog({super.key, required this.strategyPublicId});

  final String strategyPublicId;

  static Future<void> show(BuildContext context, String strategyPublicId) {
    return showShadDialog<void>(
      context: context,
      builder: (context) =>
          RecentlyDeletedDialog(strategyPublicId: strategyPublicId),
    );
  }

  @override
  ConsumerState<RecentlyDeletedDialog> createState() =>
      _RecentlyDeletedDialogState();
}

enum _RowState { idle, restoring, failed, gone }

class _RecentlyDeletedDialogState extends ConsumerState<RecentlyDeletedDialog> {
  List<TrashedPage>? _pages;
  bool _loadFailed = false;
  final Map<String, _RowState> _rows = {};

  /// Keeps the times shown current while the dialog stays open, and takes
  /// Restore away from a page whose time runs out meanwhile.
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(
      const Duration(minutes: 1),
      (_) => setState(() {}),
    );
    _load();
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadFailed = false);
    try {
      final pages = await ref
          .read(convexStrategyRepositoryProvider)
          .listTrashedPages(widget.strategyPublicId);
      if (!mounted) return;
      setState(() => _pages = pages);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadFailed = true);
    }
  }

  Future<void> _restore(TrashedPage page) async {
    setState(() => _rows[page.pageId] = _RowState.restoring);
    final outcome = await ref
        .read(strategyPageSessionProvider.notifier)
        .restorePageFromTrash(page.pageId);
    if (!mounted) return;
    setState(() {
      switch (outcome) {
        case DeletedPageRestore.restored:
          _rows.remove(page.pageId);
          _pages = [
            for (final other in _pages ?? const <TrashedPage>[])
              if (other.pageId != page.pageId) other,
          ];
        case DeletedPageRestore.gone:
          _rows[page.pageId] = _RowState.gone;
        case DeletedPageRestore.failed:
          _rows[page.pageId] = _RowState.failed;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('Recently deleted'),
      description: const Text(
        'Deleted pages stay here for $pageTrashRetentionDays days, then they '
        'are gone for good.',
      ),
      child: SizedBox(
        width: 440,
        child: _body(ShadTheme.of(context)),
      ),
    );
  }

  Widget _body(ShadThemeData theme) {
    final muted = theme.textTheme.small.copyWith(
      color: theme.colorScheme.mutedForeground,
      fontWeight: FontWeight.w400,
    );
    if (_loadFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Could not load deleted pages. Check your connection and '
                'try again.',
                style: muted,
              ),
            ),
            const SizedBox(width: 12),
            ShadButton.secondary(
              size: ShadButtonSize.sm,
              onPressed: _load,
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    final pages = _pages;
    if (pages == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text('Loading…', style: muted),
      );
    }
    if (pages.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.archiveRestore,
                size: 20,
                color: theme.colorScheme.mutedForeground,
              ),
              const SizedBox(height: 8),
              Text('No deleted pages.', style: muted),
            ],
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: pages.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final page = pages[index];
          return _TrashedPageRow(
            page: page,
            state: _rows[page.pageId] ?? _RowState.idle,
            onRestore: () => _restore(page),
          );
        },
      ),
    );
  }
}

class _TrashedPageRow extends StatelessWidget {
  const _TrashedPageRow({
    required this.page,
    required this.state,
    required this.onRestore,
  });

  final TrashedPage page;
  final _RowState state;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final now = clock.now();
    // Past its time here too, as when the server says so.
    final gone = state == _RowState.gone || !page.restorableUntil.isAfter(now);
    final error = gone
        ? 'It can no longer be restored.'
        : state == _RowState.failed
            ? 'Could not confirm the restore. Check your connection and try '
                'again.'
            : null;
    // Type roles from DESIGN.md: title for the name, label for the rest.
    final label = theme.textTheme.small.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  page.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.foreground,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  gone
                      ? deletedLabel(page, now)
                      : '${deletedLabel(page, now)} · '
                          '${timeLeftLabel(page, now)}',
                  style: label.copyWith(
                    color: theme.colorScheme.mutedForeground,
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error,
                    style: label.copyWith(
                      color: theme.colorScheme.destructive,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!gone) ...[
            const SizedBox(width: 12),
            ShadButton.secondary(
              size: ShadButtonSize.sm,
              onPressed: state == _RowState.restoring ? null : onRestore,
              child: Text(
                state == _RowState.restoring ? 'Restoring…' : 'Restore',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Deleted by Sam, 2 days ago", "Deleted by you, 5 minutes ago", or
/// "Deleted 2 days ago" when who deleted it is not known.
@visibleForTesting
String deletedLabel(TrashedPage page, DateTime now) {
  final by = page.deletedByYou ? 'you' : page.deletedByName;
  final when = _ago(now.difference(page.deletedAt));
  return by == null ? 'Deleted $when' : 'Deleted by $by, $when';
}

/// "28 days left", "1 day left", "Less than a day left".
@visibleForTesting
String timeLeftLabel(TrashedPage page, DateTime now) {
  final days = page.restorableUntil.difference(now).inDays;
  if (days < 1) return 'Less than a day left';
  return days == 1 ? '1 day left' : '$days days left';
}

String _ago(Duration elapsed) {
  String count(int n, String unit) => n == 1 ? '1 $unit' : '$n ${unit}s';
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${count(elapsed.inMinutes, 'minute')} ago';
  if (elapsed.inDays < 1) return '${count(elapsed.inHours, 'hour')} ago';
  return '${count(elapsed.inDays, 'day')} ago';
}
