import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class MapThemeSettingsSection extends StatelessWidget {
  const MapThemeSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Map Theme", style: ShadTheme.of(context).textTheme.lead),
        const SizedBox(height: 10),
        const _ActiveThemeCard(),
        const SizedBox(height: 16),
        const _ProfileLibrarySection(),
      ],
    );
  }
}

// ─── Zone 1: Active Theme (Document State) ────────────────────

class _ActiveThemeCard extends ConsumerStatefulWidget {
  const _ActiveThemeCard();

  @override
  ConsumerState<_ActiveThemeCard> createState() => _ActiveThemeCardState();
}

class _ActiveThemeCardState extends ConsumerState<_ActiveThemeCard> {
  String? _profileIdBeforeCustomize;
  bool _showSaveForm = false;
  late final TextEditingController _saveNameController;

  @override
  void initState() {
    super.initState();
    _saveNameController = TextEditingController();
  }

  @override
  void dispose() {
    _saveNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strategyTheme = ref.watch(strategyThemeProvider);
    final effectivePalette = ref.watch(effectiveMapThemePaletteProvider);
    final hasActiveStrategy = ref.watch(strategyProvider).stratName != null;
    final profilesState = ref.watch(mapThemeProfilesProvider);

    final isOverride = strategyTheme.overridePalette != null;

    final assignedProfileId = strategyTheme.profileId ??
        MapThemeProfilesProvider.immutableDefaultProfileId;
    final assignedProfile = profilesState.profiles.firstWhere(
      (p) => p.id == assignedProfileId,
      orElse: () => MapThemeProfilesProvider.immutableDefaultProfile,
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOverride
              ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.4)
              : Settings.tacticalVioletTheme.border,
        ),
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Active Theme",
              style: ShadTheme.of(context).textTheme.small.copyWith(
                    color: Settings.tacticalVioletTheme.mutedForeground,
                    letterSpacing: 0.3,
                  ),
            ),
            const SizedBox(height: 10),
            if (!hasActiveStrategy)
              Text(
                "Open a strategy to manage map themes.",
                style: ShadTheme.of(context).textTheme.small.copyWith(
                      color: Settings.tacticalVioletTheme.mutedForeground,
                    ),
              )
            else
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                layoutBuilder: (currentChild, previousChildren) {
                  return Stack(
                    alignment: Alignment.topCenter,
                    children: [
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  );
                },
                child: isOverride
                    ? _buildOverrideState(context, effectivePalette)
                    : _buildProfileAssignedState(context, assignedProfile),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileAssignedState(
      BuildContext context, MapThemeProfile profile) {
    return SizedBox(
      width: double.infinity,
      key: const ValueKey('profile-assigned'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(profile.name),
                    const SizedBox(height: 2),
                    Text(
                      profile.isBuiltIn
                          ? "Built-in profile"
                          : "Custom profile",
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color:
                                Settings.tacticalVioletTheme.mutedForeground,
                          ),
                    ),
                  ],
                ),
              ),
              _PaletteSwatches(palette: profile.palette),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: ShadButton.ghost(
              onPressed: () {
                _profileIdBeforeCustomize =
                    ref.read(strategyThemeProvider).profileId ??
                        MapThemeProfilesProvider.immutableDefaultProfileId;
                ref
                    .read(strategyProvider.notifier)
                    .setThemeOverrideForCurrentStrategy(
                        ref.read(effectiveMapThemePaletteProvider));
              },
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit_outlined, size: 14),
                  SizedBox(width: 6),
                  Text("Customize"),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverrideState(BuildContext context, MapThemePalette palette) {
    return SizedBox(
      width: double.infinity,
      key: const ValueKey('override-active'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Settings.tacticalVioletTheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              "CUSTOM OVERRIDE",
              style: ShadTheme.of(context).textTheme.small.copyWith(
                    color: Settings.tacticalVioletTheme.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
            ),
          ),
          const SizedBox(height: 10),
          _PaletteEditor(
            label: "",
            palette: palette,
            onChanged: (nextPalette) {
              ref
                  .read(strategyProvider.notifier)
                  .setThemeOverrideForCurrentStrategy(nextPalette);
            },
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ShadButton.ghost(
                onPressed: () {
                  final restoreId = _profileIdBeforeCustomize ??
                      MapThemeProfilesProvider.immutableDefaultProfileId;
                  ref
                      .read(strategyProvider.notifier)
                      .setThemeProfileForCurrentStrategy(restoreId);
                  setState(() {
                    _profileIdBeforeCustomize = null;
                    _showSaveForm = false;
                  });
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.undo_outlined, size: 14),
                    SizedBox(width: 6),
                    Text("Reset"),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              ShadButton.outline(
                onPressed: () {
                  setState(() {
                    _showSaveForm = !_showSaveForm;
                    if (_showSaveForm) {
                      final profiles = ref.read(mapThemeProfilesProvider);
                      _saveNameController.text =
                          "Profile ${MapThemeProfilesProvider.nextGeneratedProfileNumber(
                        profiles.profiles
                            .where((p) => !p.isBuiltIn)
                            .toList(),
                      )}";
                    }
                  });
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _showSaveForm ? Icons.close : Icons.save_outlined,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(_showSaveForm ? "Cancel" : "Save as Profile"),
                  ],
                ),
              ),
            ],
          ),
          if (_showSaveForm) ...[
            const SizedBox(height: 10),
            _buildSaveForm(context, palette),
          ],
        ],
      ),
    );
  }

  Widget _buildSaveForm(BuildContext context, MapThemePalette palette) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Profile Name",
            style: ShadTheme.of(context).textTheme.small.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground,
                ),
          ),
          const SizedBox(height: 6),
          ShadInput(
            controller: _saveNameController,
            placeholder: const Text("Enter a name"),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ShadButton(
              onPressed: () async {
                final trimmedName = _saveNameController.text.trim();
                final didCreate = await ref
                    .read(mapThemeProfilesProvider.notifier)
                    .createProfile(name: trimmedName, palette: palette);
                if (!didCreate) {
                  Settings.showToast(
                    message: "Profile limit reached or invalid name.",
                    backgroundColor: Settings.tacticalVioletTheme.destructive,
                  );
                  return;
                }
                if (!mounted) return;
                Settings.showToast(
                  message: "Profile saved.",
                  backgroundColor: Settings.tacticalVioletTheme.primary,
                );
                setState(() {
                  _showSaveForm = false;
                });
              },
              child: const Text("Save"),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Zone 2: Profile Library (Global Preferences) ─────────────

class _ProfileLibrarySection extends ConsumerStatefulWidget {
  const _ProfileLibrarySection();

  @override
  ConsumerState<_ProfileLibrarySection> createState() =>
      _ProfileLibrarySectionState();
}

class _ProfileLibrarySectionState extends ConsumerState<_ProfileLibrarySection> {
  @override
  Widget build(BuildContext context) {
    final profilesState = ref.watch(mapThemeProfilesProvider);
    final strategyTheme = ref.watch(strategyThemeProvider);
    final hasActiveStrategy = ref.watch(strategyProvider).stratName != null;

    final activeProfileId = strategyTheme.overridePalette == null
        ? (strategyTheme.profileId ??
            MapThemeProfilesProvider.immutableDefaultProfileId)
        : null;

    final customCount =
        profilesState.profiles.where((p) => !p.isBuiltIn).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "Profile Library",
              style: ShadTheme.of(context).textTheme.small.copyWith(
                    color: Settings.tacticalVioletTheme.mutedForeground,
                    letterSpacing: 0.3,
                  ),
            ),
            Text(
              "$customCount/${MapThemeProfilesProvider.customProfilesSoftCap} custom",
              style: ShadTheme.of(context).textTheme.small.copyWith(
                    color: Settings.tacticalVioletTheme.mutedForeground,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final profile in profilesState.profiles) ...[
          _ProfileListRow(
            title: profile.name,
            palette: profile.palette,
            isSelected: activeProfileId == profile.id,
            isDefault:
                profile.id == profilesState.defaultProfileIdForNewStrategies,
            onTap: hasActiveStrategy
                ? () {
                    ref
                        .read(strategyProvider.notifier)
                        .setThemeProfileForCurrentStrategy(profile.id);
                  }
                : null,
            trailing: profile.isBuiltIn
                ? null
                : _buildProfilePopupMenu(
                    context,
                    profile,
                    profile.id ==
                        profilesState.defaultProfileIdForNewStrategies,
                  ),
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _buildProfilePopupMenu(
    BuildContext context,
    MapThemeProfile profile,
    bool isDefault,
  ) {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_vert,
        size: 18,
        color: Settings.tacticalVioletTheme.mutedForeground,
      ),
      padding: EdgeInsets.zero,
      onSelected: (value) async {
        switch (value) {
          case 'rename':
            final newName = await _showRenameDialog(
              context: context,
              currentName: profile.name,
            );
            if (newName != null && newName.isNotEmpty) {
              await ref
                  .read(mapThemeProfilesProvider.notifier)
                  .renameProfile(profileId: profile.id, newName: newName);
            }
          case 'set_default':
            await ref
                .read(mapThemeProfilesProvider.notifier)
                .setDefaultProfileForNewStrategies(profile.id);
            if (!mounted) return;
            Settings.showToast(
              message: "Default profile updated.",
              backgroundColor: Settings.tacticalVioletTheme.primary,
            );
          case 'delete':
            await ref
                .read(mapThemeProfilesProvider.notifier)
                .deleteProfile(profile.id);
            if (!mounted) return;
            Settings.showToast(
              message: "Profile deleted.",
              backgroundColor: Settings.tacticalVioletTheme.primary,
            );
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 16),
              SizedBox(width: 8),
              Text("Rename"),
            ],
          ),
        ),
        if (!isDefault)
          const PopupMenuItem(
            value: 'set_default',
            child: Row(
              children: [
                Icon(Icons.star_outline, size: 16),
                SizedBox(width: 8),
                Text("Set as Default"),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline,
                  size: 16,
                  color: Settings.tacticalVioletTheme.destructive),
              const SizedBox(width: 8),
              Text("Delete",
                  style: TextStyle(
                      color: Settings.tacticalVioletTheme.destructive)),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Profile List Row ─────────────────────────────────────────

class _ProfileListRow extends StatelessWidget {
  const _ProfileListRow({
    required this.title,
    required this.palette,
    required this.isSelected,
    required this.isDefault,
    required this.onTap,
    this.trailing,
  });

  final String title;
  final MapThemePalette palette;
  final bool isSelected;
  final bool isDefault;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? Settings.tacticalVioletTheme.primary
                : Settings.tacticalVioletTheme.border,
            width: isSelected ? 1.5 : 1,
          ),
          color: isSelected
              ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.05)
              : Settings.tacticalVioletTheme.background,
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isDefault) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Settings.tacticalVioletTheme.primary
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        "DEFAULT",
                        style: ShadTheme.of(context).textTheme.small.copyWith(
                              color: Settings.tacticalVioletTheme.primary,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
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
    );
  }
}

// ─── Palette Widgets ──────────────────────────────────────────

class _PaletteEditor extends StatelessWidget {
  const _PaletteEditor({
    required this.label,
    required this.palette,
    required this.onChanged,
  });

  final String label;
  final MapThemePalette palette;
  final ValueChanged<MapThemePalette> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label),
            ],
          ),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            _EditableSwatch(
              label: "Base",
              color: palette.baseColor,
              onPick: (color) {
                onChanged(palette.copyWith(baseColorValue: color.toARGB32()));
              },
            ),
            const SizedBox(width: 8),
            _EditableSwatch(
              label: "Detail",
              color: palette.detailColor,
              onPick: (color) {
                onChanged(palette.copyWith(detailColorValue: color.toARGB32()));
              },
            ),
            const SizedBox(width: 8),
            _EditableSwatch(
              label: "Highlight",
              color: palette.highlightColor,
              onPick: (color) {
                onChanged(
                    palette.copyWith(highlightColorValue: color.toARGB32()));
              },
            ),
          ],
        ),
      ],
    );
  }
}

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

