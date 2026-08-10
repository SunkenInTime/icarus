import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/map_theme_editor_dialog.dart';
import 'package:icarus/widgets/settings_scope_card.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The single home for map themes: pick the open strategy's theme, manage
/// profiles, and jump into the live editor. Every path routes through
/// [showMapThemeEditorDialog].
class MapThemeSettingsSection extends ConsumerWidget {
  const MapThemeSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customCount = ref
        .watch(mapThemeProfilesProvider)
        .profiles
        .where((p) => !p.isBuiltIn)
        .length;

    return SettingsScopeCard(
      title: "Map theme",
      trailing: Text(
        "$customCount/${MapThemeProfilesProvider.customProfilesSoftCap} custom",
        style: ShadTheme.of(context).textTheme.small.copyWith(
              color: Settings.tacticalVioletTheme.mutedForeground,
            ),
      ),
      child: const _ThemeProfilesList(),
    );
  }
}

class _ThemeProfilesList extends ConsumerWidget {
  const _ThemeProfilesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profilesState = ref.watch(mapThemeProfilesProvider);
    final strategyTheme = ref.watch(strategyThemeProvider);
    final hasActiveStrategy = ref.watch(strategyProvider).stratName != null;

    final overridePalette =
        hasActiveStrategy ? strategyTheme.overridePalette : null;
    final activeProfileId = !hasActiveStrategy || overridePalette != null
        ? null
        : (strategyTheme.profileId ??
            MapThemeProfilesProvider.immutableDefaultProfileId);
    final customCount =
        profilesState.profiles.where((p) => !p.isBuiltIn).length;
    final canCreate =
        customCount < MapThemeProfilesProvider.customProfilesSoftCap;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (overridePalette != null) ...[
          _ProfileListRow(
            title: "Custom",
            tags: const ["This strategy only"],
            palette: overridePalette,
            isSelected: true,
            onTap: () {},
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: canCreate
                      ? () => showMapThemeEditorDialog(
                            context,
                            mode: MapThemeEditorMode.createProfile,
                            initialPalette: overridePalette,
                          )
                      : null,
                  child: const Text("Save as profile"),
                ),
                const SizedBox(width: 4),
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: () => showMapThemeEditorDialog(
                    context,
                    mode: MapThemeEditorMode.customizeStrategy,
                    initialPalette: overridePalette,
                  ),
                  child: const Text("Edit"),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
        ],
        for (final profile in profilesState.profiles) ...[
          _ProfileListRow(
            title: profile.name,
            tags: [
              if (profile.id == profilesState.defaultProfileIdForNewStrategies)
                "Default",
              if (profile.isBuiltIn) "Built-in",
            ],
            palette: profile.palette,
            isSelected: activeProfileId == profile.id,
            onTap: hasActiveStrategy
                ? () => _selectProfile(
                      context,
                      ref,
                      profile: profile,
                      hasOverride: overridePalette != null,
                    )
                : null,
            trailing: _profileRowTrailing(
              context,
              ref,
              profile: profile,
              isActive: activeProfileId == profile.id,
              isDefault:
                  profile.id == profilesState.defaultProfileIdForNewStrategies,
            ),
          ),
          const SizedBox(height: 2),
        ],
        _NewProfileRow(
          enabled: canCreate,
          onTap: () => showMapThemeEditorDialog(
            context,
            mode: MapThemeEditorMode.createProfile,
            initialPalette: ref.read(effectiveMapThemePaletteProvider),
          ),
        ),
      ],
    );
  }

  Future<void> _selectProfile(
    BuildContext context,
    WidgetRef ref, {
    required MapThemeProfile profile,
    required bool hasOverride,
  }) async {
    if (hasOverride) {
      final confirmed = await ConfirmAlertDialog.show(
        context: context,
        title: "Discard custom colors?",
        content:
            "This strategy's custom colors will be replaced with \"${profile.name}\" and can't be brought back.",
        confirmText: "Discard",
        isDestructive: true,
      );
      if (!confirmed || !context.mounted) return;
    }
    ref
        .read(strategyProvider.notifier)
        .setThemeProfileForCurrentStrategy(profile.id);
  }

  Widget? _profileRowTrailing(
    BuildContext context,
    WidgetRef ref, {
    required MapThemeProfile profile,
    required bool isActive,
    required bool isDefault,
  }) {
    final children = <Widget>[
      if (isActive)
        ShadButton.ghost(
          size: ShadButtonSize.sm,
          onPressed: () => showMapThemeEditorDialog(
            context,
            mode: MapThemeEditorMode.customizeStrategy,
            initialPalette: ref.read(effectiveMapThemePaletteProvider),
          ),
          child: const Text("Customize"),
        ),
      if (!(profile.isBuiltIn && isDefault))
        _ProfileContextMenuButton(profile: profile, isDefault: isDefault),
    ];
    if (children.isEmpty) return null;
    if (children.length == 1) return children.single;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        children.first,
        const SizedBox(width: 4),
        ...children.skip(1),
      ],
    );
  }
}

