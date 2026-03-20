import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/marker_sizes_sync.dart';
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
    final appPreferences = ref.watch(appPreferencesProvider);

    // Left/right sheets default to expandCrossSide + minHeight only, so width
    // stays unbounded and the panel stretches to the full overlay. Cap width to
    // match the sidebar panel (content + ShadDialog's default horizontal padding).
    return ShadSheet(
      constraints: const BoxConstraints(
        maxWidth: Settings.sideBarPanelWidth + 48,
      ),
      // Avoid nested scroll views; the outer ShadDialog scroll shows a desktop bar.
      scrollable: false,
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
      description: const Text(
        "Adjust strategy sizing and workspace visibility from one place.",
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: Settings.sideBarContentWidth,
          child: Material(
            color: Colors.transparent,
            child: ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SettingsScopeCard(
                      scope: SettingsScope.strategy,
                      title: "Page object sizing",
                      description: activeStrategyName == null
                          ? "Resize placed objects for the current strategy page."
                          : "Resize placed objects for \"$activeStrategyName\".",
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
                          const _PageMarkerSizesSyncBanner(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionDivider(),
                    const SizedBox(height: 20),
                    SettingsScopeCard(
                      scope: SettingsScope.workspace,
                      title: "Saving",
                      description:
                          "Control how Icarus persists strategy edits while you work.",
                      child: Column(
                        children: [
                          _SettingsToggleTile(
                            icon: Icons.save_outlined,
                            title: "Autosave",
                            description:
                                "Automatically save the current strategy after 15 seconds of inactivity. When off, Icarus will ask before you leave unsaved work.",
                            value: appPreferences.autosaveEnabled,
                            onChanged: (value) async {
                              await ref
                                  .read(appPreferencesProvider.notifier)
                                  .setAutosaveEnabled(value);
                              ref
                                  .read(strategyProvider.notifier)
                                  .refreshAutosaveScheduling();
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionDivider(),
                    const SizedBox(height: 20),
                    SettingsScopeCard(
                      scope: SettingsScope.workspace,
                      title: "Map visibility helpers",
                      description:
                          "Show or hide map reference layers while you work.",
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
                              ref
                                  .read(mapProvider.notifier)
                                  .updateUltOrbs(value);
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionDivider(),
                    const SizedBox(height: 20),
                    const MapThemeSettingsSection(),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
    final theme = ShadTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accentColor.withValues(alpha: 0.16)),
      ),
      child: Text(
        value,
        style: theme.textTheme.small.copyWith(
          color: theme.colorScheme.foreground,
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

class _PageMarkerSizesSyncBanner extends ConsumerStatefulWidget {
  const _PageMarkerSizesSyncBanner();

  @override
  ConsumerState<_PageMarkerSizesSyncBanner> createState() =>
      _PageMarkerSizesSyncBannerState();
}

class _PageMarkerSizesSyncBannerState
    extends ConsumerState<_PageMarkerSizesSyncBanner> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final stratState = ref.watch(strategyProvider);
    final liveSettings = ref.watch(strategySettingsProvider);
    final strategy =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(stratState.id);
    final showCta = stratState.stratName != null &&
        markerSizesDifferAcrossPages(
          strategy: strategy,
          activePageId: stratState.activePageId,
          liveSettings: liveSettings,
        );

    return SizedBox(
      width: double.infinity,
      child: AnimatedCrossFade(
        firstCurve: Curves.easeInCubic,
        secondCurve: Curves.easeOutCubic,
        sizeCurve: Curves.easeInOutCubic,
        duration: const Duration(milliseconds: 240),
        crossFadeState:
            showCta ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        firstChild: const SizedBox.shrink(),
        secondChild: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Marker sizes differ across pages. Apply these sizes everywhere?',
                style: ShadTheme.of(context).textTheme.small.copyWith(
                      color: Settings.tacticalVioletTheme.mutedForeground,
                      height: 1.35,
                    ),
              ),
              const SizedBox(height: 8),
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        try {
                          await ref
                              .read(strategyProvider.notifier)
                              .applyMarkerSizesToAllPages();
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                child: Text(_busy ? 'Applying…' : 'Apply to all pages'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
