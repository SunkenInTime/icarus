import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/widgets/client_upgrade_button.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/marker_sizes_sync.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/services/analytics_service.dart';
import 'package:icarus/services/discord_presence_service.dart';
import 'package:icarus/services/guarded_sign_out.dart';
import 'package:icarus/widgets/account_avatar.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/map_theme_settings_section.dart';
import 'package:icarus/widgets/settings_scope_card.dart';
import 'package:icarus/widgets/strategy_edit_boundary.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum _SettingsMode {
  strategy,
  global,
  shortcuts,
}

enum _SettingsSection {
  strategyObjects,
  strategyMapTheme,
  globalAccount,
  globalLanguage,
  globalDefaults,
  globalSaving,
  globalMapVisibility,
  globalPrivacy,
  shortcuts,
}

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});

  static const double _maxDialogWidth = 1080;
  static const double _maxDialogHeight = 820;
  static const double _navigationWidth = 208;

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
    final strategySettings = ref.watch(strategySettingsProvider);
    final mapState = ref.watch(mapProvider);
    final appPreferences = ref.watch(appPreferencesProvider);

    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth =
        (screenSize.width - 96).clamp(560.0, SettingsTab._maxDialogWidth);
    final dialogHeight =
        (screenSize.height - 80).clamp(420.0, SettingsTab._maxDialogHeight);

    return ShadDialog(
      constraints: BoxConstraints(
        maxWidth: dialogWidth,
        maxHeight: dialogHeight,
      ),
      padding: EdgeInsets.zero,
      scrollable: false,
      closeIconPosition: const ShadPosition(top: 18, right: 18),
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SettingsNavigationRail(
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
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context)
                        .copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      child: switch (_mode) {
                        _SettingsMode.strategy => StrategyEditBoundary(
                            disabledOpacity: 0.55,
                            child: _StrategySettingsSections(
                              key: const ValueKey('strategy-settings'),
                              sectionKeys: _sectionKeys,
                              strategySettings: strategySettings,
                            ),
                          ),
                        _SettingsMode.global => _GlobalSettingsSections(
                            key: const ValueKey('global-settings'),
                            sectionKeys: _sectionKeys,
                            appPreferences: appPreferences,
                            mapState: mapState,
                          ),
                        _SettingsMode.shortcuts => _ShortcutSettingsSection(
                            key: _sectionKeys[_SettingsSection.shortcuts],
                          ),
                      },
                    ),
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
    final modeChanged = nextMode != _mode;
    setState(() {
      _mode = nextMode;
      _selectedSection = section;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _sectionKeys[section]?.currentContext;
      if (context == null || !mounted) return;
      if (modeChanged) {
        // New pane: land on the section directly, no scroll animation from a
        // stale offset.
        Scrollable.ensureVisible(context, alignment: 0);
      } else {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 220),
          curve: Settings.easeOut,
          alignment: 0,
        );
      }
    });
  }

  _SettingsMode _modeForSection(_SettingsSection section) {
    switch (section) {
      case _SettingsSection.strategyObjects:
      case _SettingsSection.strategyMapTheme:
        return _SettingsMode.strategy;
      case _SettingsSection.globalAccount:
      case _SettingsSection.globalLanguage:
      case _SettingsSection.globalDefaults:
      case _SettingsSection.globalSaving:
      case _SettingsSection.globalMapVisibility:
      case _SettingsSection.globalPrivacy:
        return _SettingsMode.global;
      case _SettingsSection.shortcuts:
        return _SettingsMode.shortcuts;
    }
  }
}

class _StrategySettingsSections extends ConsumerWidget {
  const _StrategySettingsSections({
    super.key,
    required this.sectionKeys,
    required this.strategySettings,
  });

