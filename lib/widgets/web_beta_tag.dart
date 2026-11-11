import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/widgets/dialogs/web_beta_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Marks the web build as the beta. Tapping it explains what that means.
/// Callers show it only when the platform policy says this is the web beta.
///
/// It lives in the library strip only, beside the tabs where the demo tag
/// was: the one deliberate exception to DESIGN.md's strip contents. The
/// editor carries no labels, so it never appears there.
class WebBetaTag extends StatelessWidget {
  const WebBetaTag({super.key});

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Semantics(
      label: context.l10n.webBetaTagSemantics,
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
        child: Text(
          context.l10n.webBetaTag,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
