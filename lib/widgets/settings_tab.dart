import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/map_theme_settings_section.dart'
    show MapThemeActiveThemeCard, MapThemeProfileLibrary;
import 'package:shadcn_ui/shadcn_ui.dart';

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasActiveStrategy = ref.watch(strategyProvider).stratName != null;
    final theme = ShadTheme.of(context);

    return ShadSheet(
      title: Text("Settings", style: theme.textTheme.h3),
      description: const Text(
        "Per-strategy options apply to the current strategy. View and library options apply app-wide.",
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: SizedBox(
          width: Settings.sideBarContentWidth,
          child: Material(
            color: Colors.transparent,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SettingsSectionCard(
                    icon: LucideIcons.fileEdit,
                    title: "This Strategy",
                    subtitle: "Saved with the current strategy",
                    accentColor: Settings.tacticalVioletTheme.primary,
                    isPerStrategy: true,
                    child: _ThisStrategyContent(
                      hasActiveStrategy: hasActiveStrategy,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SettingsSectionCard(
                    icon: LucideIcons.eye,
                    title: "Map View",
                    subtitle: "Display options · app-wide",
                    accentColor: Settings.tacticalVioletTheme.mutedForeground,
                    isPerStrategy: false,
                    child: const _MapViewContent(),
                  ),
                  const SizedBox(height: 12),
                  _SettingsSectionCard(
                    icon: LucideIcons.palette,
                    title: "Theme Library",
                    subtitle: "Manage themes · app-wide",
                    accentColor: Settings.tacticalVioletTheme.mutedForeground,
                    isPerStrategy: false,
                    child: const MapThemeProfileLibrary(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Card wrapper that visually distinguishes per-strategy vs app-wide sections.
class _SettingsSectionCard extends StatelessWidget {
  const _SettingsSectionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.isPerStrategy,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accentColor;
  final bool isPerStrategy;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [Settings.cardForegroundBackdrop],
        border: Border.all(
          color: isPerStrategy
              ? accentColor.withValues(alpha: 0.5)
              : Settings.tacticalVioletTheme.border,
          width: isPerStrategy ? 1.5 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left accent bar for per-strategy
            if (isPerStrategy)
              Container(
                height: 3,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        icon,
                        size: 18,
                        color: accentColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.lead.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              style: theme.textTheme.small.copyWith(
                                color: Settings.tacticalVioletTheme.mutedForeground,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  child,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThisStrategyContent extends ConsumerWidget {
  const _ThisStrategyContent({required this.hasActiveStrategy});

  final bool hasActiveStrategy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);

    if (!hasActiveStrategy) {
      return Text(
        "Open a strategy to adjust its settings.",
        style: theme.textTheme.small.copyWith(
          color: Settings.tacticalVioletTheme.mutedForeground,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ScaleRow(
          label: "Agent size",
          value: ref.watch(strategySettingsProvider).agentSize,
          min: Settings.agentSizeMin,
          max: Settings.agentSizeMax,
          onChanged: (v) =>
              ref.read(strategySettingsProvider.notifier).updateAgentSize(v),
        ),
        const SizedBox(height: 10),
        _ScaleRow(
          label: "Ability size",
          value: ref.watch(strategySettingsProvider).abilitySize,
          min: Settings.abilitySizeMin,
          max: Settings.abilitySizeMax,
          onChanged: (v) =>
              ref.read(strategySettingsProvider.notifier).updateAbilitySize(v),
        ),
        const SizedBox(height: 14),
        const MapThemeActiveThemeCard(embedded: true),
      ],
    );
  }
}

class _ScaleRow extends StatelessWidget {
  const _ScaleRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: ShadTheme.of(context).textTheme.small,
          ),
        ),
        Expanded(
          child: Slider(
            min: min,
            max: max,
            value: value,
            inactiveColor: Settings.tacticalVioletTheme.secondary,
            activeColor: Settings.tacticalVioletTheme.primary,
            divisions: (max - min).round(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 28,
          child: Text(
            value.round().toString(),
            style: ShadTheme.of(context).textTheme.small.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground,
                ),
          ),
        ),
      ],
    );
  }
}

class _MapViewContent extends ConsumerWidget {
  const _MapViewContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _ToggleRow(
          label: "Show spawn barrier",
          value: ref.watch(mapProvider).showSpawnBarrier,
          onChanged: (v) =>
              ref.read(mapProvider.notifier).updateSpawnBarrier(v),
        ),
        const SizedBox(height: 8),
        _ToggleRow(
          label: "Show region names",
          value: ref.watch(mapProvider).showRegionNames,
          onChanged: (v) =>
              ref.read(mapProvider.notifier).updateRegionNames(v),
        ),
        const SizedBox(height: 8),
        _ToggleRow(
          label: "Show ult orbs",
          value: ref.watch(mapProvider).showUltOrbs,
          onChanged: (v) => ref.read(mapProvider.notifier).updateUltOrbs(v),
        ),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: ShadTheme.of(context).textTheme.small,
          ),
        ),
        ShadCheckbox(
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