  final Map<_SettingsSection, GlobalKey> sectionKeys;
  final StrategySettings strategySettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.strategyObjects],
          title: l10n.settingsObjectStyling,
          child: Column(
            children: [
              _SettingsSliderTile(
                icon: LucideIcons.personStanding,
                iconColor: Settings.settingsAgentAccent,
                title: l10n.settingsAgentMarkersTitle,
                description: l10n.settingsAgentMarkersDescription,
                value: strategySettings.agentSize,
                min: Settings.agentSizeMin,
                max: Settings.agentSizeMax,
                divisions: 15,
                accentColor: Settings.accentInk,
                onChanged: (value) {
                  ref
                      .read(strategySettingsProvider.notifier)
                      .updateAgentSize(value);
                  ref.read(strategyProvider.notifier).setUnsaved();
                },
                onChangeCommitted: (start, end) {
                  if (start == end) return;

                  final settings = ref.read(strategySettingsProvider.notifier);
                  settings.updateAgentSize(start);
                  ref.read(actionProvider.notifier).performTransaction(
                    groups: const [ActionGroup.strategySettings],
                    mutation: () => settings.updateAgentSize(end),
                  );
                },
              ),
              _SettingsSliderTile(
                icon: LucideIcons.sparkles,
                iconColor: Settings.settingsAbilityAccent,
                title: l10n.settingsAbilityMarkersTitle,
                description: l10n.settingsAbilityMarkersDescription,
                value: strategySettings.abilitySize,
                min: Settings.abilitySizeMin,
                max: Settings.abilitySizeMax,
                divisions: 15,
                accentColor: Settings.accentInk,
                onChanged: (value) {
                  ref
                      .read(strategySettingsProvider.notifier)
                      .updateAbilitySize(value);
                  ref.read(strategyProvider.notifier).setUnsaved();
                },
                onChangeCommitted: (start, end) {
                  if (start == end) return;

                  final settings = ref.read(strategySettingsProvider.notifier);
                  settings.updateAbilitySize(start);
                  ref.read(actionProvider.notifier).performTransaction(
                    groups: const [ActionGroup.strategySettings],
                    mutation: () => settings.updateAbilitySize(end),
                  );
                },
              ),
              _SettingsToggleTile(
                icon: LucideIcons.contrast,
                iconColor: Settings.settingsNeutralAccent,
                title: l10n.settingsNeutralTeamColorsTitle,
                description: l10n.settingsNeutralTeamColorsDescription,
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
        const SizedBox(height: 28),
        KeyedSubtree(
          key: sectionKeys[_SettingsSection.strategyMapTheme],
          child: const MapThemeSettingsSection(),
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
    final allowsLocalLibrary =
        ref.watch(platformPolicyProvider).allowsLocalLibrary;
    final discordPresenceSupported =
        ref.watch(discordPresenceSupportedProvider);
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AccountSettingsSection(
          key: sectionKeys[_SettingsSection.globalAccount],
        ),
        const SizedBox(height: 20),
        const _SettingsItemDivider(),
        const SizedBox(height: 20),
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalLanguage],
          title: l10n.settingsLanguage,
          child: _LanguageTile(languageCode: appPreferences.languageCode),
        ),
        const SizedBox(height: 28),
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalDefaults],
          title: l10n.settingsNewStrategyDefaultsTitle,
          child: Column(
            children: [
              _SettingsSliderTile(
                icon: LucideIcons.personStanding,
                iconColor: Settings.settingsAgentAccent,
                title: l10n.settingsDefaultAgentMarkersTitle,
                description: l10n.settingsDefaultAgentMarkersDescription,
                value: appPreferences.defaultAgentSizeForNewStrategies,
                min: Settings.agentSizeMin,
                max: Settings.agentSizeMax,
                divisions: 15,
                accentColor: Settings.accentInk,
                onChanged: (value) {
                  ref
                      .read(appPreferencesProvider.notifier)
                      .setDefaultAgentSizeForNewStrategies(value);
                },
              ),
              _SettingsSliderTile(
                icon: LucideIcons.sparkles,
                iconColor: Settings.settingsAbilityAccent,
                title: l10n.settingsDefaultAbilityMarkersTitle,
                description: l10n.settingsDefaultAbilityMarkersDescription,
                value: appPreferences.defaultAbilitySizeForNewStrategies,
                min: Settings.abilitySizeMin,
                max: Settings.abilitySizeMax,
                divisions: 15,
                accentColor: Settings.accentInk,
                onChanged: (value) {
                  ref
                      .read(appPreferencesProvider.notifier)
                      .setDefaultAbilitySizeForNewStrategies(value);
                },
              ),
              _SettingsToggleTile(
                icon: LucideIcons.contrast,
                iconColor: Settings.settingsNeutralAccent,
                title: l10n.settingsDefaultNeutralColorsTitle,
                description: l10n.settingsDefaultNeutralColorsDescription,
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
        if (allowsLocalLibrary || discordPresenceSupported) ...[
          const SizedBox(height: 28),
          SettingsScopeCard(
            key: sectionKeys[_SettingsSection.globalSaving],
            title: l10n.settingsWorkspaceBehaviorTitle,
            child: Column(
              children: [
                // Autosave only covers strategies on this device.
                if (allowsLocalLibrary)
                  _SettingsToggleTile(
                    icon: LucideIcons.save,
                    iconColor: Settings.settingsPersistenceAccent,
                    title: l10n.settingsAutosaveTitle,
                    description: l10n.settingsAutosaveDescription,
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
                if (discordPresenceSupported)
                  _SettingsToggleTile(
                    icon: LucideIcons.gamepad2,
                    iconColor: Settings.settingsDiscordAccent,
                    title: l10n.settingsDiscordPresenceTitle,
                    description: l10n.settingsDiscordPresenceDescription,
                    value: appPreferences.discordPresenceEnabled,
                    onChanged: (value) {
                      ref
                          .read(appPreferencesProvider.notifier)
                          .setDiscordPresenceEnabled(value);
                    },
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 28),
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalMapVisibility],
          title: l10n.settingsMapVisibilityTitle,
          child: Column(
            children: [
              _SettingsToggleTile(
                icon: LucideIcons.grid3x3,
                iconColor: Settings.settingsMapAccent,
                title: l10n.settingsSpawnBarriersTitle,
                description: l10n.settingsSpawnBarriersDescription,
                value: mapState.showSpawnBarrier,
                onChanged: (value) {
                  ref.read(mapProvider.notifier).updateSpawnBarrier(value);
                },
              ),
              _SettingsToggleTile(
                icon: LucideIcons.mapPin,
                iconColor: Settings.settingsMapAccent,
                title: l10n.settingsRegionNamesTitle,
                description: l10n.settingsRegionNamesDescription,
                value: mapState.showRegionNames,
                onChanged: (value) {
                  ref.read(mapProvider.notifier).updateRegionNames(value);
                },
              ),
              _SettingsToggleTile(
                icon: LucideIcons.circleDot,
                iconColor: Settings.settingsMapAccent,
                title: l10n.settingsUltOrbsTitle,
                description: l10n.settingsUltOrbsDescription,
                value: mapState.showUltOrbs,
                onChanged: (value) {
                  ref.read(mapProvider.notifier).updateUltOrbs(value);
                },
              ),
              _SettingsToggleTile(
                icon: LucideIcons.messageSquareText,
                iconColor: Settings.settingsMapAccent,
                title: l10n.settingsCaptionsTitle,
                description: l10n.settingsCaptionsDescription,
                value: appPreferences.showCaptions,
                onChanged: (value) {
                  ref
                      .read(appPreferencesProvider.notifier)
                      .setShowCaptions(value);
                },
              ),
              _SettingsSliderTile(
                icon: LucideIcons.grip,
                iconColor: Settings.settingsMapAccent,
                title: l10n.settingsBackgroundDotsTitle,
                description: l10n.settingsBackgroundDotsDescription,
                value: appPreferences.backgroundDotOpacity,
                min: 0,
                max: 1,
                divisions: 20,
                accentColor: Settings.accentInk,
                valueLabel: (value) =>
                    l10n.settingsPercentValue((value * 100).round()),
                onChanged: (value) {
                  ref
                      .read(appPreferencesProvider.notifier)
                      .setBackgroundDotOpacity(value);
                },
              ),
              _SettingsSliderTile(
                icon: LucideIcons.eye,
                iconColor: Settings.settingsMapAccent,
                title: l10n.settingsViewConesTitle,
                description: l10n.settingsViewConesDescription,
                value: appPreferences.viewConeOpacity,
                min: AppPreferences.minViewConeOpacity,
                max: 1,
                divisions: 18,
                accentColor: Settings.accentInk,
                valueLabel: (value) =>
                    l10n.settingsPercentValue((value * 100).round()),
                onChanged: (value) {
                  ref
                      .read(appPreferencesProvider.notifier)
                      .setViewConeOpacity(value);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalPrivacy],
          title: l10n.settingsPrivacy,
          child: _SettingsToggleTile(
            icon: LucideIcons.chartColumn,
            iconColor: Settings.settingsPersistenceAccent,
            title: l10n.settingsAnalyticsTitle,
            description: l10n.settingsAnalyticsDescription,
            value: ref.watch(analyticsEnabledProvider),
            onChanged: (value) async {
              await ref
                  .read(analyticsEnabledProvider.notifier)
                  .setEnabled(value);
            },
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ShortcutSettingsSection extends ConsumerStatefulWidget {
  const _ShortcutSettingsSection({super.key});

  @override
  ConsumerState<_ShortcutSettingsSection> createState() =>
      _ShortcutSettingsSectionState();
}

class _ShortcutSettingsSectionState
    extends ConsumerState<_ShortcutSettingsSection> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _editingShortcutId;
  String? _duplicateMessage;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final customBindings = ref.watch(
      appPreferencesProvider.select((prefs) => prefs.customShortcutBindings),
    );
    final visibleDefinitions = ShortcutInfo.editableShortcuts
        .where(
          (definition) => ShortcutInfo.matchesSearch(
            definition,
            _query,
            customBindings,
            l10n,
          ),
        )
        .toList(growable: false);
    final snapToMapMatches = _snapToMapMatches(l10n);

    return SettingsScopeCard(
      title: l10n.settingsKeybinds,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _ShortcutSearchField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              const SizedBox(width: 12),
              ShadButton.secondary(
                size: ShadButtonSize.sm,
                leading: const Icon(LucideIcons.rotateCcw, size: 15),
                onPressed: customBindings.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _editingShortcutId = null;
                          _duplicateMessage = null;
                        });
                        ref
                            .read(appPreferencesProvider.notifier)
                            .resetAllCustomShortcutBindings();
                      },
                child: Text(l10n.settingsKeybindsRestoreDefaults),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const _ShortcutTableHeader(),
          const SizedBox(height: 4),
          // The Alt row isn't a definition, but it can be what matched.
          if (visibleDefinitions.isEmpty && !snapToMapMatches)
            const _ShortcutEmptySearch()
          else
            for (final definition in visibleDefinitions) ...[
              _ShortcutBindingRow(
                definition: definition,
                customBindings: customBindings,
                isEditing: _editingShortcutId == definition.id,
                duplicateMessage: _editingShortcutId == definition.id
                    ? _duplicateMessage
                    : null,
                onEdit: () {
                  setState(() {
                    _editingShortcutId = definition.id;
                    _duplicateMessage = null;
                  });
                },
                onCancel: () {
                  setState(() {
                    _editingShortcutId = null;
                    _duplicateMessage = null;
                  });
                },
                onReset: ShortcutInfo.isDefaultBinding(
                  definition.id,
                  customBindings,
                )
                    ? null
                    : () {
                        setState(() {
                          _editingShortcutId = null;
                          _duplicateMessage = null;
                        });
                        ref
                            .read(appPreferencesProvider.notifier)
                            .resetCustomShortcutBinding(definition.id);
                      },
                onCaptured: (binding, triggerShake) {
                  final duplicate = ShortcutInfo.findDuplicateBinding(
                    editingShortcutId: definition.id,
                    binding: binding,
                    customBindings: customBindings,
                  );
                  if (duplicate != null) {
                    triggerShake();
                    setState(() {
                      _duplicateMessage = l10n.settingsKeybindsAlreadyBound(
                        binding.displayLabel(),
                        duplicate.title(l10n),
                      );
                    });
                    return;
                  }
                  ref
                      .read(appPreferencesProvider.notifier)
                      .setCustomShortcutBinding(
                        definition.id,
                        binding.serialize(),
                      );
                  setState(() {
                    _editingShortcutId = null;
                    _duplicateMessage = null;
                  });
                },
              ),
              const _SettingsItemDivider(),
            ],
          if (snapToMapMatches) const _SnapToMapRow(),
        ],
      ),
    );
  }

  bool _snapToMapMatches(AppLocalizations l10n) {
    final query = ShortcutInfo.normalizeSearch(_query);
    return ShortcutInfo.normalizeSearch(
      '${l10n.settingsKeybindsSnapToMap} ${l10n.settingsKeybindsHoldAlt}',
    ).contains(query);
  }
}

/// Alt snapping a dragged item onto the map's lines. It changes a drag
/// rather than doing anything itself, so it can't be rebound, but this is
/// where people look for what a key does.
class _SnapToMapRow extends StatelessWidget {
  const _SnapToMapRow();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.settingsKeybindsSnapToMap,
              style: ShadTheme.of(context).textTheme.p.copyWith(
                    color: Settings.tacticalVioletTheme.foreground,
                    fontWeight: FontWeight.w400,
                  ),
            ),
          ),
          const SizedBox(width: 40),
          SizedBox(
            width: 132,
            child: Align(
              alignment: Alignment.centerRight,
              child: _ShortcutBindingPill(
                label: l10n.settingsKeybindsHoldAlt,
                isEditing: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutSearchField extends StatelessWidget {
  const _ShortcutSearchField({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: TextEditingShortcutScope(
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          style: TextStyle(
            color: Settings.tacticalVioletTheme.foreground,
            fontSize: 13,
          ),
          cursorColor: Settings.accentInk,
          decoration: InputDecoration(
            isDense: true,
            hintText: context.l10n.settingsKeybindsSearchHint,
            hintStyle: TextStyle(
              color: Settings.tacticalVioletTheme.mutedForeground,
              fontSize: 13,
            ),
            prefixIcon: Icon(
              LucideIcons.search,
              size: 17,
              color: Settings.tacticalVioletTheme.mutedForeground,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            filled: true,
            fillColor: Settings.tacticalVioletTheme.card,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: Settings.tacticalVioletTheme.border,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(
                color: Settings.accentInk,
                width: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutTableHeader extends StatelessWidget {
  const _ShortcutTableHeader();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.settingsKeybindsActionColumn,
              style: theme.textTheme.small.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground,
                fontSize: 12,
              ),
            ),
          ),
          SizedBox(
            width: 132,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                l10n.settingsKeybindsBindingColumn,
                style: theme.textTheme.small.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutBindingRow extends StatelessWidget {
  const _ShortcutBindingRow({
    required this.definition,
    required this.customBindings,
    required this.isEditing,
    required this.onEdit,
    required this.onCancel,
    required this.onCaptured,
    this.duplicateMessage,
    this.onReset,
  });

  final IcarusShortcutDefinition definition;
  final Map<String, String> customBindings;
  final bool isEditing;
  final String? duplicateMessage;
  final VoidCallback onEdit;
  final VoidCallback onCancel;
  final VoidCallback? onReset;
  final void Function(IcarusKeyBinding binding, VoidCallback triggerShake)
      onCaptured;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final binding = ShortcutInfo.effectiveBindingFor(
      definition.id,
      customBindings,
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Settings.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: isEditing
          ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.06)
          : Colors.transparent,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  definition.title(context.l10n),
                  style: theme.textTheme.p.copyWith(
                    color: Settings.tacticalVioletTheme.foreground,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              if (onReset != null)
                ShadTooltip(
                  builder: (_) => Text(context.l10n.settingsKeybindsResetTooltip),
                  child: ShadIconButton.ghost(
                    icon: const Icon(LucideIcons.undo2, size: 15),
                    onPressed: onReset,
                  ),
                )
              else
                const SizedBox(width: 32),
              const SizedBox(width: 8),
              SizedBox(
                width: 132,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    mouseCursor: SystemMouseCursors.click,
                    onTap: onEdit,
                    child: _ShortcutBindingPill(
                      label: binding.displayLabel(),
                      isEditing: isEditing,
                    ),
                  ),
                ),
              ),
            ],
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Settings.easeOut,
            switchOutCurve: Settings.easeOut.flipped,
            child: isEditing
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _ShortcutCaptureField(
                      duplicateMessage: duplicateMessage,
                      onCancel: onCancel,
                      onCaptured: onCaptured,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _ShortcutBindingPill extends StatelessWidget {
  const _ShortcutBindingPill({
    required this.label,
    required this.isEditing,
  });

  final String label;
  final bool isEditing;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Settings.easeOut,
      constraints: const BoxConstraints(minWidth: 56),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: isEditing
            ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.16)
            : Settings.tacticalVioletTheme.secondary.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isEditing
              ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.34)
              : Settings.tacticalVioletTheme.border.withValues(alpha: 0.9),
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: ShadTheme.of(context).textTheme.small.copyWith(
              color: Settings.tacticalVioletTheme.foreground,
              height: 1.1,
            ),
      ),
    );
  }
}

class _ShortcutCaptureField extends StatefulWidget {
  const _ShortcutCaptureField({
    required this.onCaptured,
    required this.onCancel,
    this.duplicateMessage,
  });

  final void Function(IcarusKeyBinding binding, VoidCallback triggerShake)
      onCaptured;
  final VoidCallback onCancel;
  final String? duplicateMessage;

  @override
  State<_ShortcutCaptureField> createState() => _ShortcutCaptureFieldState();
}

class _ShortcutCaptureFieldState extends State<_ShortcutCaptureField>
    with SingleTickerProviderStateMixin {
  late final FocusNode _focusNode;
  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -7), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -7, end: 7), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 7, end: -4), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -4, end: 0), weight: 1),
    ]).animate(
      CurvedAnimation(parent: _shakeController, curve: Settings.easeOut),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _triggerShake() {
    _shakeController
      ..reset()
      ..forward();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onCancel();
      return KeyEventResult.handled;
    }

    final binding = IcarusKeyBinding.fromPressedKeys(
      HardwareKeyboard.instance.logicalKeysPressed,
    );
    if (!binding.isComplete) return KeyEventResult.handled;
    widget.onCaptured(binding, _triggerShake);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final hasDuplicate = widget.duplicateMessage != null;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedBuilder(
            animation: _shakeAnimation,
            builder: (context, child) {
              return Transform.translate(
                offset: Offset(_shakeAnimation.value, 0),
                child: child,
              );
            },
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Settings.tacticalVioletTheme.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: hasDuplicate
                      ? Settings.tacticalVioletTheme.destructive
                      : Settings.accentInk.withValues(alpha: 0.65),
                  width: hasDuplicate ? 1.4 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.keyboard,
                    size: 17,
                    color: hasDuplicate
                        ? Settings.tacticalVioletTheme.destructive
                        : Settings.accentInk,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      context.l10n.settingsKeybindsCapturePrompt,
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color: Settings.tacticalVioletTheme.foreground,
                          ),
                    ),
                  ),
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: widget.onCancel,
                    child: Text(context.l10n.commonCancel),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Settings.easeOut,
            switchOutCurve: Settings.easeOut.flipped,
            child: hasDuplicate
                ? Padding(
                    key: ValueKey(widget.duplicateMessage),
                    padding: const EdgeInsets.only(top: 7),
                    child: Text(
                      widget.duplicateMessage!,
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color: Settings.tacticalVioletTheme.destructive,
                          ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text(
                      context.l10n.settingsKeybindsCaptureHelp,
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color: Settings.tacticalVioletTheme.mutedForeground,
                          ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutEmptySearch extends StatelessWidget {
  const _ShortcutEmptySearch();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(
          context.l10n.settingsKeybindsNoMatches,
          style: ShadTheme.of(context).textTheme.small.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground,
              ),
        ),
      ),
    );
  }
}

class AccountSettingsSection extends ConsumerWidget {
  const AccountSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final l10n = context.l10n;

    return SettingsScopeCard(
      title: l10n.settingsAccount,
      description: authState.isAuthenticated
          ? l10n.settingsAccountSignedInDescription
          : l10n.settingsAccountSignedOutDescription,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Settings.easeOut,
        switchOutCurve: Settings.easeOut.flipped,
        child: authState.isAuthenticated
            ? _SignedInAccountRow(
                key: const ValueKey('account-signed-in'),
                authState: authState,
              )
            : Padding(
                key: const ValueKey('account-signed-out'),
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.cloudOff,
                      size: 18,
                      color: Settings.tacticalVioletTheme.mutedForeground,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.settingsAccountNotSignedIn,
                        style: TextStyle(
                          color: Settings.tacticalVioletTheme.mutedForeground,
                        ),
                      ),
                    ),
                    ShadButton(
                      size: ShadButtonSize.sm,
                      onPressed: authState.isLoading
                          ? null
                          : () {
                              showDialog<void>(
                                context: context,
                                builder: (_) => const AuthDialog(),
                              );
                            },
                      child: Text(l10n.commonLogIn),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _SignedInAccountRow extends ConsumerWidget {
  const _SignedInAccountRow({super.key, required this.authState});

  final AppAuthState authState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = Settings.tacticalVioletTheme;
    final email = authState.user?.email;
    final avatarUrl = authState.avatarUrl;
    // The server refuses this build. Reconnecting can't help; reloading or
    // updating can, so this row says what the sync button says.
    final needsNewerIcarus = ref.watch(clientUpgradeRequiredProvider);
    final l10n = context.l10n;

    final (String statusLabel, IconData statusIcon, Color statusColor) =
        needsNewerIcarus
            ? (
                l10n.settingsSyncNeedsNewerIcarus,
                LucideIcons.circleAlert,
                theme.destructive,
              )
            : switch (authState.convexAuthStatus) {
                ConvexAuthStatus.ready => (
                    l10n.settingsSyncActive,
                    LucideIcons.cloudCheck,
                    theme.mutedForeground,
                  ),
                ConvexAuthStatus.configuring => (
                    l10n.settingsSyncConnecting,
                    LucideIcons.refreshCw,
                    theme.mutedForeground,
                  ),
                ConvexAuthStatus.offline => (
                    l10n.settingsSyncOffline,
                    LucideIcons.cloudOff,
                    theme.mutedForeground,
                  ),
                ConvexAuthStatus.incident => (
                    l10n.settingsSyncNeedsAttention,
                    LucideIcons.circleAlert,
                    theme.destructive,
                  ),
                ConvexAuthStatus.signedOut => (
                    l10n.settingsSyncInactive,
                    LucideIcons.cloudOff,
                    theme.mutedForeground,
                  ),
              };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          AccountAvatar(
            radius: 16,
            backgroundColor: theme.muted,
            avatarUrl: avatarUrl,
            fallback: Text(
              authState.displayName(l10n).characters.first.toUpperCase(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.foreground,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  authState.displayName(l10n),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (email != null && email != authState.displayName(l10n))
                  Text(
                    email,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.mutedForeground,
                      fontSize: 12,
                    ),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(statusIcon, size: 13, color: statusColor),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        statusLabel,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (needsNewerIcarus) ...[
            ClientUpgradeNotice(
              buttonSize: ShadButtonSize.sm,
              builder: (context, message, action) =>
                  action ?? const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
          ] else if (authState.convexAuthStatus ==
              ConvexAuthStatus.incident) ...[
            ShadButton(
              size: ShadButtonSize.sm,
              onPressed: () {
                ref
                    .read(authProvider.notifier)
                    .reinitializeConvexAuth(source: 'settings_account');
              },
              child: Text(l10n.commonReconnect),
            ),
            const SizedBox(width: 8),
          ],
          ShadButton.outline(
            key: const ValueKey('settings-sign-out'),
            size: ShadButtonSize.sm,
            onPressed: authState.isLoading
                ? null
                : () async {
                    await ref.read(guardedSignOutRequestProvider)(context);
                  },
            child: Text(l10n.commonSignOut),
          ),
        ],
      ),
    );
  }
}

class _SettingsNavigationRail extends ConsumerWidget {
  const _SettingsNavigationRail({
    required this.selectedSection,
    required this.onSectionSelected,
  });

  final _SettingsSection selectedSection;
  final ValueChanged<_SettingsSection> onSectionSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowsLocalLibrary =
        ref.watch(platformPolicyProvider).allowsLocalLibrary;
    final l10n = context.l10n;

    return Container(
      width: SettingsTab._navigationWidth,
      color: Settings.tacticalVioletTheme.card.withValues(alpha: 0.72),
      padding: const EdgeInsets.fromLTRB(14, 18, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.settingsTitle,
            style: ShadTheme.of(context).textTheme.h4.copyWith(
                  color: Settings.tacticalVioletTheme.foreground,
                  fontWeight: FontWeight.w500,
                ),
          ),
          const SizedBox(height: 20),
          _SettingsNavHeader(label: l10n.settingsNavCurrentStrategy),
          const SizedBox(height: 4),
          _SettingsNavItem(
            icon: LucideIcons.slidersHorizontal,
            label: l10n.settingsObjectStyling,
            isSelected: selectedSection == _SettingsSection.strategyObjects,
            onTap: () => onSectionSelected(_SettingsSection.strategyObjects),
          ),
          _SettingsNavItem(
            icon: LucideIcons.palette,
            label: l10n.mapThemeTitle,
            isSelected: selectedSection == _SettingsSection.strategyMapTheme,
            onTap: () => onSectionSelected(_SettingsSection.strategyMapTheme),
          ),
          const SizedBox(height: 20),
          _SettingsNavHeader(label: l10n.settingsNavAppWide),
          const SizedBox(height: 4),
          _SettingsNavItem(
            icon: LucideIcons.user,
            label: l10n.settingsAccount,
            isSelected: selectedSection == _SettingsSection.globalAccount,
            onTap: () => onSectionSelected(_SettingsSection.globalAccount),
          ),
          _SettingsNavItem(
            icon: LucideIcons.languages,
            label: l10n.settingsLanguage,
            isSelected: selectedSection == _SettingsSection.globalLanguage,
            onTap: () => onSectionSelected(_SettingsSection.globalLanguage),
          ),
          _SettingsNavItem(
            icon: LucideIcons.wandSparkles,
            label: l10n.settingsNavDefaults,
            isSelected: selectedSection == _SettingsSection.globalDefaults,
            onTap: () => onSectionSelected(_SettingsSection.globalDefaults),
          ),
          if (allowsLocalLibrary)
            _SettingsNavItem(
              icon: LucideIcons.save,
              label: l10n.settingsNavAutosave,
              isSelected: selectedSection == _SettingsSection.globalSaving,
              onTap: () => onSectionSelected(_SettingsSection.globalSaving),
            ),
          _SettingsNavItem(
            icon: LucideIcons.map,
            label: l10n.settingsNavMapLayers,
            isSelected: selectedSection == _SettingsSection.globalMapVisibility,
            onTap: () =>
                onSectionSelected(_SettingsSection.globalMapVisibility),
          ),
          _SettingsNavItem(
            icon: LucideIcons.shield,
            label: l10n.settingsPrivacy,
            isSelected: selectedSection == _SettingsSection.globalPrivacy,
            onTap: () => onSectionSelected(_SettingsSection.globalPrivacy),
          ),
          _SettingsNavItem(
            icon: LucideIcons.keyboard,
            label: l10n.settingsKeybinds,
            isSelected: selectedSection == _SettingsSection.shortcuts,
            onTap: () => onSectionSelected(_SettingsSection.shortcuts),
          ),
          const Spacer(),
          const _VersionFooter(),
        ],
      ),
    );
  }
}

