import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/ui_theme_provider.dart';
import 'package:icarus/theme/theme_color_format.dart';
import 'package:icarus/theme/ui_theme_models.dart';
import 'package:icarus/theme/ui_theme_tokens.dart';
import 'package:icarus/widgets/map_theme_settings_section.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ThemeStudioSection extends ConsumerStatefulWidget {
  const ThemeStudioSection({super.key});

  @override
  ConsumerState<ThemeStudioSection> createState() => _ThemeStudioSectionState();
}

class _ThemeStudioSectionState extends ConsumerState<ThemeStudioSection> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final uiThemeState = ref.watch(uiThemeProvider);
    final effectiveTheme = ref.watch(effectiveUiThemeProvider);

    final categories = <String>{
      ...UiThemeTokenRegistry.colorTokens.map((token) => token.category),
      ...UiThemeTokenRegistry.shadowTokens.map((token) => token.category),
    }.toList()
      ..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Theme Studio', style: ShadTheme.of(context).textTheme.h4),
            Row(
              children: [
                ShadButton.secondary(
                  leading: const Icon(LucideIcons.map, size: 16),
                  onPressed: _openTokenMapPage,
                  child: const Text('Token Map'),
                ),
                const SizedBox(width: 8),
                ShadButton.secondary(
                  leading: const Icon(LucideIcons.copy),
                  onPressed: _copyThemeToClipboard,
                  child: const Text('Copy Theme JSON'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Edit runtime color and shadow tokens with live app updates.',
          style: ShadTheme.of(context).textTheme.small.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground,
              ),
        ),
        const SizedBox(height: 12),
        _buildProfileBar(uiThemeState),
        const SizedBox(height: 10),
        ShadInput(
          placeholder: const Text('Search tokens, labels, usage...'),
          leading: const Padding(
            padding: EdgeInsets.only(left: 10),
            child: Icon(LucideIcons.search, size: 16),
          ),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 12),
        for (final category in categories) ...[
          _TokenCategoryCard(
            category: category,
            query: _query,
            effectiveTheme: effectiveTheme,
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: Settings.tacticalVioletTheme.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Settings.tacticalVioletTheme.border),
            boxShadow: Settings.cardForegroundBackdropShadows,
          ),
          padding: const EdgeInsets.all(10),
          child: const MapThemeSettingsSection(),
        ),
      ],
    );
  }

  Widget _buildProfileBar(UiThemeState state) {
    return Container(
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: state.activeProfileId,
                dropdownColor: Settings.tacticalVioletTheme.card,
                items: [
                  for (final profile in state.profiles)
                    DropdownMenuItem(
                      value: profile.id,
                      child: Text(profile.name),
                    )
                ],
                onChanged: (value) {
                  if (value == null) return;
                  ref.read(uiThemeProvider.notifier).setActiveProfile(value);
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          ShadButton.secondary(
            leading: const Icon(LucideIcons.plus, size: 14),
            onPressed: _showCreateProfileDialog,
            child: const Text('New'),
          ),
          const SizedBox(width: 6),
          ShadButton.secondary(
            leading: const Icon(LucideIcons.pencil, size: 14),
            onPressed: _showRenameProfileDialog,
            child: const Text('Rename'),
          ),
          const SizedBox(width: 6),
          ShadButton.destructive(
            leading: const Icon(LucideIcons.trash2, size: 14),
            onPressed:
                state.activeProfile.isBuiltIn ? null : _deleteActiveProfile,
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateProfileDialog() async {
    final controller = TextEditingController();
    final result = await showShadDialog<String>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('Create Theme Profile'),
        description:
            const Text('Creates a profile from the currently active theme.'),
        actions: [
          ShadButton.secondary(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
        child: Material(
          color: Colors.transparent,
          child: ShadInput(
            controller: controller,
            placeholder: const Text('Profile name'),
          ),
        ),
      ),
    );

    if (result == null || result.isEmpty) return;

    await ref
        .read(uiThemeProvider.notifier)
        .createProfileFromActive(name: result);
    if (!mounted) return;
    Settings.showToast(
      message: 'Theme profile created.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }

  Future<void> _showRenameProfileDialog() async {
    final current = ref.read(uiThemeProvider).activeProfile;
    if (current.isBuiltIn) {
      Settings.showToast(
        message: 'Built-in profile cannot be renamed.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    final controller = TextEditingController(text: current.name);
    final result = await showShadDialog<String>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('Rename Theme Profile'),
        actions: [
          ShadButton.secondary(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
        child: Material(
          color: Colors.transparent,
          child: ShadInput(
            controller: controller,
            placeholder: const Text('Profile name'),
          ),
        ),
      ),
    );

    if (result == null || result.isEmpty) return;

    await ref.read(uiThemeProvider.notifier).renameProfile(
          profileId: current.id,
          newName: result,
        );
  }

  Future<void> _deleteActiveProfile() async {
    final active = ref.read(uiThemeProvider).activeProfile;
    if (active.isBuiltIn) return;

    await ref.read(uiThemeProvider.notifier).deleteProfile(active.id);
    if (!mounted) return;

    Settings.showToast(
      message: 'Theme profile deleted.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }

  Future<void> _copyThemeToClipboard() async {
    final mapPalette = ref.read(effectiveMapThemePaletteProvider);
    final mapColors = {
      'base': ThemeColorFormat.toHex(mapPalette.baseColor),
      'detail': ThemeColorFormat.toHex(mapPalette.detailColor),
      'highlight': ThemeColorFormat.toHex(mapPalette.highlightColor),
    };

    try {
      final json = ref.read(uiThemeProvider.notifier).exportActiveThemeJson(
            mapColors: mapColors,
          );

      await Clipboard.setData(ClipboardData(text: json));

      if (!mounted) return;
      Settings.showToast(
        message: 'Theme JSON copied to clipboard.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    } catch (_) {
      if (!mounted) return;
      Settings.showToast(
        message: 'Failed to copy theme JSON.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  void _openTokenMapPage() {
    Navigator.of(context).pushNamed(Routes.themeTokenMap);
  }
}

class _TokenCategoryCard extends ConsumerWidget {
  const _TokenCategoryCard({
    required this.category,
    required this.query,
    required this.effectiveTheme,
  });

  final String category;
  final String query;
  final UiThemeResolvedData effectiveTheme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorTokens = UiThemeTokenRegistry.colorTokens.where((token) {
      if (token.category != category) return false;
      if (query.isEmpty) return true;
      final haystack = [
        token.id,
        token.label,
        token.usageDescription,
        ...token.affectedElements,
      ].join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();

    final shadowTokens = UiThemeTokenRegistry.shadowTokens.where((token) {
      if (token.category != category) return false;
      if (query.isEmpty) return true;
      final haystack = [
        token.id,
        token.label,
        token.usageDescription,
        ...token.affectedElements,
      ].join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();

    if (colorTokens.isEmpty && shadowTokens.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: ExpansionTile(
        title: Text(category),
        initiallyExpanded: query.isNotEmpty,
        childrenPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        children: [
          for (final token in colorTokens)
            _ColorTokenRow(
              token: token,
              color: effectiveTheme.color(token.id),
            ),
          for (final token in shadowTokens)
            _ShadowTokenRow(
              token: token,
              layers: effectiveTheme.shadowLayers(token.id),
            ),
        ],
      ),
    );
  }
}

class _ColorTokenRow extends ConsumerWidget {
  const _ColorTokenRow({required this.token, required this.color});

  final UiColorTokenDefinition token;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(token.label),
                const SizedBox(height: 2),
                Text(
                  token.id,
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: Settings.tacticalVioletTheme.mutedForeground,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  token.usageDescription,
                  style: ShadTheme.of(context).textTheme.small,
                ),
                const SizedBox(height: 2),
                Text(
                  'Affects: ${token.affectedElements.join(', ')}',
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: Settings.tacticalVioletTheme.mutedForeground,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _showColorEditor(context, ref),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: Settings.tacticalVioletTheme.border),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(ThemeColorFormat.toHex(color)),
              const SizedBox(height: 6),
              Row(
                children: [
                  ShadIconButton.secondary(
                    width: 28,
                    height: 28,
                    icon: const Icon(LucideIcons.pencil, size: 14),
                    onPressed: () => _showColorEditor(context, ref),
                  ),
                  const SizedBox(width: 4),
                  ShadIconButton.secondary(
                    width: 28,
                    height: 28,
                    icon: const Icon(LucideIcons.rotateCcw, size: 14),
                    onPressed: () {
                      ref
                          .read(uiThemeProvider.notifier)
                          .resetColorToken(token.id);
                    },
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showColorEditor(BuildContext context, WidgetRef ref) async {
    var working = color;
    final hexController =
        TextEditingController(text: ThemeColorFormat.toHex(color));
    final hslController =
        TextEditingController(text: ThemeColorFormat.toHsl(color));

    await showShadDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            void apply(Color next) {
              working = next;
              hexController.text = ThemeColorFormat.toHex(next);
              hslController.text = ThemeColorFormat.toHsl(next);
              ref.read(uiThemeProvider.notifier).updateColorToken(
                    tokenId: token.id,
                    colorValue: next.toARGB32(),
                  );
              setState(() {});
            }

            return ShadDialog(
              title: Text('Edit ${token.label}'),
              actions: [
                ShadButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
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
                      ColorPicker(
                        pickerColor: working,
                        onColorChanged: apply,
                        pickerAreaHeightPercent: 0.7,
                        enableAlpha: true,
                        displayThumbColor: true,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ShadInput(
                              controller: hexController,
                              placeholder: const Text('#RRGGBB or #AARRGGBB'),
                            ),
                          ),
                          const SizedBox(width: 6),
                          ShadButton.secondary(
                            onPressed: () {
                              final parsed =
                                  ThemeColorFormat.parseHex(hexController.text);
                              if (parsed == null) return;
                              apply(parsed);
                            },
                            child: const Text('Apply Hex'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ShadInput(
                              controller: hslController,
                              placeholder: const Text('hsl(...) / hsla(...)'),
                            ),
                          ),
                          const SizedBox(width: 6),
                          ShadButton.secondary(
                            onPressed: () {
                              final parsed =
                                  ThemeColorFormat.parseHsl(hslController.text);
                              if (parsed == null) return;
                              apply(parsed);
                            },
                            child: const Text('Apply HSL'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ShadowTokenRow extends ConsumerWidget {
  const _ShadowTokenRow({
    required this.token,
    required this.layers,
  });

  final UiShadowTokenDefinition token;
  final List<UiShadowLayerDefinition> layers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(token.label),
                const SizedBox(height: 2),
                Text(
                  token.id,
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: Settings.tacticalVioletTheme.mutedForeground,
                      ),
                ),
                const SizedBox(height: 4),
                Text(token.usageDescription,
                    style: ShadTheme.of(context).textTheme.small),
                const SizedBox(height: 2),
                Text(
                  'Affects: ${token.affectedElements.join(', ')}',
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: Settings.tacticalVioletTheme.mutedForeground,
                      ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 160,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Settings.tacticalVioletTheme.card,
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: Settings.tacticalVioletTheme.border),
                    boxShadow:
                        layers.map((layer) => layer.toBoxShadow()).toList(),
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              ShadIconButton.secondary(
                width: 28,
                height: 28,
                icon: const Icon(LucideIcons.pencil, size: 14),
                onPressed: () => _showShadowEditor(context, ref),
              ),
              const SizedBox(width: 4),
              ShadIconButton.secondary(
                width: 28,
                height: 28,
                icon: const Icon(LucideIcons.rotateCcw, size: 14),
                onPressed: () {
                  ref.read(uiThemeProvider.notifier).resetShadowToken(token.id);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showShadowEditor(BuildContext context, WidgetRef ref) async {
    List<UiShadowLayerDefinition> working =
        layers.map((layer) => layer.copyWith()).toList();

    await showShadDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            void commit() {
              ref.read(uiThemeProvider.notifier).updateShadowToken(
                    tokenId: token.id,
                    layers: working,
                  );
              setState(() {});
            }

            return ShadDialog(
              title: Text('Edit ${token.label}'),
              actions: [
                ShadButton.secondary(
                  onPressed: () {
                    working.add(
                      const UiShadowLayerDefinition(
                        colorValue: 0x66000000,
                        blurRadius: 4,
                        spreadRadius: 0,
                        offsetX: 0,
                        offsetY: 2,
                      ),
                    );
                    commit();
                  },
                  child: const Text('Add Layer'),
                ),
                ShadButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
              child: Material(
                color: Colors.transparent,
                child: SizedBox(
                  width: 560,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int index = 0; index < working.length; index++)
                        _ShadowLayerEditor(
                          index: index,
                          layer: working[index],
                          onChanged: (next) {
                            working[index] = next;
                            commit();
                          },
                          onMoveUp: index == 0
                              ? null
                              : () {
                                  final temp = working[index - 1];
                                  working[index - 1] = working[index];
                                  working[index] = temp;
                                  commit();
                                },
                          onMoveDown: index == working.length - 1
                              ? null
                              : () {
                                  final temp = working[index + 1];
                                  working[index + 1] = working[index];
                                  working[index] = temp;
                                  commit();
                                },
                          onDelete: working.length <= 1
                              ? null
                              : () {
                                  working.removeAt(index);
                                  commit();
                                },
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ShadowLayerEditor extends StatelessWidget {
  const _ShadowLayerEditor({
    required this.index,
    required this.layer,
    required this.onChanged,
    this.onMoveUp,
    this.onMoveDown,
    this.onDelete,
  });

  final int index;
  final UiShadowLayerDefinition layer;
  final ValueChanged<UiShadowLayerDefinition> onChanged;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final color = Color(layer.colorValue);
    final hexController =
        TextEditingController(text: ThemeColorFormat.toHex(color));

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text('Layer ${index + 1}'),
              const Spacer(),
              ShadIconButton.secondary(
                width: 24,
                height: 24,
                icon: const Icon(LucideIcons.arrowUp, size: 12),
                onPressed: onMoveUp,
              ),
              const SizedBox(width: 4),
              ShadIconButton.secondary(
                width: 24,
                height: 24,
                icon: const Icon(LucideIcons.arrowDown, size: 12),
                onPressed: onMoveDown,
              ),
              const SizedBox(width: 4),
              ShadIconButton.destructive(
                width: 24,
                height: 24,
                icon: const Icon(LucideIcons.trash2, size: 12),
                onPressed: onDelete,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              InkWell(
                onTap: () async {
                  Color selected = color;
                  await showShadDialog<void>(
                    context: context,
                    builder: (ctx) => StatefulBuilder(
                      builder: (ctx, setState) {
                        return ShadDialog(
                          title: const Text('Pick shadow color'),
                          actions: [
                            ShadButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('Done'),
                            ),
                          ],
                          child: ColorPicker(
                            pickerColor: selected,
                            onColorChanged: (next) {
                              selected = next;
                              onChanged(
                                  layer.copyWith(colorValue: next.toARGB32()));
                              setState(() {});
                            },
                            enableAlpha: true,
                            displayThumbColor: true,
                          ),
                        );
                      },
                    ),
                  );
                },
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: Settings.tacticalVioletTheme.border),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ShadInput(
                  controller: hexController,
                  placeholder: const Text('#RRGGBB / #AARRGGBB'),
                  onSubmitted: (value) {
                    final parsed = ThemeColorFormat.parseHex(value);
                    if (parsed == null) return;
                    onChanged(layer.copyWith(colorValue: parsed.toARGB32()));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _NumericField(
                label: 'Blur',
                value: layer.blurRadius,
                onChanged: (value) =>
                    onChanged(layer.copyWith(blurRadius: value)),
              ),
              const SizedBox(width: 6),
              _NumericField(
                label: 'Spread',
                value: layer.spreadRadius,
                onChanged: (value) =>
                    onChanged(layer.copyWith(spreadRadius: value)),
              ),
              const SizedBox(width: 6),
              _NumericField(
                label: 'Offset X',
                value: layer.offsetX,
                onChanged: (value) => onChanged(layer.copyWith(offsetX: value)),
              ),
              const SizedBox(width: 6),
              _NumericField(
                label: 'Offset Y',
                value: layer.offsetY,
                onChanged: (value) => onChanged(layer.copyWith(offsetY: value)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NumericField extends StatefulWidget {
  const _NumericField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_NumericField> createState() => _NumericFieldState();
}

class _NumericFieldState extends State<_NumericField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toStringAsFixed(1));
  }

  @override
  void didUpdateWidget(covariant _NumericField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.text = widget.value.toStringAsFixed(1);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label, style: ShadTheme.of(context).textTheme.small),
          const SizedBox(height: 4),
          ShadInput(
            controller: _controller,
            onSubmitted: (value) {
              final parsed = double.tryParse(value.trim());
              if (parsed == null) return;
              widget.onChanged(parsed);
            },
          ),
        ],
      ),
    );
  }
}
