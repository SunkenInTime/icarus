import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/release_notes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/release_notes_provider.dart';
import 'package:icarus/widgets/desktop_update_dialog.dart';
import 'package:icarus/widgets/dot_matrix_loaders.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Every shipped version's patch notes, newest first, with the installed
/// version marked. Read-only: updating stays with the update dialog.
class ReleaseNotesDialog extends ConsumerWidget {
  const ReleaseNotesDialog({super.key});

  static const double _width = 520;
  static const double _bodyHeight = 460;

  static Future<void> show(BuildContext context) {
    return showShadDialog<void>(
      context: context,
      builder: (context) => const ReleaseNotesDialog(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(releaseNotesProvider);

    return ShadDialog(
      title: const Text("What's new"),
      description: const Text('Everything that changed, release by release.'),
      constraints: const BoxConstraints(maxWidth: _width),
      child: SizedBox(
        height: _bodyHeight,
        child: notes.when(
          loading: () => const Center(child: WingDotLoader()),
          error: (_, __) => _Unavailable(
            onRetry: () => ref.invalidate(releaseNotesProvider),
          ),
          data: (entries) => entries.isEmpty
              ? _Unavailable(
                  onRetry: () => ref.invalidate(releaseNotesProvider),
                )
              : _ReleaseList(entries: entries),
        ),
      ),
    );
  }
}

class _ReleaseList extends StatelessWidget {
  const _ReleaseList({required this.entries});

  final List<ReleaseNotesEntry> entries;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ListView.separated(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _ReleaseCard(entry: entries[index]),
      ),
    );
  }
}

/// One release: version, date, and its notes on a raised surface, one step
/// above the dialog sheet. No lines; the lift does the separating.
class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.entry});

  final ReleaseNotesEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Container(
      decoration: Settings.raisedSurface(16),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                entry.versionName,
                style: theme.textTheme.large.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (entry.isInstalled) ...[
                const SizedBox(width: 10),
                const ShadBadge.outline(child: Text('Installed')),
              ] else if (entry.isNewerThanInstalled) ...[
                const SizedBox(width: 10),
                const ShadBadge(child: Text('Available')),
              ],
              const Spacer(),
              if (entry.date != null)
                Text(
                  entry.date!,
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.mutedForeground,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          PatchNotesList(notes: entry.changes),
        ],
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.wifiOff,
            size: 22,
            color: theme.colorScheme.mutedForeground,
          ),
          const SizedBox(height: 12),
          Text(
            "Couldn't load patch notes. Check your connection and try again.",
            textAlign: TextAlign.center,
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.mutedForeground,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 16),
          ShadButton.secondary(
            onPressed: onRetry,
            leading: const Icon(LucideIcons.refreshCw, size: 16),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