/// The build number, tucked under the navigation. Click copies it for bug
/// reports.
class _VersionFooter extends StatelessWidget {
  const _VersionFooter();

  static const String _label =
      'Icarus ${Settings.versionName} (${Settings.versionNumber})';

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return ShadTooltip(
      builder: (context) => Text(context.l10n.settingsCopyVersionTooltip),
      child: ShadButton.ghost(
        key: const ValueKey('settings-version'),
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: theme.mutedForeground,
        hoverForegroundColor: theme.foreground,
        onPressed: () {
          Clipboard.setData(const ClipboardData(text: _label));
          Settings.showToast(
            message: context.l10n.settingsVersionCopied,
            backgroundColor: theme.primary,
          );
        },
        child: const Text(_label, style: TextStyle(fontSize: 11)),
      ),
    );
  }
}

class _SettingsNavHeader extends StatelessWidget {
  const _SettingsNavHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Text(
        label,
        style: ShadTheme.of(context).textTheme.small.copyWith(
              color: Settings.tacticalVioletTheme.mutedForeground,
              fontSize: 12,
              fontWeight: FontWeight.w400,
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
    const theme = Settings.tacticalVioletTheme;
    final contentColor = isSelected ? theme.foreground : theme.mutedForeground;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(8),
          hoverColor: theme.secondary.withValues(alpha: 0.45),
          highlightColor: theme.secondary.withValues(alpha: 0.6),
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              color: isSelected
                  ? theme.secondary.withValues(alpha: 0.9)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SizedBox(
              height: 34,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 16,
                      color: isSelected ? theme.primary : contentColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: ShadTheme.of(context).textTheme.small.copyWith(
                              color: contentColor,
                              fontWeight: FontWeight.w400,
                            ),
                      ),
                    ),
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

class _SettingsSliderTile extends StatefulWidget {
  const _SettingsSliderTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.accentColor,
    required this.onChanged,
    this.onChangeCommitted,
    this.valueLabel,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final Color accentColor;
  final ValueChanged<double> onChanged;
  final void Function(double start, double end)? onChangeCommitted;
  final String Function(double value)? valueLabel;

  @override
  State<_SettingsSliderTile> createState() => _SettingsSliderTileState();
}

class _SettingsSliderTileState extends State<_SettingsSliderTile> {
  double? _dragStartValue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Icon(
                  widget.icon,
                  size: 20,
                  color: widget.iconColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title),
                    const SizedBox(height: 2),
                    Text(
                      widget.description,
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color: Settings.tacticalVioletTheme.mutedForeground,
                            fontSize: 12,
                            height: 1.35,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                widget.valueLabel?.call(widget.value) ??
                    widget.value.toStringAsFixed(0),
                style: ShadTheme.of(context).textTheme.small.copyWith(
                  color: Settings.tacticalVioletTheme.foreground,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 24,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: widget.accentColor,
                thumbColor: widget.accentColor,
                overlayColor: widget.accentColor.withValues(alpha: 0.12),
                inactiveTrackColor: Settings.tacticalVioletTheme.secondary,
                trackHeight: 2.8,
                mouseCursor:
                    const WidgetStatePropertyAll(SystemMouseCursors.click),
              ),
              child: Slider(
                min: widget.min,
                max: widget.max,
                divisions: widget.divisions,
                value: widget.value,
                onChangeStart: (value) => _dragStartValue = value,
                onChangeEnd: (value) {
                  widget.onChangeCommitted?.call(
                    _dragStartValue ?? widget.value,
                    value,
                  );
                  _dragStartValue = null;
                },
                onChanged: widget.onChanged,
              ),
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
    required this.iconColor,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Icon(
              icon,
              size: 20,
              color: iconColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: Settings.tacticalVioletTheme.mutedForeground,
                        fontSize: 12,
                        height: 1.35,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ShadCheckbox(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Picks the language Icarus shows. Each language is listed under its own
/// name, so it can be found by someone who can't read the current one.
class _LanguageTile extends ConsumerWidget {
  const _LanguageTile({required this.languageCode});

  /// The language picked, or null while Icarus follows the system.
  final String? languageCode;

  static const _system = '';
  static const _names = {'en': 'English', 'ja': '日本語', 'zh': '简体中文'};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    String label(String code) =>
        code == _system ? l10n.settingsLanguageSystem : _names[code]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: Icon(
              LucideIcons.languages,
              size: 20,
              color: Settings.settingsPersistenceAccent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.settingsLanguageTitle),
                const SizedBox(height: 2),
                Text(
                  l10n.settingsLanguageDescription,
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: Settings.tacticalVioletTheme.mutedForeground,
                        fontSize: 12,
                        height: 1.35,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ShadSelect<String>(
            // Keyed by the language shown, so the list's own words follow it.
            key: ValueKey('language-${l10n.localeName}-$languageCode'),
            initialValue: languageCode ?? _system,
            minWidth: 168,
            selectedOptionBuilder: (context, value) => Text(label(value)),
            options: [
              for (final code in [_system, ..._names.keys])
                ShadOption(value: code, child: Text(label(code))),
            ],
            onChanged: (value) {
              if (value == null) return;
              ref
                  .read(appPreferencesProvider.notifier)
                  .setLanguageCode(value == _system ? null : value);
            },
          ),
        ],
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
      color: Settings.tacticalVioletTheme.border.withValues(alpha: 0.55),
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
    final activePageId = ref.watch(
        strategyPageSessionProvider.select((state) => state.activePageId));
    final liveSettings = ref.watch(strategySettingsProvider);
    final strategyId = stratState.strategyId;
    final strategy = strategyId == null
        ? null
        : Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategyId);
    final showCta = stratState.strategyName != null &&
        markerSizesDifferAcrossPages(
          strategy: strategy,
          activePageId: activePageId,
          liveSettings: liveSettings,
        );

    return SizedBox(
      width: double.infinity,
      child: AnimatedCrossFade(
        firstCurve: Settings.easeOut.flipped,
        secondCurve: Settings.easeOut,
        sizeCurve: Settings.easeOut,
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
                context.l10n.settingsMarkerSizesDiffer,
                style: ShadTheme.of(context).textTheme.small.copyWith(
                      color: Settings.tacticalVioletTheme.mutedForeground,
                      height: 1.35,
                    ),
              ),
              const SizedBox(height: 8),
              ShadButton(
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
                child: Text(
                  _busy
                      ? context.l10n.settingsApplyingMarkerSizes
                      : context.l10n.settingsApplyMarkerSizesToAllPages,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
