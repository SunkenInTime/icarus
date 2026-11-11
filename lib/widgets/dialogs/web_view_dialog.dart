import 'package:flutter/material.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class WebViewDialog extends StatelessWidget {
  const WebViewDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ShadDialog.alert(
      title: Text(l10n.webViewTitle),
      description: Text(l10n.webViewNotInstalled),
      actions: [
        ShadButton.secondary(
          child: Text(l10n.commonClose),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
        ShadButton(
          child: Text(l10n.webViewInstall),
          onPressed: () {
            launchUrl(Uri.parse(
                'https://developer.microsoft.com/en-us/microsoft-edge/webview2/?form=MA13LH'));
          },
        ),
      ],
    );
  }
}
