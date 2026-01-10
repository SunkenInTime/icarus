import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class InAppDebugDialog extends ConsumerWidget {
  const InAppDebugDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(inAppDebugProvider);

    return ShadDialog(
      title: const Text('In-App Debug Logs'),
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 500),
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
                  final text = logs.join('\n');
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Logs copied to clipboard'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
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
        width: 560,
        height: 350,
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
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SelectableText(
                        '${index + 1}. ${logs[index]}',
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
