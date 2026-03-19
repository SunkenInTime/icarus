import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/map_theme_settings_section.dart';
import 'package:icarus/widgets/settings_scope_card.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeStrategyName = ref.watch(strategyProvider).stratName;
    final strategySettings = ref.watch(strategySettingsProvider);
    final mapState = ref.watch(mapProvider);

    return ShadSheet(
      title: Row(
        children: [
          Icon(
            LucideIcons.pencil,
            size: 18,
            color: Settings.tacticalVioletTheme.primary,
          ),
          const SizedBox(width: 8),
          Text("Settings", style: ShadTheme.of(context).textTheme.h3),
        ],
      ),
      description: Text(
        activeStrategyName == null
            ? "Settings marked Strategy save with the active plan. Settings marked Workspace stay with your app."
            : "Settings marked Strategy save to \"$activeStrategyName\". Settings marked Workspace stay with your app.",
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 340,
          child: Material(
            color: Colors.transparent,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ScopeLegendBanner(activeStrategyName: activeStrategyName),
                  const SizedBox(height: 16),
                  SettingsScopeCard(
                    scope: SettingsScope.strategy,
                    title: "Page object sizing",
                    description:
                        "These controls are saved with the current strategy page, so each setup can have its own scale.",
                    child: Column(
                      children: [
                        _SettingsSliderTile(
                          icon: Icons.person_pin_circle_outlined,
                          title: "Agent markers",
                          description:
                              "Resize placed agents and view tools for this strategy.",
                          value: strategySettings.agentSize,
                          min: Settings.agentSizeMin,
                          max: Settings.agentSizeMax,
                          divisions: 15,
                          accentColor: Settings.tacticalVioletTheme.primary,
                          onChanged: (value) {
                            ref
                                .read(strategySettingsProvider.notifier)
                                .updateAgentSize(value);
                          },
                        ),
                        const _SettingsItemDivider(),
                        _SettingsSliderTile(
                          icon: Icons.auto_awesome_outlined,
                          title: "Ability markers",
                          description:
                              "Resize utility icons and placement helpers for this strategy.",
                          value: strategySettings.abilitySize,
                          min: Settings.abilitySizeMin,
                          max: Settings.abilitySizeMax,
                          divisions: 15,
                          accentColor: Settings.tacticalVioletTheme.primary,
                          onChanged: (value) {
                            ref
                                .read(strategySettingsProvider.notifier)
                                .updateAbilitySize(value);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _SectionDivider(),
                  const SizedBox(height: 18),
                  SettingsScopeCard(
                    scope: SettingsScope.workspace,
                    title: "Map visibility helpers",
                    description:
                        "These toggles change your workspace view and stay available as you move between strategies.",
                    child: Column(
                      children: [
                        _SettingsToggleTile(
                          icon: Icons.grid_on_rounded,
                          title: "Spawn barriers",
                          description:
                              "Keep round-start barrier guides visible on the map.",
                          value: mapState.showSpawnBarrier,
                          onChanged: (value) {
                            ref
                                .read(mapProvider.notifier)
                                .updateSpawnBarrier(value);
                          },
                        ),
                        const _SettingsItemDivider(),
                        _SettingsToggleTile(
                          icon: Icons.location_on_outlined,
                          title: "Region names",
                          description:
                              "Show map callout names directly on the canvas.",
                          value: mapState.showRegionNames,
                          onChanged: (value) {
                            ref
                                .read(mapProvider.notifier)
                                .updateRegionNames(value);
                          },
                        ),
                        const _SettingsItemDivider(),
                        _SettingsToggleTile(
                          icon: Icons.radio_button_checked_outlined,
                          title: "Ultimate orbs",
                          description:
                              "Display orb pickup markers on supported maps.",
                          value: mapState.showUltOrbs,
                          onChanged: (value) {
                            ref.read(mapProvider.notifier).updateUltOrbs(value);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _SectionDivider(),
                  const SizedBox(height: 18),
                  const MapThemeSettingsSection(),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScopeLegendBanner extends StatelessWidget {
  const _ScopeLegendBanner({required this.activeStrategyName});

  final String? activeStrategyName;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          LucideIcons.info,
          size: 16,
          color: Settings.tacticalVioletTheme.mutedForeground,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Know what gets saved",
                style: ShadTheme.of(context)
                    .textTheme
                    .lead
                    .copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                activeStrategyName == null
                    ? "Strategy-marked controls travel with the active plan. Workspace-marked controls only change your local view."
                    : "\"$activeStrategyName\" keeps its own Strategy settings. Workspace settings only change your local view.",
                style: ShadTheme.of(context).textTheme.small.copyWith(
                      color: Settings.tacticalVioletTheme.mutedForeground,
                      height: 1.4,
                    ),
              ),
              const SizedBox(height: 10),
              const Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SettingsScopeBadge(scope: SettingsScope.strategy),
                  SettingsScopeBadge(scope: SettingsScope.workspace),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsSliderTile extends StatelessWidget {
  const _SettingsSliderTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.accentColor,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String description;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final Color accentColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLeadingIcon(
                icon: icon,
                accentColor: accentColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color: Settings.tacticalVioletTheme.mutedForeground,
                            height: 1.3,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _SettingValuePill(
                value: value.toStringAsFixed(0),
                accentColor: accentColor,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accentColor,
              thumbColor: accentColor,
              overlayColor: accentColor.withValues(alpha: 0.12),
              inactiveTrackColor: Settings.tacticalVioletTheme.secondary,
              trackHeight: 2.8,
            ),
            child: Slider(
              min: min,
              max: max,
              divisions: divisions,
              value: value,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsToggleTile extends StatelessWidget {
  const _SettingsToggleTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingLeadingIcon(
            icon: icon,
            accentColor: const Color(0xff4b8f86),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: Settings.tacticalVioletTheme.mutedForeground,
                        height: 1.3,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ShadCheckbox(
              value: value,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingLeadingIcon extends StatelessWidget {
  const _SettingLeadingIcon({
    required this.icon,
    required this.accentColor,
  });

  final IconData icon;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.15),
        ),
      ),
      child: Icon(icon, size: 18, color: accentColor),
    );
  }
}

class _SettingValuePill extends StatelessWidget {
  const _SettingValuePill({
    required this.value,
    required this.accentColor,
  });

  final String value;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accentColor.withValues(alpha: 0.16)),
      ),
      child: Text(
        value,
        style: ShadTheme.of(context).textTheme.small.copyWith(
              color: accentColor,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _SettingsItemDivider extends StatelessWidget {
  const _SettingsItemDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: Settings.tacticalVioletTheme.border.withValues(alpha: 0.8),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: Settings.tacticalVioletTheme.border.withValues(alpha: 0.9),
    );
  }
}
