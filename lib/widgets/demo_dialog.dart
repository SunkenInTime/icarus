import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

class DemoDialog extends ConsumerWidget {
  const DemoDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: const Text('Demo Version'),
      content: const SizedBox(
        width: 400,
        child: Text(
          'You are running the web version of this application, which has limited functionality. '
          'For the best experience, please install the Windows version from the Microsoft Store — it is free.',
        ),
      ),
      actions: [
        CustomButton(
          icon: const Icon(
            Icons.close,
          ),
          onPressed: () {
            Navigator.of(context).pop();
          },
          height: 40,
          label: 'Close',
          backgroundColor: Settings.highlightColor,
        ),
        CustomButton(
          icon: const Icon(Icons.download),
          onPressed: () async {
            await launchUrl(Settings.windowsStoreLink);
          },
          height: 40,
          label: 'Download',
        )
      ],
    );
  }
}
