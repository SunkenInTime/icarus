import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum SettingsScope {
  strategy,
  workspace,
}

class SettingsScopeCard extends StatelessWidget {
  const SettingsScopeCard({
    super.key,
    required this.scope,
    required this.title,
    required this.description,
    required this.child,
    this.trailing,
  });

  final SettingsScope scope;
  final String title;
  final String description;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = SettingsScopeVisualStyle.fromScope(scope);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: style.borderColor),
        boxShadow: const [Settings.cardForegroundBackdrop],
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            style.tintedBackground,
            Settings.tacticalVioletTheme.card,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: style.iconBackground,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: style.borderColor),
                ),
                child: Icon(
                  style.icon,
                  size: 17,
                  color: style.accentColor,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: ShadTheme.of(context)
                                .textTheme
                                .lead
                                .copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SettingsScopeBadge(scope: scope),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color: Settings.tacticalVioletTheme.mutedForeground,
                            height: 1.35,
                          ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class SettingsScopeBadge extends StatelessWidget {
  const SettingsScopeBadge({
    super.key,
    required this.scope,
  });

  final SettingsScope scope;

  @override
  Widget build(BuildContext context) {
    final style = SettingsScopeVisualStyle.fromScope(scope);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: style.iconBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: style.borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 12, color: style.accentColor),
          const SizedBox(width: 5),
          Text(
            style.badgeLabel,
            style: ShadTheme.of(context).textTheme.small.copyWith(
                  color: style.accentColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
          ),
        ],
      ),
    );
  }
}

class SettingsScopeVisualStyle {
  const SettingsScopeVisualStyle({
    required this.icon,
    required this.badgeLabel,
    required this.accentColor,
    required this.tintedBackground,
    required this.iconBackground,
    required this.borderColor,
  });

  final IconData icon;
  final String badgeLabel;
  final Color accentColor;
  final Color tintedBackground;
  final Color iconBackground;
  final Color borderColor;

  factory SettingsScopeVisualStyle.fromScope(SettingsScope scope) {
    switch (scope) {
      case SettingsScope.strategy:
        final accent = Settings.tacticalVioletTheme.primary;
        return SettingsScopeVisualStyle(
          icon: LucideIcons.pencil,
          badgeLabel: 'STRATEGY',
          accentColor: accent,
          tintedBackground: accent.withValues(alpha: 0.12),
          iconBackground: accent.withValues(alpha: 0.16),
          borderColor: accent.withValues(alpha: 0.34),
        );
      case SettingsScope.workspace:
        const accent = Color(0xff14b8a6);
        return SettingsScopeVisualStyle(
          icon: LucideIcons.eye,
          badgeLabel: 'WORKSPACE',
          accentColor: accent,
          tintedBackground: accent.withValues(alpha: 0.12),
          iconBackground: accent.withValues(alpha: 0.15),
          borderColor: accent.withValues(alpha: 0.34),
        );
    }
  }
}
