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

enum _SettingsMode {
  strategy,
  global,
}

enum _SettingsSection {
  strategyObjects,
  strategyMapTheme,
  globalDefaults,
  globalSaving,
  globalMapVisibility,
  globalMapProfiles,
}

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});

  static const double _dialogWidth = 860;
  static const double _dialogHeight = 640;
  static const double _navigationWidth = 196;

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  _SettingsMode _mode = _SettingsMode.strategy;
  _SettingsSection _selectedSection = _SettingsSection.strategyObjects;
  final ScrollController _scrollController = ScrollController();
  final Map<_SettingsSection, GlobalKey> _sectionKeys = {
    for (final section in _SettingsSection.values) section: GlobalKey(),
  };

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeStrategyName = ref.watch(strategyProvider).stratName;
    final strategySettings = ref.watch(strategySettingsProvider);
    final mapState = ref.watch(mapProvider);
    final appPreferences = ref.watch(appPreferencesProvider);
    final scopeLabel =
        _mode == _SettingsMode.strategy ? 'Current strategy' : 'App-wide';
    final scopeValue =
        _mode == _SettingsMode.strategy ? activeStrategyName : 'Defaults';

    return ShadDialog(
      constraints: const BoxConstraints(
        maxWidth: SettingsTab._dialogWidth,
        maxHeight: SettingsTab._dialogHeight,
      ),
      padding: EdgeInsets.zero,
      scrollable: false,
      closeIconPosition: const ShadPosition(top: 18, right: 18),
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: SettingsTab._dialogWidth,
          height: SettingsTab._dialogHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SettingsNavigationRail(
                mode: _mode,
                selectedSection: _selectedSection,
                onSectionSelected: _selectSection,
              ),
              Container(
                width: 1,
                color:
                    Settings.tacticalVioletTheme.border.withValues(alpha: 0.9),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 36),
                        child: _SettingsScopeHeader(
                          label: scopeLabel,
                          value: scopeValue,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context)
                              .copyWith(scrollbars: false),
                          child: SingleChildScrollView(
                            controller: _scrollController,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              child: _mode == _SettingsMode.strategy
                                  ? _StrategySettingsSections(
                                      key: const ValueKey('strategy-settings'),
                                      sectionKeys: _sectionKeys,
                                      activeStrategyName: activeStrategyName,
                                      strategySettings: strategySettings,
                                      onManageThemeProfiles: () =>
                                          _selectSection(
                                        _SettingsSection.globalMapProfiles,
                                      ),
                                    )
                                  : _GlobalSettingsSections(
                                      key: const ValueKey('global-settings'),
                                      sectionKeys: _sectionKeys,
                                      appPreferences: appPreferences,
                                      mapState: mapState,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectSection(_SettingsSection section) {
    final nextMode = _modeForSection(section);
    setState(() {
      _mode = nextMode;
      _selectedSection = section;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _sectionKeys[section]?.currentContext;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: 0,
      );
    });
  }

  _SettingsMode _modeForSection(_SettingsSection section) {
    switch (section) {
      case _SettingsSection.strategyObjects:
      case _SettingsSection.strategyMapTheme:
        return _SettingsMode.strategy;
      case _SettingsSection.globalDefaults:
      case _SettingsSection.globalSaving:
      case _SettingsSection.globalMapVisibility:
      case _SettingsSection.globalMapProfiles:
        return _SettingsMode.global;
    }
  }
}

class _SettingsScopeHeader extends StatelessWidget {
  const _SettingsScopeHeader({
    required this.label,
    required this.value,
  });

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final displayValue = value ?? 'Open strategy';

    return Row(
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.small.copyWith(
            color: Settings.tacticalVioletTheme.mutedForeground,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.45,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: Settings.tacticalVioletTheme.secondary
                  .withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color:
                    Settings.tacticalVioletTheme.border.withValues(alpha: 0.9),
              ),
            ),
            child: Text(
              displayValue,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.small.copyWith(
                color: Settings.tacticalVioletTheme.foreground,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StrategySettingsSections extends ConsumerWidget {
  const _StrategySettingsSections({
    super.key,
    required this.sectionKeys,
    required this.activeStrategyName,
    required this.strategySettings,
    required this.onManageThemeProfiles,
  });

  final Map<_SettingsSection, GlobalKey> sectionKeys;
  final String? activeStrategyName;
  final StrategySettings strategySettings;
  final VoidCallback onManageThemeProfiles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.strategyObjects],
          title: "Strategy object styling",
          description: activeStrategyName == null
              ? "Resize markers and control how placed objects render."
              : "Changes apply to \"$activeStrategyName\".",
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
              const _SettingsItemDivider(),
              _SettingsToggleTile(
                icon: Icons.contrast_outlined,
                title: "Neutral team marker colors",
                description:
                    "Render ally and enemy marker accents as matching-brightness greys.",
                value: strategySettings.useNeutralTeamColors,
                onChanged: (value) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!context.mounted) return;
                    ref
                        .read(strategySettingsProvider.notifier)
                        .updateNeutralTeamColors(value);
                    ref
                        .read(strategyProvider.notifier)
                        .applyNeutralTeamColorsToAllPages(value);
                  });
                },
              ),
              const _PageMarkerSizesSyncBanner(),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const _SectionDivider(),
        const SizedBox(height: 20),
        KeyedSubtree(
          key: sectionKeys[_SettingsSection.strategyMapTheme],
          child: MapThemeSettingsSection(
            scope: MapThemeSettingsScope.strategy,
            onManageProfiles: onManageThemeProfiles,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _GlobalSettingsSections extends ConsumerWidget {
  const _GlobalSettingsSections({
    super.key,
    required this.sectionKeys,
    required this.appPreferences,
    required this.mapState,
  });

  final Map<_SettingsSection, GlobalKey> sectionKeys;
  final AppPreferences appPreferences;
  final MapState mapState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalDefaults],
          title: "New strategy defaults",
          description: "Set the marker styling each new strategy starts with.",
          child: Column(
            children: [
              _SettingsSliderTile(
                icon: Icons.person_pin_circle_outlined,
                title: "Default agent markers",
                description:
                    "Default size for agent markers in new strategies.",
                value: appPreferences.defaultAgentSizeForNewStrategies,
                min: Settings.agentSizeMin,
                max: Settings.agentSizeMax,
                divisions: 15,
                accentColor: Settings.tacticalVioletTheme.primary,
                onChanged: (value) {
                  ref
                      .read(appPreferencesProvider.notifier)
                      .setDefaultAgentSizeForNewStrategies(value);
                },
              ),
              const _SettingsItemDivider(),
              _SettingsSliderTile(
                icon: Icons.auto_awesome_outlined,
                title: "Default ability markers",
                description:
                    "Default size for ability markers in new strategies.",
                value: appPreferences.defaultAbilitySizeForNewStrategies,
                min: Settings.abilitySizeMin,
                max: Settings.abilitySizeMax,
                divisions: 15,
                accentColor: Settings.tacticalVioletTheme.primary,
                onChanged: (value) {
                  ref
                      .read(appPreferencesProvider.notifier)
                      .setDefaultAbilitySizeForNewStrategies(value);
                },
              ),
              const _SettingsItemDivider(),
              _SettingsToggleTile(
                icon: Icons.contrast_outlined,
                title: "Neutral marker colors by default",
                description:
                    "Use grey ally and enemy accents for new strategies.",
                value: appPreferences.defaultNeutralTeamColorsForNewStrategies,
                onChanged: (value) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!context.mounted) return;
                    ref
                        .read(appPreferencesProvider.notifier)
                        .setDefaultNeutralTeamColorsForNewStrategies(value);
                  });
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const _SectionDivider(),
        const SizedBox(height: 20),
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalSaving],
          title: "Workspace behavior",
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
          key: sectionKeys[_SettingsSection.globalMapVisibility],
          title: "Workspace map visibility",
          description: "Show or hide map reference layers while you work.",
          child: Column(
            children: [
              _SettingsToggleTile(
                icon: Icons.grid_on_rounded,
                title: "Spawn barriers",
                description:
                    "Keep round-start barrier guides visible on the map.",
                value: mapState.showSpawnBarrier,
                onChanged: (value) {
                  ref.read(mapProvider.notifier).updateSpawnBarrier(value);
                },
              ),
              const _SettingsItemDivider(),
              _SettingsToggleTile(
                icon: Icons.location_on_outlined,
                title: "Region names",
                description: "Show map callout names directly on the canvas.",
                value: mapState.showRegionNames,
                onChanged: (value) {
                  ref.read(mapProvider.notifier).updateRegionNames(value);
                },
              ),
              const _SettingsItemDivider(),
              _SettingsToggleTile(
                icon: Icons.radio_button_checked_outlined,
                title: "Ultimate orbs",
                description: "Display orb pickup markers on supported maps.",
                value: mapState.showUltOrbs,
                onChanged: (value) {
                  ref.read(mapProvider.notifier).updateUltOrbs(value);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const _SectionDivider(),
        const SizedBox(height: 20),
        KeyedSubtree(
          key: sectionKeys[_SettingsSection.globalMapProfiles],
          child: const MapThemeSettingsSection(
            scope: MapThemeSettingsScope.global,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SettingsNavigationRail extends StatelessWidget {
  const _SettingsNavigationRail({
    required this.mode,
    required this.selectedSection,
    required this.onSectionSelected,
  });

  final _SettingsMode mode;
  final _SettingsSection selectedSection;
  final ValueChanged<_SettingsSection> onSectionSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: SettingsTab._navigationWidth,
      color: Settings.tacticalVioletTheme.card.withValues(alpha: 0.72),
      padding: const EdgeInsets.fromLTRB(14, 18, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Settings",
            style: ShadTheme.of(context).textTheme.h4.copyWith(
                  color: Settings.tacticalVioletTheme.foreground,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 18),
          _SettingsNavHeader(
            label: "Current strategy",
            isActive: mode == _SettingsMode.strategy,
            onTap: () => onSectionSelected(_SettingsSection.strategyObjects),
          ),
          const SizedBox(height: 4),
          _SettingsNavItem(
            icon: Icons.tune_outlined,
            label: "Object styling",
            isSelected: selectedSection == _SettingsSection.strategyObjects,
            onTap: () => onSectionSelected(_SettingsSection.strategyObjects),
          ),
          _SettingsNavItem(
            icon: Icons.palette_outlined,
            label: "Map theme",
            isSelected: selectedSection == _SettingsSection.strategyMapTheme,
            onTap: () => onSectionSelected(_SettingsSection.strategyMapTheme),
          ),
          const SizedBox(height: 16),
          _SettingsNavHeader(
            label: "App-wide",
            isActive: mode == _SettingsMode.global,
            onTap: () => onSectionSelected(_SettingsSection.globalDefaults),
          ),
          const SizedBox(height: 4),
          _SettingsNavItem(
            icon: Icons.auto_fix_high_outlined,
            label: "Defaults",
            isSelected: selectedSection == _SettingsSection.globalDefaults,
            onTap: () => onSectionSelected(_SettingsSection.globalDefaults),
          ),
          _SettingsNavItem(
            icon: Icons.save_outlined,
            label: "Autosave",
            isSelected: selectedSection == _SettingsSection.globalSaving,
            onTap: () => onSectionSelected(_SettingsSection.globalSaving),
          ),
          _SettingsNavItem(
            icon: Icons.map_outlined,
            label: "Map layers",
            isSelected: selectedSection == _SettingsSection.globalMapVisibility,
            onTap: () =>
                onSectionSelected(_SettingsSection.globalMapVisibility),
          ),
          _SettingsNavItem(
            icon: Icons.format_color_fill_outlined,
            label: "Theme profiles",
            isSelected: selectedSection == _SettingsSection.globalMapProfiles,
            onTap: () => onSectionSelected(_SettingsSection.globalMapProfiles),
          ),
        ],
      ),
    );
  }
}

class _SettingsNavHeader extends StatelessWidget {
  const _SettingsNavHeader({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isActive
        ? Settings.tacticalVioletTheme.foreground
        : Settings.tacticalVioletTheme.mutedForeground;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: isActive
                    ? Settings.tacticalVioletTheme.primary
                    : Settings.tacticalVioletTheme.mutedForeground
                        .withValues(alpha: 0.36),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: ShadTheme.of(context).textTheme.small.copyWith(
                    color: color,
                    fontWeight: isActive ? FontWeight.w800 : FontWeight.w700,
                    letterSpacing: 0.25,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsNavItem extends StatelessWidget {
  const _SettingsNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.24)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected
                    ? Settings.tacticalVioletTheme.foreground
                    : Settings.tacticalVioletTheme.mutedForeground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: isSelected
                            ? Settings.tacticalVioletTheme.foreground
                            : Settings.tacticalVioletTheme.mutedForeground,
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w500,
                      ),
                ),
              ),
            ],
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
