import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/settings.dart';
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
    return ShadDialog(
      key: const ValueKey('web-beta-dialog'),
      title: const Text('Icarus web beta'),
      description: const Text(
        'Strategies you make here are saved to your Icarus account and open '
        'in the desktop app too.',
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        ShadButton(
          key: const ValueKey('web-beta-download'),
          leading: const Icon(LucideIcons.download, size: 16),
          onPressed: () => launchUrl(Settings.stableWindowsInstallerLink),
          child: const Text('Download for Windows'),
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
                  heading: 'Desktop-only for now',
                  features: policy.desktopOnly,
                ),
              if (policy.desktopOnly.isNotEmpty &&
                  policy.comingToWebBeta.isNotEmpty)
                const SizedBox(height: 12),
              if (policy.comingToWebBeta.isNotEmpty)
                _FeatureList(
                  heading: 'Coming to the web beta',
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
          [for (final feature in features) feature.label].join(' · '),
          style: TextStyle(fontSize: 14, color: theme.foreground),
        ),
      ],
    );
  }
}
