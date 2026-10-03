import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/map_theme_profile_code.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/map_theme_editor_dialog.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/map_svg_color_mapper.dart';
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
    final hasActiveStrategy = ref.watch(strategyProvider).strategyName != null;

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
            onTap: null,
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
        _AddProfileRow(
          icon: LucideIcons.plus,
          label: "New profile",
          enabled: canCreate,
          onTap: () => showMapThemeEditorDialog(
            context,
            mode: MapThemeEditorMode.createProfile,
            initialPalette: ref.read(effectiveMapThemePaletteProvider),
          ),
        ),
        _AddProfileRow(
          icon: LucideIcons.clipboardPaste,
          label: "Import profile code",
          enabled: canCreate,
          onTap: () => _importProfileCode(context, ref),
        ),
      ],
    );
  }

  Future<void> _importProfileCode(BuildContext context, WidgetRef ref) async {
    final added = await _showImportProfileCodeDialog(context);
    if (added == null || !context.mounted) return;

    final hasActiveStrategy = ref.read(strategyProvider).strategyName != null;
    Settings.showToast(
      message: "${added.name} added",
      backgroundColor: Settings.tacticalVioletTheme.primary,
      actionLabel: hasActiveStrategy ? "Use it" : null,
      onActionPressed: hasActiveStrategy
          ? () {
              if (!context.mounted) return;
              _selectProfile(
                context,
                ref,
                profile: added,
                hasOverride:
                    ref.read(strategyThemeProvider).overridePalette != null,
              );
            }
          : null,
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

class _AddProfileRow extends StatelessWidget {
  const _AddProfileRow({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
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
                    icon,
                    size: 15,
                    color: theme.mutedForeground,
                  ),
                ),
                Text(
                  label,
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
          leading: const Icon(LucideIcons.copy, size: 16),
          onPressed: _copyProfileCode,
          child: const Text("Copy profile code"),
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

    final renamed = await ref
        .read(mapThemeProfilesProvider.notifier)
        .renameProfile(profileId: widget.profile.id, newName: newName);
    if (!renamed) {
      Settings.showToast(
        message: "Couldn't rename this profile.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  Future<void> _copyProfileCode() async {
    await Clipboard.setData(
      ClipboardData(
        text: MapThemeProfileCode.encode(
          name: widget.profile.name,
          palette: widget.profile.palette,
        ),
      ),
    );
    if (!mounted) return;

    Settings.showToast(
      message: "Profile code copied",
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
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
                if (onTap != null || isSelected)
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

/// Turns a shared profile code into a new custom profile. Returns the
/// profile it added, or null when nothing was added.
Future<MapThemeProfile?> _showImportProfileCodeDialog(
  BuildContext context,
) async {
  // A code already on the clipboard fills the field, so the usual import is
  // Import profile code, then Add profile.
  final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
  final clipboardCode = MapThemeProfileCode.find(clipboard?.text ?? '');
  if (!context.mounted) return null;

  return showShadDialog<MapThemeProfile>(
    context: context,
    builder: (_) => _ImportProfileCodeDialog(clipboardCode: clipboardCode),
  );
}

class _ImportProfileCodeDialog extends ConsumerStatefulWidget {
  const _ImportProfileCodeDialog({required this.clipboardCode});

  final String? clipboardCode;

  @override
  ConsumerState<_ImportProfileCodeDialog> createState() =>
      _ImportProfileCodeDialogState();
}

class _ImportProfileCodeDialogState
    extends ConsumerState<_ImportProfileCodeDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.clipboardCode ?? '');
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final result = MapThemeProfileCode.parse(_controller.text);
    final code = result is MapThemeProfileCodeValid ? result : null;
    final duplicate = code == null
        ? null
        : ref
            .watch(mapThemeProfilesProvider)
            .profiles
            .where((profile) => profile.palette == code.palette)
            .firstOrNull;

    final (String? message, bool isError) = switch (result) {
      MapThemeProfileCodeEmpty() => (null, false),
      MapThemeProfileCodeInvalid() => (
          "That isn't an Icarus profile code.",
          true,
        ),
      MapThemeProfileCodeIncomplete() => (
          "This code is incomplete. Copy the whole code and paste it again.",
          true,
        ),
      MapThemeProfileCodeNewerVersion() => (
          "This code is from a newer version of Icarus. Update Icarus to import it.",
          true,
        ),
      MapThemeProfileCodeValid() when duplicate != null => (
          "You already have these colors as “${duplicate.name}”.",
          false,
        ),
      MapThemeProfileCodeValid() => (
          _controller.text == widget.clipboardCode
              ? "Pasted from your clipboard."
              : null,
          false,
        ),
    };
    final canAdd = code != null && duplicate == null && !_adding;

    return ShadDialog(
      title: const Text("Import profile code"),
      description: const Text(
        "Paste a code someone shared to add their map colors to your profiles.",
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        ShadButton(
          enabled: canAdd,
          onPressed: canAdd ? () => _add(code) : null,
          child: const Text("Add profile"),
        ),
      ],
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              CustomTextField(
                controller: _controller,
                hintText: "Paste a profile code",
                hasError: isError,
                autofocus: widget.clipboardCode == null,
                onSubmitted: (_) {
                  if (canAdd) _add(code);
                },
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 16,
                child: message == null
                    ? null
                    : Text(
                        message,
                        style: ShadTheme.of(context).textTheme.small.copyWith(
                              fontSize: 12,
                              color: isError
                                  ? theme.destructive
                                  : theme.mutedForeground,
                            ),
                      ),
              ),
              const SizedBox(height: 8),
              _ProfileCodePreview(code: code),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _add(MapThemeProfileCodeValid code) async {
    setState(() => _adding = true);
    final created =
        await ref.read(mapThemeProfilesProvider.notifier).createProfile(
              name: code.name,
              palette: code.palette,
            );
    if (!mounted) return;
    if (created == null) {
      setState(() => _adding = false);
      Settings.showToast(
        message: "Couldn't add this profile.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }
    Navigator.of(context).pop(created);
  }
}

/// The open map drawn in the pasted colors, so the importer sees what they
/// are adding before they add it.
class _ProfileCodePreview extends ConsumerWidget {
  const _ProfileCodePreview({required this.code});

  final MapThemeProfileCodeValid? code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = Settings.tacticalVioletTheme;
    final mapState = ref.watch(mapProvider);
    final mapAsset =
        'assets/maps/${Maps.mapNames[mapState.currentMap]}_map${mapState.isAttack ? "" : "_defense"}.svg';
    final code = this.code;

    return Container(
      height: 250,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.border),
        gradient: RadialGradient(
          radius: 1.5,
          colors: [theme.card, theme.background],
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                const Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: DotGrid(),
                  ),
                ),
                if (code == null)
                  Center(
                    child: Text(
                      "The colors show here once you paste a code.",
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color: theme.mutedForeground,
                          ),
                    ),
                  )
                else
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: CanonicalMapArtwork(
                        map: mapState.currentMap,
                        isAttack: mapState.isAttack,
                        child: SvgPicture.asset(
                          mapAsset,
                          colorMapper:
                              MapSvgColorMapper.forPalette(code.palette),
                          fit: BoxFit.contain,
                          semanticsLabel: 'Profile code preview',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (code != null)
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: theme.card.withValues(alpha: 0.92),
                border: Border(top: BorderSide(color: theme.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(code.name, overflow: TextOverflow.ellipsis),
                  ),
                  _PaletteSwatches(palette: code.palette),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
