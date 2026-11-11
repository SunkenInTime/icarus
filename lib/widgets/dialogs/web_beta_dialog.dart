import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

/// What the web beta is, what still needs the desktop app, and where to get
/// it. The feature lists come from the platform policy so they never drift
/// from what the app actually blocks.
class WebBetaDialog extends ConsumerWidget {
  const WebBetaDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(platformPolicyProvider);
    final l10n = context.l10n;
    return ShadDialog(
      key: const ValueKey('web-beta-dialog'),
      title: Text(l10n.webBetaTitle),
      description: Text(
        l10n.webBetaDescription,
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
        ShadButton(
          key: const ValueKey('web-beta-download'),
          leading: const Icon(LucideIcons.download, size: 16),
          onPressed: () => launchUrl(Settings.stableWindowsInstallerLink),
          child: Text(l10n.webBetaDownloadForWindows),
        ),
      ],
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (policy.desktopOnly.isNotEmpty)
                _FeatureList(
                  heading: l10n.webBetaDesktopOnly,
                  features: policy.desktopOnly,
                ),
              if (policy.desktopOnly.isNotEmpty &&
                  policy.comingToWebBeta.isNotEmpty)
                const SizedBox(height: 12),
              if (policy.comingToWebBeta.isNotEmpty)
                _FeatureList(
                  heading: l10n.webBetaComing,
                  features: policy.comingToWebBeta,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureList extends StatelessWidget {
  const _FeatureList({required this.heading, required this.features});

  final String heading;
  final Set<PlatformFeature> features;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: theme.mutedForeground,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          [for (final feature in features) feature.label(context.l10n)]
              .join(' · '),
          style: TextStyle(fontSize: 14, color: theme.foreground),
        ),
      ],
    );
  }
}