class _EditableSwatch extends StatelessWidget {
  const _EditableSwatch({
    required this.label,
    required this.color,
    required this.onPick,
  });

  final String label;
  final Color color;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final picked = await _showColorPickerDialog(
            context: context,
            initialColor: color,
            title: "Pick $label color",
          );
          if (picked != null) {
            onPick(picked);
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: ShadTheme.of(context).textTheme.small),
            const SizedBox(height: 4),
            Container(
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Settings.tacticalVioletTheme.border),
                color: color,
              ),
            ),
          ],
        ),
      ),
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

Future<Color?> _showColorPickerDialog({
  required BuildContext context,
  required Color initialColor,
  required String title,
}) async {
  var workingColor = initialColor;
  return showShadDialog<Color>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ShadDialog(
            title: Text(title),
            actions: [
              ShadButton.secondary(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text("Cancel"),
              ),
              ShadButton(
                onPressed: () => Navigator.of(context).pop(workingColor),
                child: const Text("Apply"),
              ),
            ],
            child: Material(
              color: Colors.transparent,
              child: SizedBox(
                width: 320,
                child: ColorPicker(
                  portraitOnly: true,
                  pickerColor: workingColor,
                  onColorChanged: (color) {
                    setState(() {
                      workingColor = color;
                    });
                  },
                  pickerAreaHeightPercent: 0.8,
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

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
          child: ShadInput(
            controller: controller,
            placeholder: const Text("Profile name"),
          ),
        ),
      );
    },
  );
}
