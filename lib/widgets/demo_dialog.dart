import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

class DemoDialog extends ConsumerWidget {
  const DemoDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadDialog.alert(
      title: const Text('Browser beta'),
      description: const SizedBox(
        width: 400,
        child: Text(
          'The browser client supports the cloud library and shared strategies. '
          'Some editing and file tools still require the Windows app.',
        ),
      ),
      actions: [
        ShadButton.secondary(
          leading: const Icon(
            Icons.close,
          ),
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('Close'),
        ),
        ShadButton(
          leading: const Icon(Icons.download),
          onPressed: () async {
            await launchUrl(Settings.stableWindowsInstallerLink);
          },
          child: const Text('Download app'),
        )
      ],
    );
  }
}
