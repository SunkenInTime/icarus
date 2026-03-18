import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/app_preferences_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/map_theme_settings_section.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadSheet(
      title: Text("Settings", style: ShadTheme.of(context).textTheme.h3),
      child: const Padding(
        padding: EdgeInsets.all(8.0),
        child: SizedBox(
          width: 325,
          child: Material(
            color: Colors.transparent,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StrategyScope(),
                  SizedBox(height: 14),
                  _GlobalScope(),
                  SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Strategy Scope (Per-Page) ────────────────────────────────

class _StrategyScope extends ConsumerWidget {
  const _StrategyScope();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const colors = Settings.tacticalVioletTheme;
    final hasActiveStrategy = ref.watch(strategyProvider).stratName != null;

    return _ScopeCard(
      icon: LucideIcons.swords,
      title: "This Strategy",
      scopeLabel: "PER PAGE",
      accentColor: colors.primary,
      description: "Affects the active page only",
      children: hasActiveStrategy
          ? [
              _CompactSlider(
                label: "Agent Scale",
                value: ref.watch(strategySettingsProvider).agentSize,
                min: Settings.agentSizeMin,
                max: Settings.agentSizeMax,
                divisions: 15,
                onChanged: (v) => ref
                    .read(strategySettingsProvider.notifier)
                    .updateAgentSize(v),
              ),
              const SizedBox(height: 6),
              _CompactSlider(
                label: "Ability Scale",
                value: ref.watch(strategySettingsProvider).abilitySize,
                min: Settings.abilitySizeMin,
                max: Settings.abilitySizeMax,
                divisions: 15,
                onChanged: (v) => ref
                    .read(strategySettingsProvider.notifier)
                    .updateAbilitySize(v),
              ),
              const SizedBox(height: 14),
              const _SectionDivider("Map Theme"),
              const SizedBox(height: 10),
              const ActiveThemeCard(),
            ]
          : [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  "Open a strategy to configure page settings.",
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: colors.mutedForeground,
                      ),
                ),
              ),
            ],
    );
  }
}

// ─── Global Scope (App-Wide) ──────────────────────────────────

class _GlobalScope extends ConsumerWidget {
  const _GlobalScope();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const colors = Settings.tacticalVioletTheme;
    final prefs = ref.watch(appPreferencesProvider);

    return _ScopeCard(
      icon: LucideIcons.globe,
      title: "Global",
      scopeLabel: "APP-WIDE",
      accentColor: colors.mutedForeground,
      description: "Preferences that apply everywhere",
      children: [
        const _SectionDivider("Map Overlays"),
        const SizedBox(height: 8),
        _CompactCheckbox(
          label: "Show Spawn Barrier",
          value: prefs.showSpawnBarrier,
          onChanged: (v) async =>
              ref.read(appPreferencesProvider.notifier).setShowSpawnBarrier(v),
        ),
        _CompactCheckbox(
          label: "Show Region Names",
          value: prefs.showRegionNames,
          onChanged: (v) async =>
              ref.read(appPreferencesProvider.notifier).setShowRegionNames(v),
        ),
        _CompactCheckbox(
          label: "Show Ult Orbs",
          value: prefs.showUltOrbs,
          onChanged: (v) async =>
              ref.read(appPreferencesProvider.notifier).setShowUltOrbs(v),
        ),
        const SizedBox(height: 14),
        const _SectionDivider("New Strategy Defaults"),
        const SizedBox(height: 8),
        _CompactSlider(
          label: "Agent Scale",
          value: prefs.defaultAgentSizeForNewStrategies,
          min: Settings.agentSizeMin,
          max: Settings.agentSizeMax,
          divisions: 15,
          onChanged: (v) => ref
              .read(appPreferencesProvider.notifier)
              .setDefaultAgentSizeForNewStrategies(v),
        ),
        const SizedBox(height: 6),
        _CompactSlider(
          label: "Ability Scale",
          value: prefs.defaultAbilitySizeForNewStrategies,
          min: Settings.abilitySizeMin,
          max: Settings.abilitySizeMax,
          divisions: 15,
          onChanged: (v) => ref
              .read(appPreferencesProvider.notifier)
              .setDefaultAbilitySizeForNewStrategies(v),
        ),
        const SizedBox(height: 14),
        const _SectionDivider("Theme Profiles"),
        const SizedBox(height: 10),
        const ProfileLibrarySection(),
      ],
    );
  }
}

// ─── Scope Card Container ─────────────────────────────────────

class _ScopeCard extends StatelessWidget {
  const _ScopeCard({
    required this.icon,
    required this.title,
    required this.scopeLabel,
    required this.accentColor,
    required this.description,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String scopeLabel;
  final Color accentColor;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withValues(alpha: 0.2)),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 2,
            color: accentColor.withValues(alpha: 0.5),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 15, color: accentColor),
                    const SizedBox(width: 8),
                    Text(
                      title,
                      style: theme.textTheme.lead.copyWith(fontSize: 15),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        scopeLabel,
                        style: theme.textTheme.small.copyWith(
                          color: accentColor,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.small.copyWith(
                    color: Settings.tacticalVioletTheme.mutedForeground,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 14),
                ...children,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Section Divider ──────────────────────────────────────────

class _SectionDivider extends StatelessWidget {
  const _SectionDivider(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text.toUpperCase(),
          style: ShadTheme.of(context).textTheme.small.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 1,
            color: Settings.tacticalVioletTheme.border,
          ),
        ),
      ],
    );
  }
}

// ─── Compact Slider ───────────────────────────────────────────

class _CompactSlider extends StatelessWidget {
  const _CompactSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 13)),
            Text(
              value.round().toString(),
              style: TextStyle(
                fontSize: 12,
                color: Settings.tacticalVioletTheme.mutedForeground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: Settings.tacticalVioletTheme.primary,
            inactiveTrackColor: Settings.tacticalVioletTheme.secondary,
            thumbColor: Settings.tacticalVioletTheme.primary,
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
    );
  }
}

// ─── Compact Checkbox Row ─────────────────────────────────────

class _CompactCheckbox extends StatelessWidget {
  const _CompactCheckbox({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          ShadCheckbox(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

// ─── Legacy SettingsSection (kept for external usage) ─────────

class SettingsSection extends StatelessWidget {
  const SettingsSection(
      {super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: ShadTheme.of(context).textTheme.lead),
        const SizedBox(
          height: 10,
        ),
        ...children
      ],
    );
  }
}
