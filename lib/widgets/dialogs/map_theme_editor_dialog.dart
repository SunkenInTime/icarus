import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/better_color_picker.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/icarus_color_picker_style.dart';
import 'package:icarus/widgets/map_svg_color_mapper.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum MapThemeEditorMode {
  /// Design a new profile from scratch.
  createProfile,

  /// Change an existing profile everywhere it is used.
  editProfile,

  /// One-off palette for the open strategy only.
  customizeStrategy,
}

Future<void> showMapThemeEditorDialog(
  BuildContext context, {
  required MapThemeEditorMode mode,
  required MapThemePalette initialPalette,
  MapThemeProfile? profile,
}) {
  return showShadDialog<void>(
    context: context,
    builder: (context) => MapThemeEditorDialog(
      mode: mode,
      initialPalette: initialPalette,
      profile: profile,
    ),
  );
}

class MapThemeEditorDialog extends ConsumerStatefulWidget {
  const MapThemeEditorDialog({
    super.key,
    required this.mode,
    required this.initialPalette,
    this.profile,
  }) : assert(
          mode != MapThemeEditorMode.editProfile || profile != null,
          'editProfile requires the profile being edited',
        );

  final MapThemeEditorMode mode;
  final MapThemePalette initialPalette;
  final MapThemeProfile? profile;

  @override
  ConsumerState<MapThemeEditorDialog> createState() =>
      _MapThemeEditorDialogState();
}

enum _PaletteSlot { base, detail, highlight }

class _MapThemeEditorDialogState extends ConsumerState<MapThemeEditorDialog> {
  late MapThemePalette _palette = widget.initialPalette;
  late final TextEditingController _nameController = TextEditingController();
  _PaletteSlot _selectedSlot = _PaletteSlot.base;

  @override
  void initState() {
    super.initState();
    switch (widget.mode) {
      case MapThemeEditorMode.createProfile:
        final profiles = ref.read(mapThemeProfilesProvider).profiles;
        _nameController.text =
            "Profile ${MapThemeProfilesProvider.nextGeneratedProfileNumber(
          profiles.where((p) => !p.isBuiltIn).toList(),
        )}";
      case MapThemeEditorMode.editProfile:
        _nameController.text = widget.profile!.name;
      case MapThemeEditorMode.customizeStrategy:
        break;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(screenSize.width - 96, 1120.0);
    final dialogHeight = math.min(screenSize.height - 80, 780.0);

    final mapState = ref.watch(mapProvider);
    final mapAsset =
        'assets/maps/${Maps.mapNames[mapState.currentMap]}_map${mapState.isAttack ? "" : "_defense"}.svg';

