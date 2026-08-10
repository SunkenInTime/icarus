import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/marker_sizes_sync.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/services/analytics_service.dart';
import 'package:icarus/widgets/map_theme_settings_section.dart';
import 'package:icarus/widgets/settings_scope_card.dart';
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
                        _SettingsMode.strategy => _StrategySettingsSections(
                            key: const ValueKey('strategy-settings'),
                            sectionKeys: _sectionKeys,
                            strategySettings: strategySettings,
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
          curve: Curves.easeOutCubic,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.strategyObjects],
          title: "Object styling",
          child: Column(
            children: [
              _SettingsSliderTile(
                icon: Icons.person_pin_circle_outlined,
                iconColor: Settings.settingsAgentAccent,
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
                icon: Icons.auto_awesome_outlined,
                iconColor: Settings.settingsAbilityAccent,
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
                icon: Icons.contrast_outlined,
                iconColor: Settings.settingsNeutralAccent,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalDefaults],
          title: "New strategy defaults",
          child: Column(
            children: [
              _SettingsSliderTile(
                icon: Icons.person_pin_circle_outlined,
                iconColor: Settings.settingsAgentAccent,
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
              _SettingsSliderTile(
                icon: Icons.auto_awesome_outlined,
                iconColor: Settings.settingsAbilityAccent,
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
              _SettingsToggleTile(
                icon: Icons.contrast_outlined,
                iconColor: Settings.settingsNeutralAccent,
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
        const SizedBox(height: 28),
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalSaving],
          title: "Workspace behavior",
          child: Column(
            children: [
              _SettingsToggleTile(
                icon: Icons.save_outlined,
                iconColor: Settings.settingsPersistenceAccent,
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
              _SettingsToggleTile(
                icon: Icons.sports_esports_outlined,
                iconColor: Settings.settingsDiscordAccent,
                title: "Discord Rich Presence",
                description:
                    "Show the current map and attack or defense side on your Discord profile. Strategy names are never shared.",
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
        const SizedBox(height: 28),
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalMapVisibility],
          title: "Workspace map visibility",
          child: Column(
            children: [
              _SettingsToggleTile(
                icon: Icons.grid_on_rounded,
                iconColor: Settings.settingsMapAccent,
                title: "Spawn barriers",
                description:
                    "Keep round-start barrier guides visible on the map.",
                value: mapState.showSpawnBarrier,
                onChanged: (value) {
                  ref.read(mapProvider.notifier).updateSpawnBarrier(value);
                },
              ),
              _SettingsToggleTile(
                icon: Icons.location_on_outlined,
                iconColor: Settings.settingsMapAccent,
                title: "Region names",
                description: "Show map callout names directly on the canvas.",
                value: mapState.showRegionNames,
                onChanged: (value) {
                  ref.read(mapProvider.notifier).updateRegionNames(value);
                },
              ),
              _SettingsToggleTile(
                icon: Icons.radio_button_checked_outlined,
                iconColor: Settings.settingsMapAccent,
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
        const SizedBox(height: 28),
        SettingsScopeCard(
          key: sectionKeys[_SettingsSection.globalPrivacy],
          title: "Privacy",
          child: _SettingsToggleTile(
            icon: Icons.analytics_outlined,
            iconColor: Settings.settingsPersistenceAccent,
            title: "Anonymous analytics",
            description:
                "Share app opens and a few feature-use events — never strategy content or personal details.",
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
    final customBindings = ref.watch(
      appPreferencesProvider.select((prefs) => prefs.customShortcutBindings),
    );
    final visibleDefinitions = ShortcutInfo.editableShortcuts
        .where(
          (definition) => ShortcutInfo.matchesSearch(
            definition,
            _query,
            customBindings,
          ),
        )
        .toList(growable: false);

    return SettingsScopeCard(
      title: "Keybinds",
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
                leading: const Icon(Icons.restart_alt_outlined, size: 15),
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
                child: const Text("Restore Defaults"),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const _ShortcutTableHeader(),
          const SizedBox(height: 4),
          if (visibleDefinitions.isEmpty)
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
                      _duplicateMessage =
                          "${binding.displayLabel()} is already bound to ${duplicate.title}.";
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
          cursorColor: Settings.tacticalVioletTheme.primary,
          decoration: InputDecoration(
            isDense: true,
            hintText: "Search actions or keys...",
            hintStyle: TextStyle(
              color: Settings.tacticalVioletTheme.mutedForeground,
              fontSize: 13,
            ),
            prefixIcon: Icon(
              Icons.search,
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
              borderSide: BorderSide(
                color: Settings.tacticalVioletTheme.primary,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              "Action",
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
                "Binding",
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
      curve: Curves.easeOutCubic,
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
                  definition.title,
                  style: theme.textTheme.p.copyWith(
                    color: Settings.tacticalVioletTheme.foreground,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              if (onReset != null)
                ShadTooltip(
                  builder: (_) => const Text("Reset to default"),
                  child: ShadIconButton.ghost(
                    icon: const Icon(Icons.undo_outlined, size: 15),
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
      curve: Curves.easeOutCubic,
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
      CurvedAnimation(parent: _shakeController, curve: Curves.easeOutCubic),
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
                      : Settings.tacticalVioletTheme.primary
                          .withValues(alpha: 0.65),
                  width: hasDuplicate ? 1.4 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.keyboard_alt_outlined,
                    size: 17,
                    color: hasDuplicate
                        ? Settings.tacticalVioletTheme.destructive
                        : Settings.tacticalVioletTheme.primary,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      "Press new shortcut...",
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color: Settings.tacticalVioletTheme.foreground,
                          ),
                    ),
                  ),
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: widget.onCancel,
                    child: const Text("Cancel"),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
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
                      "Escape cancels. Ctrl and Cmd are saved as one platform-aware Primary modifier.",
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
          "No shortcuts match that search.",
          style: ShadTheme.of(context).textTheme.small.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground,
              ),
        ),
      ),
    );
  }
}

class _SettingsNavigationRail extends StatelessWidget {
  const _SettingsNavigationRail({
    required this.selectedSection,
    required this.onSectionSelected,
  });

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
                  fontWeight: FontWeight.w500,
                ),
          ),
          const SizedBox(height: 20),
          const _SettingsNavHeader(label: "Current strategy"),
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
          const SizedBox(height: 20),
          const _SettingsNavHeader(label: "App-wide"),
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
            icon: Icons.privacy_tip_outlined,
            label: "Privacy",
            isSelected: selectedSection == _SettingsSection.globalPrivacy,
            onTap: () => onSectionSelected(_SettingsSection.globalPrivacy),
          ),
          _SettingsNavItem(
            icon: Icons.keyboard_alt_outlined,
            label: "Keybinds",
            isSelected: selectedSection == _SettingsSection.shortcuts,
            onTap: () => onSectionSelected(_SettingsSection.shortcuts),
          ),
        ],
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
                child: Text(_busy ? 'Applying…' : 'Apply to all pages'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
