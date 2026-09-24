import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/dialogs/web_beta_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Marks the web build as the beta. Tapping it explains what that means.
/// Callers show it only when the platform policy says this is the web beta.
class WebBetaTag extends StatelessWidget {
  const WebBetaTag({super.key});

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Semantics(
      label: 'About the Icarus web beta',
      button: true,
      excludeSemantics: true,
      child: ShadButton.outline(
        key: const ValueKey('web-beta-tag'),
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: theme.mutedForeground,
        hoverForegroundColor: theme.foreground,
        onPressed: () => showShadDialog<void>(
          context: context,
          builder: (_) => const WebBetaDialog(),
        ),
        child: const Text(
          'Beta',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
