import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class WebViewDialog extends StatelessWidget {
  const WebViewDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return ShadDialog.alert(
      title: const Text('WebView'),
      description: const Text(
          'WebView is not installed on your system. Please install it to use youtube videos.'),
      actions: [
        ShadButton.secondary(
          child: const Text('Close'),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
        ShadButton(
          child: const Text('Install'),
          onPressed: () {
            launchUrl(Uri.parse(
                'https://developer.microsoft.com/en-us/microsoft-edge/webview2/?form=MA13LH'));
          },
        ),
      ],
    );
  }
}