    return ShadDialog(
      constraints: BoxConstraints(
        maxWidth: dialogWidth,
        maxHeight: dialogHeight,
      ),
      padding: EdgeInsets.zero,
      scrollable: false,
      closeIconPosition: const ShadPosition(top: 14, right: 14),
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildPreview(mapAsset)),
              Container(
                width: 1,
                color:
                    Settings.tacticalVioletTheme.border.withValues(alpha: 0.9),
              ),
              SizedBox(width: 340, child: _buildControls(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(String mapAsset) {
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.5,
          colors: [
            Settings.tacticalVioletTheme.card,
            Settings.tacticalVioletTheme.background,
          ],
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(4),
              child: DotGrid(),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SvgPicture.asset(
                mapAsset,
                colorMapper: MapSvgColorMapper.forPalette(_palette),
                fit: BoxFit.contain,
                semanticsLabel: 'Map theme preview',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final title = switch (widget.mode) {
      MapThemeEditorMode.createProfile => "New profile",
      MapThemeEditorMode.editProfile => "Edit profile",
      MapThemeEditorMode.customizeStrategy => "Customize map theme",
    };
    final showNameField = widget.mode != MapThemeEditorMode.customizeStrategy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 28),
            child: Text(
              title,
              style: ShadTheme.of(context).textTheme.p.copyWith(
                    color: Settings.tacticalVioletTheme.foreground,
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
          if (widget.mode == MapThemeEditorMode.customizeStrategy) ...[
            const SizedBox(height: 4),
            Text(
              "Only this strategy is affected.",
              style: ShadTheme.of(context).textTheme.small.copyWith(
                    color: Settings.tacticalVioletTheme.mutedForeground,
                  ),
            ),
          ],
          const SizedBox(height: 14),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showNameField) ...[
                    CustomTextField(
                      controller: _nameController,
                      hintText: "Profile name",
                    ),
                    const SizedBox(height: 14),
                  ],
                  _buildSlotTabs(context),
                  const SizedBox(height: 12),
                  BetterColorPicker(
                    key: ValueKey(_selectedSlot),
                    value: _selectedSlotColor,
                    initialMode: BetterColorPickerMode.hsv,
                    style: icarusColorPickerStyle,
                    onChanging: (next) => _updateSlot(_selectedSlot, next),
                    onChanged: (next) => _updateSlot(_selectedSlot, next),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildFooter(context),
        ],
      ),
    );
  }

  Widget _buildSlotTabs(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: theme.secondary.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSlotTab(context, _PaletteSlot.base, "Base"),
            const SizedBox(width: 2),
            _buildSlotTab(context, _PaletteSlot.detail, "Detail"),
            const SizedBox(width: 2),
            _buildSlotTab(context, _PaletteSlot.highlight, "Highlight"),
          ],
        ),
      ),
    );
  }

  Widget _buildSlotTab(BuildContext context, _PaletteSlot slot, String label) {
    final isSelected = _selectedSlot == slot;
    const theme = Settings.tacticalVioletTheme;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => setState(() => _selectedSlot = slot),
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(6),
        hoverColor: theme.secondary.withValues(alpha: 0.45),
        splashFactory: NoSplash.splashFactory,
        child: Ink(
          decoration: BoxDecoration(
            color: isSelected
                ? theme.secondary.withValues(alpha: 0.95)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: _slotColor(slot),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: theme.border),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: isSelected
                            ? theme.foreground
                            : theme.mutedForeground,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color get _selectedSlotColor => _slotColor(_selectedSlot);

  Color _slotColor(_PaletteSlot slot) {
    return switch (slot) {
      _PaletteSlot.base => _palette.baseColor,
      _PaletteSlot.detail => _palette.detailColor,
      _PaletteSlot.highlight => _palette.highlightColor,
    };
  }

  void _updateSlot(_PaletteSlot slot, Color color) {
    setState(() {
      _palette = switch (slot) {
        _PaletteSlot.base =>
          _palette.copyWith(baseColorValue: color.toARGB32()),
        _PaletteSlot.detail =>
          _palette.copyWith(detailColorValue: color.toARGB32()),
        _PaletteSlot.highlight =>
          _palette.copyWith(highlightColorValue: color.toARGB32()),
      };
    });
  }

  Widget _buildFooter(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ShadButton.ghost(
            size: ShadButtonSize.sm,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Cancel"),
          ),
          const SizedBox(width: 6),
          switch (widget.mode) {
            MapThemeEditorMode.createProfile => ShadButton(
                size: ShadButtonSize.sm,
                onPressed: _saveNewProfile,
                child: const Text("Save profile"),
              ),
            MapThemeEditorMode.editProfile => ShadButton(
                size: ShadButtonSize.sm,
                onPressed: _saveProfileEdits,
                child: const Text("Save changes"),
              ),
            MapThemeEditorMode.customizeStrategy => ShadButton(
                size: ShadButtonSize.sm,
                onPressed: _applyToStrategy,
                child: const Text("Apply"),
              ),
          },
        ],
      ),
    );
  }

  Future<void> _saveNewProfile() async {
    final created = await ref
        .read(mapThemeProfilesProvider.notifier)
        .createProfile(name: _nameController.text.trim(), palette: _palette);
    if (created == null) {
      Settings.showToast(
        message: "Profile limit reached or invalid name.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }
    final hasActiveStrategy = ref.read(strategyProvider).stratName != null;
    if (hasActiveStrategy) {
      ref
          .read(strategyProvider.notifier)
          .setThemeProfileForCurrentStrategy(created.id);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    Settings.showToast(
      message:
          hasActiveStrategy ? "Profile saved and applied." : "Profile saved.",
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }

  Future<void> _saveProfileEdits() async {
    final profile = widget.profile!;
    final notifier = ref.read(mapThemeProfilesProvider.notifier);
    await notifier.updateProfilePalette(
      profileId: profile.id,
      palette: _palette,
    );
    final trimmedName = _nameController.text.trim();
    if (trimmedName.isNotEmpty && trimmedName != profile.name) {
      await notifier.renameProfile(
        profileId: profile.id,
        newName: trimmedName,
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    Settings.showToast(
      message: "Profile updated.",
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }

  void _applyToStrategy() {
    ref
        .read(strategyProvider.notifier)
        .setThemeOverrideForCurrentStrategy(_palette);
    Navigator.of(context).pop();
  }
}
