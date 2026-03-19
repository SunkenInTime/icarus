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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: style.containerBorderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 3,
            decoration: BoxDecoration(
              color: style.accentColor.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: style.iconBackground,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: style.accentColor.withValues(alpha: 0.18),
                  ),
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
        border: Border.all(color: style.accentColor.withValues(alpha: 0.16)),
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
    required this.iconBackground,
    required this.containerBorderColor,
  });

  final IconData icon;
  final String badgeLabel;
  final Color accentColor;
  final Color iconBackground;
  final Color containerBorderColor;

  factory SettingsScopeVisualStyle.fromScope(SettingsScope scope) {
    switch (scope) {
      case SettingsScope.strategy:
        final accent = Settings.tacticalVioletTheme.primary;
        return SettingsScopeVisualStyle(
          icon: LucideIcons.pencil,
          badgeLabel: 'STRATEGY',
          accentColor: accent,
          iconBackground: accent.withValues(alpha: 0.12),
          containerBorderColor:
              Settings.tacticalVioletTheme.border.withValues(alpha: 0.95),
        );
      case SettingsScope.workspace:
        const accent = Color(0xff4b8f86);
        return SettingsScopeVisualStyle(
          icon: LucideIcons.eye,
          badgeLabel: 'WORKSPACE',
          accentColor: accent,
          iconBackground: accent.withValues(alpha: 0.12),
          containerBorderColor:
              Settings.tacticalVioletTheme.border.withValues(alpha: 0.95),
        );
    }
  }
}
