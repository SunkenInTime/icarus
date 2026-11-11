import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Covers the editor on an upright phone, which is too narrow to place
/// anything on a map that's bound by height. The editor stays alive under
/// it, so turning the phone picks up exactly where it was.
class TurnPhoneNotice extends StatelessWidget {
  const TurnPhoneNotice({super.key, required this.onLeave, this.backTooltip});

  final VoidCallback onLeave;

  /// Where leaving goes when it isn't the library.
  final String? backTooltip;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return ColoredBox(
      key: const ValueKey('turn-phone-notice'),
      color: theme.background,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.smartphone,
                  size: 38,
                  color: theme.mutedForeground,
                ),
                const SizedBox(height: 16),
                Text(
                  context.l10n.turnPhoneTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.turnPhoneRotationLockHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.mutedForeground),
                ),
                const SizedBox(height: 16),
                ShadButton.secondary(
                  key: const ValueKey('turn-phone-leave'),
                  onPressed: onLeave,
                  child: Text(
                    backTooltip ?? context.l10n.turnPhoneBackToLibrary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
