import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class InAppDebugDialog extends ConsumerWidget {
  const InAppDebugDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(inAppDebugProvider);

    return ShadDialog(
      title: const Text('In-App Debug Logs'),
      description: const Text(
        'Use Copy to send the latest debug report.',
      ),
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
      actions: [
        ShadButton.outline(
          onPressed: () {
            ref.read(inAppDebugProvider.notifier).clearLogs();
          },
          leading: const Icon(LucideIcons.trash2, size: 16),
          child: const Text('Clear'),
        ),
        ShadButton.secondary(
          onPressed: logs.isEmpty
              ? null
              : () async {
                  final text = AppErrorReporter.buildClipboardReport(logs);
                  await Clipboard.setData(ClipboardData(text: text));
                  Settings.showToast(
                    message: 'Debug report copied to clipboard.',
                    backgroundColor: Settings.tacticalVioletTheme.primary,
                  );
                },
          leading: const Icon(LucideIcons.copy, size: 16),
          child: const Text('Copy'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
      child: SizedBox(
        width: 680,
        height: 440,
        child: logs.isEmpty
            ? Center(
                child: Text(
                  'No logs yet.',
                  style: ShadTheme.of(context).textTheme.muted,
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  color: ShadTheme.of(context)
                      .colorScheme
                      .muted
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: logs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    return _DebugLogEntryCard(entry: logs[index]);
                  },
                ),
              ),
      ),
    );
  }
}

class _DebugLogEntryCard extends StatelessWidget {
  const _DebugLogEntryCard({required this.entry});

  final DebugLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _backgroundColor(theme, entry.level),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _borderColor(theme, entry.level),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.headline,
            style: theme.textTheme.small.copyWith(
              color: _headlineColor(theme, entry.level),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            entry.message,
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 12,
              height: 1.4,
            ),
          ),
          if (entry.errorText != null &&
              entry.errorText!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Error',
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              entry.errorText!,
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          if (entry.stackTrace != null &&
              entry.stackTrace!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Stack trace',
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              entry.stackTrace!,
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _backgroundColor(ShadThemeData theme, DebugLogLevel level) {
    return switch (level) {
      DebugLogLevel.info => theme.colorScheme.secondary.withValues(alpha: 0.28),
      DebugLogLevel.warning => const Color(0xff7c2d12).withValues(alpha: 0.35),
      DebugLogLevel.error =>
        theme.colorScheme.destructive.withValues(alpha: 0.18),
    };
  }

  Color _borderColor(ShadThemeData theme, DebugLogLevel level) {
    return switch (level) {
      DebugLogLevel.info => theme.colorScheme.border,
      DebugLogLevel.warning => const Color(0xfff59e0b).withValues(alpha: 0.5),
      DebugLogLevel.error =>
        theme.colorScheme.destructive.withValues(alpha: 0.45),
    };
  }

  Color _headlineColor(ShadThemeData theme, DebugLogLevel level) {
    return switch (level) {
      DebugLogLevel.info => theme.colorScheme.foreground,
      DebugLogLevel.warning => const Color(0xfffbbf24),
      DebugLogLevel.error => theme.colorScheme.destructiveForeground,
    };
  }
}