class _NewProfileRow extends StatelessWidget {
  const _NewProfileRow({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: enabled ? onTap : null,
        mouseCursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        borderRadius: BorderRadius.circular(8),
        hoverColor: theme.secondary.withValues(alpha: 0.45),
        splashFactory: NoSplash.splashFactory,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Icon(
                    LucideIcons.plus,
                    size: 15,
                    color: theme.mutedForeground,
                  ),
                ),
                Text(
                  "New profile",
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: theme.mutedForeground,
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

class _ProfileContextMenuButton extends ConsumerStatefulWidget {
  const _ProfileContextMenuButton({
    required this.profile,
    required this.isDefault,
  });

  final MapThemeProfile profile;
  final bool isDefault;

  @override
  ConsumerState<_ProfileContextMenuButton> createState() =>
      _ProfileContextMenuButtonState();
}

class _ProfileContextMenuButtonState
    extends ConsumerState<_ProfileContextMenuButton> {
  final ShadContextMenuController _contextMenuController =
      ShadContextMenuController();

  @override
  void dispose() {
    _contextMenuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadContextMenuRegion(
      controller: _contextMenuController,
      items: _buildMenuItems(),
      child: ShadIconButton.secondary(
        width: 26,
        height: 26,
        icon: Icon(
          LucideIcons.ellipsisVertical,
          size: 18,
          color: Settings.tacticalVioletTheme.mutedForeground,
        ),
        onPressed: () {
          _contextMenuController.toggle();
        },
      ),
    );
  }

  List<ShadContextMenuItem> _buildMenuItems() {
    return [
      if (!widget.isDefault)
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.star, size: 16),
          onPressed: _setAsDefault,
          child: const Text("Set as Default"),
        ),
      if (!widget.profile.isBuiltIn)
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.pencil, size: 16),
          onPressed: _renameProfile,
          child: const Text("Rename"),
        ),
      if (!widget.profile.isBuiltIn)
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.palette, size: 16),
          onPressed: _editProfilePalette,
          child: const Text("Edit colors"),
        ),
      if (!widget.profile.isBuiltIn)
        ShadContextMenuItem(
          leading: Icon(
            LucideIcons.trash2,
            size: 16,
            color: Settings.tacticalVioletTheme.destructive,
          ),
          onPressed: _deleteProfile,
          child: Text(
            "Delete",
            style: TextStyle(color: Settings.tacticalVioletTheme.destructive),
          ),
        ),
    ];
  }

  Future<void> _renameProfile() async {
    final newName = await _showRenameDialog(
      context: context,
      currentName: widget.profile.name,
    );
    if (newName == null || newName.isEmpty) return;

    await ref
        .read(mapThemeProfilesProvider.notifier)
        .renameProfile(profileId: widget.profile.id, newName: newName);
  }

  Future<void> _editProfilePalette() async {
    await showMapThemeEditorDialog(
      context,
      mode: MapThemeEditorMode.editProfile,
      profile: widget.profile,
      initialPalette: widget.profile.palette,
    );
  }

  Future<void> _setAsDefault() async {
    await ref
        .read(mapThemeProfilesProvider.notifier)
        .setDefaultProfileForNewStrategies(widget.profile.id);
    if (!mounted) return;

    Settings.showToast(
      message: "Default profile updated.",
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }

  Future<void> _deleteProfile() async {
    await ref.read(mapThemeProfilesProvider.notifier).deleteProfile(
          widget.profile.id,
        );
    if (!mounted) return;

    Settings.showToast(
      message: "Profile deleted.",
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }
}

// ─── Profile List Row ─────────────────────────────────────────

class _ProfileListRow extends StatelessWidget {
  const _ProfileListRow({
    required this.title,
    required this.palette,
    required this.isSelected,
    required this.onTap,
    this.tags = const [],
    this.trailing,
  });

  final String title;
  final MapThemePalette palette;
  final bool isSelected;
  final List<String> tags;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        mouseCursor:
            onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(8),
        hoverColor: theme.secondary.withValues(alpha: 0.45),
        highlightColor: theme.secondary.withValues(alpha: 0.6),
        splashFactory: NoSplash.splashFactory,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: isSelected
                ? theme.secondary.withValues(alpha: 0.9)
                : Colors.transparent,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                if (onTap != null)
                  SizedBox(
                    width: 22,
                    child: isSelected
                        ? Icon(
                            LucideIcons.check,
                            size: 15,
                            color: theme.primary,
                          )
                        : null,
                  ),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (tags.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          tags.join(' · '),
                          style: ShadTheme.of(context).textTheme.small.copyWith(
                                color: theme.mutedForeground,
                                fontSize: 12,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _PaletteSwatches(palette: palette),
                if (trailing != null) ...[
                  const SizedBox(width: 4),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Palette Widgets ──────────────────────────────────────────

class _PaletteSwatches extends StatelessWidget {
  const _PaletteSwatches({required this.palette});

  final MapThemePalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Swatch(color: palette.baseColor),
        const SizedBox(width: 4),
        _Swatch(color: palette.detailColor),
        const SizedBox(width: 4),
        _Swatch(color: palette.highlightColor),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
    );
  }
}

// ─── Dialogs ──────────────────────────────────────────────────

Future<String?> _showRenameDialog({
  required BuildContext context,
  required String currentName,
}) async {
  final controller = TextEditingController(text: currentName);
  return showShadDialog<String>(
    context: context,
    builder: (dialogContext) {
      return ShadDialog(
        title: const Text("Rename Profile"),
        actions: [
          ShadButton.secondary(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("Cancel"),
          ),
          ShadButton(
            onPressed: () {
              final trimmed = controller.text.trim();
              Navigator.of(dialogContext).pop(trimmed.isEmpty ? null : trimmed);
            },
            child: const Text("Rename"),
          ),
        ],
        child: Material(
          color: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Consumer(
              builder: (context, ref, _) {
                return CustomTextField(
                  controller: controller,
                  hintText: "Profile name",
                );
              },
            ),
          ),
        ),
      );
    },
  );
}
