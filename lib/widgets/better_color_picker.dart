import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum BetterColorPickerMode { rgb, hsl, hsv, hex }

class BetterColorPickerPalette {
  const BetterColorPickerPalette({
    required this.surface,
    required this.foreground,
    required this.mutedForeground,
    required this.inputBorder,
    required this.fieldFill,
  });

  final material.Color surface;
  final material.Color foreground;
  final material.Color mutedForeground;
  final material.Color inputBorder;
  final material.Color fieldFill;

  static const lightZinc = BetterColorPickerPalette(
    surface: material.Color(0xFFFFFFFF),
    foreground: material.Color(0xFF09090B),
    mutedForeground: material.Color(0xFF71717A),
    inputBorder: material.Color(0xFFE4E4E7),
    fieldFill: material.Color(0x4DE4E4E7),
  );

  static const darkZinc = BetterColorPickerPalette(
    surface: material.Color(0xFF09090B),
    foreground: material.Color(0xFFFAFAFA),
    mutedForeground: material.Color(0xFFA1A1AA),
    inputBorder: material.Color(0xFF27272A),
    fieldFill: material.Color(0x4D27272A),
  );
}

class BetterColorPickerStyle {
  const BetterColorPickerStyle({
    this.lightPalette = BetterColorPickerPalette.lightZinc,
    this.darkPalette = BetterColorPickerPalette.darkZinc,
    this.textStyle,
    this.monospaceTextStyle,
    this.mainSliderRadius = 8,
    this.channelSliderRadius = 4,
    this.fieldRadius = 8,
    this.swatchRadius = 8,
    this.fieldHeight = 36,
    this.dialogWidth = 420,
    this.mainSliderMinExtent = 150,
  });

  final BetterColorPickerPalette lightPalette;
  final BetterColorPickerPalette darkPalette;
  final material.TextStyle? textStyle;
  final material.TextStyle? monospaceTextStyle;
  final double mainSliderRadius;
  final double channelSliderRadius;
  final double fieldRadius;
  final double swatchRadius;
  final double fieldHeight;
  final double dialogWidth;
  final double mainSliderMinExtent;

  BetterColorPickerPalette paletteFor(material.Brightness brightness) {
    return brightness == material.Brightness.dark ? darkPalette : lightPalette;
  }
}

class BetterColorPicker extends material.StatefulWidget {
  const BetterColorPicker({
    super.key,
    required this.value,
    this.onChanged,
    this.onChanging,
    this.initialMode = BetterColorPickerMode.rgb,
    this.onModeChanged,
    this.showAlpha = false,
    this.orientation = material.Axis.vertical,
    this.spacing,
    this.controlSpacing,
    this.sliderSize,
    this.style = const BetterColorPickerStyle(),
  });

  final material.Color value;
  final material.ValueChanged<material.Color>? onChanged;
  final material.ValueChanged<material.Color>? onChanging;
  final BetterColorPickerMode initialMode;
  final material.ValueChanged<BetterColorPickerMode>? onModeChanged;
  final bool showAlpha;
  final material.Axis orientation;
  final double? spacing;
  final double? controlSpacing;
  final double? sliderSize;
  final BetterColorPickerStyle style;

  @override
  material.State<BetterColorPicker> createState() => _BetterColorPickerState();
}

class _BetterColorPickerState extends material.State<BetterColorPicker> {
  late BetterColorPickerMode _mode;
  _PickerValue? _draftValue;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  @override
  void didUpdateWidget(covariant BetterColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialMode != widget.initialMode) {
      _mode = widget.initialMode;
    }
    if (oldWidget.value != widget.value) {
      final draftValue = _draftValue;
      if (draftValue == null || draftValue.color != widget.value) {
        _draftValue = null;
      }
    }
  }

  _PickerValue get _effectiveValue =>
      _draftValue ?? _PickerValue.fromColor(widget.value);

  @override
  material.Widget build(material.BuildContext context) {
    final pickerWidth = _rgbPickerControlsWidth(showAlpha: widget.showAlpha);
    final pickerScale = _pickerScaleFactor(pickerWidth: pickerWidth);
    final spacing = (widget.spacing ?? 12.0) * pickerScale;
    final controlSpacing = (widget.controlSpacing ?? 8.0) * pickerScale;
    final sliderSize = (widget.sliderSize ?? 24.0) * pickerScale;
    final mainSliderRadius = widget.style.mainSliderRadius * pickerScale;
    final channelSliderRadius = widget.style.channelSliderRadius * pickerScale;
    final sliderHandleSize = 16.0 * pickerScale;
    final sliderHandleBorderWidth = math.max(1.0, 2.0 * pickerScale);
    final alphaCheckboardSize = 8.0 * pickerScale;
    final body = widget.orientation == material.Axis.horizontal
        ? material.Column(
            mainAxisSize: material.MainAxisSize.min,
            crossAxisAlignment: material.CrossAxisAlignment.stretch,
            children: [
              material.IntrinsicHeight(
                child: material.Row(
                  mainAxisSize: material.MainAxisSize.min,
                  crossAxisAlignment: material.CrossAxisAlignment.stretch,
                  children: [
                    material.Flexible(
                      child: _buildMainSlider(
                        sliderRadius: mainSliderRadius,
                        sliderHandleSize: sliderHandleSize,
                        sliderHandleBorderWidth: sliderHandleBorderWidth,
                      ),
                    ),
                    material.SizedBox(width: spacing),
                    ..._buildChannelSliders(
                      isHorizontalLayout: true,
                      sliderSize: sliderSize,
                      spacing: controlSpacing,
                      sliderRadius: channelSliderRadius,
                      sliderHandleSize: sliderHandleSize,
                      sliderHandleBorderWidth: sliderHandleBorderWidth,
                      alphaCheckboardSize: alphaCheckboardSize,
                    ),
                  ],
                ),
              ),
              material.SizedBox(height: spacing),
              material.SizedBox(
                width: pickerWidth,
                child: _PickerControls(
                  value: _effectiveValue,
                  mode: _mode,
                  showAlpha: widget.showAlpha,
                  fieldHeight: widget.style.fieldHeight,
                  fieldRadius: widget.style.fieldRadius,
                  style: widget.style,
                  targetWidth: pickerWidth,
                  onModeChanged: (mode) {
                    setState(() {
                      _mode = mode;
                    });
                    widget.onModeChanged?.call(mode);
                  },
                  onChanged: _handleCommittedChange,
                ),
              ),
            ],
          )
        : material.Column(
            mainAxisSize: material.MainAxisSize.min,
            crossAxisAlignment: material.CrossAxisAlignment.stretch,
            children: [
              material.SizedBox(
                width: pickerWidth,
                child: _buildMainSlider(
                  sliderRadius: mainSliderRadius,
                  sliderHandleSize: sliderHandleSize,
                  sliderHandleBorderWidth: sliderHandleBorderWidth,
                ),
              ),
              material.SizedBox(height: spacing),
              ..._buildChannelSliders(
                isHorizontalLayout: false,
                sliderSize: sliderSize,
                spacing: controlSpacing,
                mainAxisExtent: pickerWidth,
                sliderRadius: channelSliderRadius,
                sliderHandleSize: sliderHandleSize,
                sliderHandleBorderWidth: sliderHandleBorderWidth,
                alphaCheckboardSize: alphaCheckboardSize,
              ),
              material.SizedBox(height: controlSpacing),
              material.SizedBox(
                width: pickerWidth,
                child: _PickerControls(
                  value: _effectiveValue,
                  mode: _mode,
                  showAlpha: widget.showAlpha,
                  fieldHeight: widget.style.fieldHeight,
                  fieldRadius: widget.style.fieldRadius,
                  style: widget.style,
                  targetWidth: pickerWidth,
                  onModeChanged: (mode) {
                    setState(() {
                      _mode = mode;
                    });
                    widget.onModeChanged?.call(mode);
                  },
                  onChanged: _handleCommittedChange,
                ),
              ),
            ],
          );

    return material.RepaintBoundary(
      child: material.SizedBox(width: pickerWidth, child: body),
    );
  }

  material.Widget _buildMainSlider({
    required double sliderRadius,
    required double sliderHandleSize,
    required double sliderHandleBorderWidth,
  }) {
    return material.AspectRatio(
      aspectRatio: 1,
      child: material.ConstrainedBox(
        constraints: material.BoxConstraints(
          minWidth: widget.style.mainSliderMinExtent,
          minHeight: widget.style.mainSliderMinExtent,
        ),
        child: _mode == BetterColorPickerMode.hsl
            ? _HSLColorSlider(
                color: _effectiveValue.hsl,
                radius: material.Radius.circular(sliderRadius),
                cursorDiameter: sliderHandleSize,
                cursorBorderWidth: sliderHandleBorderWidth,
                onChanging: (value) {
                  _handleChangingChange(
                    _effectiveValue
                        .changeToHSLSaturation(value.saturation)
                        .changeToHSLLightness(value.lightness),
                  );
                },
                onChanged: (value) {
                  _handleCommittedChange(
                    _effectiveValue
                        .changeToHSLSaturation(value.saturation)
                        .changeToHSLLightness(value.lightness),
                  );
                },
              )
            : _HSVColorSlider(
                value: _effectiveValue.hsv,
                sliderType: _HSVSliderType.satVal,
                radius: material.Radius.circular(sliderRadius),
                cursorDiameter: sliderHandleSize,
                cursorBorderWidth: sliderHandleBorderWidth,
                onChanging: (value) {
                  _handleChangingChange(
                    _effectiveValue
                        .changeToHSVSaturation(value.saturation)
                        .changeToHSVValue(value.value),
                  );
                },
                onChanged: (value) {
                  _handleCommittedChange(
                    _effectiveValue
                        .changeToHSVSaturation(value.saturation)
                        .changeToHSVValue(value.value),
                  );
                },
              ),
      ),
    );
  }

  List<material.Widget> _buildChannelSliders({
    required bool isHorizontalLayout,
    required double sliderSize,
    required double spacing,
    required double sliderRadius,
    required double sliderHandleSize,
    required double sliderHandleBorderWidth,
    required double alphaCheckboardSize,
    double? mainAxisExtent,
  }) {
    final widgets = <material.Widget>[
      material.SizedBox(
        width: isHorizontalLayout ? sliderSize : mainAxisExtent,
        height: isHorizontalLayout ? null : sliderSize,
        child: _HSVColorSlider(
          value: _effectiveValue.hsv.withSaturation(1).withValue(1),
          sliderType: _HSVSliderType.hue,
          reverse: !isHorizontalLayout,
          radius: material.Radius.circular(sliderRadius),
          cursorDiameter: sliderHandleSize,
          cursorBorderWidth: sliderHandleBorderWidth,
          onChanging: (value) {
            _handleChangingChange(_effectiveValue.changeToHSVHue(value.hue));
          },
          onChanged: (value) {
            _handleCommittedChange(_effectiveValue.changeToHSVHue(value.hue));
          },
        ),
      ),
    ];

    if (widget.showAlpha) {
      widgets.add(
        material.SizedBox(
          width: isHorizontalLayout ? sliderSize : mainAxisExtent,
          height: isHorizontalLayout ? null : sliderSize,
          child: _HSVColorSlider(
            value: _effectiveValue.hsv,
            sliderType: _HSVSliderType.alpha,
            reverse: !isHorizontalLayout,
            radius: material.Radius.circular(sliderRadius),
            cursorDiameter: sliderHandleSize,
            cursorBorderWidth: sliderHandleBorderWidth,
            alphaCheckboardSize: alphaCheckboardSize,
            onChanging: (value) {
              _handleChangingChange(
                _effectiveValue.changeToOpacity(value.alpha),
              );
            },
            onChanged: (value) {
              _handleCommittedChange(
                _effectiveValue.changeToOpacity(value.alpha),
              );
            },
          ),
        ),
      );
    }

    final wrapped = <material.Widget>[];
    for (var i = 0; i < widgets.length; i++) {
      wrapped.add(widgets[i]);
      if (i < widgets.length - 1) {
        wrapped.add(
          isHorizontalLayout
              ? material.SizedBox(width: spacing)
              : material.SizedBox(height: spacing),
        );
      }
    }
    return wrapped;
  }

  void _handleChangingChange(_PickerValue value) {
    setState(() {
      _draftValue = value;
    });
    widget.onChanging?.call(value.color);
  }

  void _handleCommittedChange(_PickerValue value) {
    setState(() {
      _draftValue = value;
    });
    widget.onChanged?.call(value.color);
  }
}

class BetterColorPickerField extends material.StatelessWidget {
  const BetterColorPickerField({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChanging,
    this.initialMode = BetterColorPickerMode.rgb,
    this.showAlpha = false,
    this.orientation = material.Axis.vertical,
    this.label,
    this.enabled = true,
    this.dialogTitle = 'Select color',
    this.style = const BetterColorPickerStyle(),
  });

  final material.Color value;
  final material.ValueChanged<material.Color> onChanged;
  final material.ValueChanged<material.Color>? onChanging;
  final BetterColorPickerMode initialMode;
  final bool showAlpha;
  final material.Axis orientation;
  final String? label;
  final bool enabled;
  final String dialogTitle;
  final BetterColorPickerStyle style;

  @override
  material.Widget build(material.BuildContext context) {
    final theme = material.Theme.of(context);
    final borderColor = theme.colorScheme.outlineVariant;
    final foregroundColor = enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    return material.InkWell(
      onTap: enabled
          ? () async {
              final result = await showBetterColorPickerDialog(
                context,
                initialColor: value,
                title: dialogTitle,
                initialMode: initialMode,
                showAlpha: showAlpha,
                orientation: orientation,
                onChanging: onChanging,
                style: style,
              );
              if (result != null && context.mounted) {
                onChanged(result);
              }
            }
          : null,
      borderRadius: material.BorderRadius.circular(12),
      child: material.Container(
        padding: const material.EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        decoration: material.BoxDecoration(
          border: material.Border.all(color: borderColor),
          borderRadius: material.BorderRadius.circular(12),
          color: enabled ? theme.colorScheme.surface : theme.disabledColor,
        ),
        child: material.Row(
          mainAxisSize: material.MainAxisSize.min,
          children: [
            material.Expanded(
              child: material.Column(
                crossAxisAlignment: material.CrossAxisAlignment.start,
                mainAxisSize: material.MainAxisSize.min,
                children: [
                  if (label != null)
                    material.Padding(
                      padding: const material.EdgeInsets.only(bottom: 4),
                      child: material.Text(
                        label!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  material.Text(
                    _colorToHex(value, showAlpha: showAlpha),
                    style: _monoTextStyle(
                      context,
                      style,
                    ).copyWith(color: foregroundColor),
                  ),
                ],
              ),
            ),
            const material.SizedBox(width: 12),
            _ColorSwatch(color: value, size: 28, radius: style.swatchRadius),
          ],
        ),
      ),
    );
  }
}

Future<material.Color?> showBetterColorPickerDialog(
  material.BuildContext context, {
  required material.Color initialColor,
  String title = 'Select color',
  BetterColorPickerMode initialMode = BetterColorPickerMode.rgb,
  bool showAlpha = false,
  material.Axis orientation = material.Axis.vertical,
  material.ValueChanged<material.Color>? onChanging,
  BetterColorPickerStyle style = const BetterColorPickerStyle(),
}) {
  return material.showDialog<material.Color>(
    context: context,
    builder: (context) {
      return _BetterColorPickerDialog(
        initialColor: initialColor,
        title: title,
        initialMode: initialMode,
        showAlpha: showAlpha,
        orientation: orientation,
        onChanging: onChanging,
        style: style,
      );
    },
  );
}

class _BetterColorPickerDialog extends material.StatefulWidget {
  const _BetterColorPickerDialog({
    required this.initialColor,
    required this.title,
    required this.initialMode,
    required this.showAlpha,
    required this.orientation,
    required this.style,
    this.onChanging,
  });

  final material.Color initialColor;
  final String title;
  final BetterColorPickerMode initialMode;
  final bool showAlpha;
  final material.Axis orientation;
  final BetterColorPickerStyle style;
  final material.ValueChanged<material.Color>? onChanging;

  @override
  material.State<_BetterColorPickerDialog> createState() =>
      _BetterColorPickerDialogState();
}

class _BetterColorPickerDialogState
    extends material.State<_BetterColorPickerDialog> {
  late material.Color _value;
  late final material.ValueNotifier<material.Color> _previewColor;

  @override
  void initState() {
    super.initState();
    _value = widget.initialColor;
    _previewColor = material.ValueNotifier(widget.initialColor);
  }

  @override
  void dispose() {
    _previewColor.dispose();
    super.dispose();
  }

  @override
  material.Widget build(material.BuildContext context) {
    final theme = material.Theme.of(context);
    return material.AlertDialog(
      title: material.Text(widget.title),
      contentPadding: const material.EdgeInsets.fromLTRB(24, 20, 24, 0),
      content: material.SizedBox(
        width: widget.style.dialogWidth,
        child: material.Column(
          mainAxisSize: material.MainAxisSize.min,
          crossAxisAlignment: material.CrossAxisAlignment.stretch,
          children: [
            material.ValueListenableBuilder<material.Color>(
              valueListenable: _previewColor,
              builder: (context, previewColor, child) {
                return material.Row(
                  children: [
                    _ColorSwatch(
                      color: previewColor,
                      size: 44,
                      radius: widget.style.swatchRadius,
                    ),
                    const material.SizedBox(width: 12),
                    material.Expanded(
                      child: material.Text(
                        _colorToHex(previewColor, showAlpha: widget.showAlpha),
                        style: _monoTextStyle(
                          context,
                          widget.style,
                        ).merge(theme.textTheme.titleMedium),
                      ),
                    ),
                  ],
                );
              },
            ),
            const material.SizedBox(height: 20),
            BetterColorPicker(
              value: _value,
              initialMode: widget.initialMode,
              showAlpha: widget.showAlpha,
              orientation: widget.orientation,
              style: widget.style,
              onChanging: (value) {
                if (_previewColor.value != value) {
                  _previewColor.value = value;
                }
                widget.onChanging?.call(value);
              },
              onChanged: (value) {
                _value = value;
                if (_previewColor.value != value) {
                  _previewColor.value = value;
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        material.TextButton(
          onPressed: () => material.Navigator.of(context).pop(),
          child: const material.Text('Cancel'),
        ),
        material.FilledButton(
          onPressed: () => material.Navigator.of(context).pop(_value),
          child: const material.Text('Apply'),
        ),
      ],
    );
  }
}

class _PickerControls extends material.StatelessWidget {
  const _PickerControls({
    required this.value,
    required this.mode,
    required this.showAlpha,
    required this.fieldHeight,
    required this.fieldRadius,
    required this.style,
    this.targetWidth,
    required this.onModeChanged,
    required this.onChanged,
  });

  final _PickerValue value;
  final BetterColorPickerMode mode;
  final bool showAlpha;
  final double fieldHeight;
  final double fieldRadius;
  final BetterColorPickerStyle style;
  final double? targetWidth;
  final material.ValueChanged<BetterColorPickerMode> onModeChanged;
  final material.ValueChanged<_PickerValue> onChanged;

  @override
  material.Widget build(material.BuildContext context) {
    final palette = style.paletteFor(material.Theme.of(context).brightness);
    final fields = <_GroupedFieldData>[
      _GroupedFieldData(
        width: 96,
        builder: (scaledWidth, index, length) => _ModeField(
          value: mode,
          width: scaledWidth,
          fieldHeight: fieldHeight,
          fieldRadius: fieldRadius,
          style: style,
          palette: palette,
          groupIndex: index,
          groupLength: length,
          onChanged: onModeChanged,
        ),
      ),
      ...switch (mode) {
        BetterColorPickerMode.rgb => _buildRgbFields(),
        BetterColorPickerMode.hsl => _buildHslFields(),
        BetterColorPickerMode.hsv => _buildHsvFields(),
        BetterColorPickerMode.hex => _buildHexFields(),
      },
    ];
    final preferredWidth =
        targetWidth ?? _pickerControlsWidth(mode: mode, showAlpha: showAlpha);

    return material.LayoutBuilder(
      builder: (context, constraints) {
        final resolvedTargetWidth = constraints.hasBoundedWidth
            ? math.max(preferredWidth, constraints.maxWidth)
            : preferredWidth;
        final scaledWidths = _scaleGroupedFieldWidths(
          widths: [for (final field in fields) field.width],
          targetWidth: resolvedTargetWidth,
        );

        return material.SizedBox(
          width: resolvedTargetWidth,
          child: material.SingleChildScrollView(
            scrollDirection: material.Axis.horizontal,
            child: material.Row(
              mainAxisSize: material.MainAxisSize.min,
              children: [
                for (var i = 0; i < fields.length; i++)
                  fields[i].builder(scaledWidths[i], i, fields.length),
              ],
            ),
          ),
        );
      },
    );
  }

  List<_GroupedFieldData> _buildRgbFields() {
    return [
      _numberField(
        width: 64,
        value: value.red.toString(),
        placeholder: 'Red',
        min: 0,
        max: 255,
        onChanged: (next) => onChanged(value.changeToColorRed(next.toDouble())),
      ),
      _numberField(
        width: 64,
        value: value.green.toString(),
        placeholder: 'Green',
        min: 0,
        max: 255,
        onChanged: (next) =>
            onChanged(value.changeToColorGreen(next.toDouble())),
      ),
      _numberField(
        width: 64,
        value: value.blue.toString(),
        placeholder: 'Blue',
        min: 0,
        max: 255,
        onChanged: (next) =>
            onChanged(value.changeToColorBlue(next.toDouble())),
      ),
      if (showAlpha)
        _numberField(
          width: 64,
          value: (value.opacity * 255).round().toString(),
          placeholder: 'Alpha',
          min: 0,
          max: 255,
          onChanged: (next) => onChanged(value.changeToOpacity(next / 255)),
        ),
    ];
  }

  List<_GroupedFieldData> _buildHslFields() {
    return [
      _numberField(
        width: 64,
        value: value.hslHue.round().toString(),
        placeholder: 'Hue',
        min: 0,
        max: 360,
        onChanged: (next) => onChanged(value.changeToHSLHue(next.toDouble())),
      ),
      _numberField(
        width: 64,
        value: (value.hslSat * 100).round().toString(),
        placeholder: 'Sat',
        min: 0,
        max: 100,
        onChanged: (next) => onChanged(value.changeToHSLSaturation(next / 100)),
      ),
      _numberField(
        width: 64,
        value: (value.hslLightness * 100).round().toString(),
        placeholder: 'Lum',
        min: 0,
        max: 100,
        onChanged: (next) => onChanged(value.changeToHSLLightness(next / 100)),
      ),
      if (showAlpha)
        _numberField(
          width: 64,
          value: (value.opacity * 100).round().toString(),
          placeholder: 'Alpha',
          min: 0,
          max: 100,
          onChanged: (next) => onChanged(value.changeToOpacity(next / 100)),
        ),
    ];
  }

  List<_GroupedFieldData> _buildHsvFields() {
    return [
      _numberField(
        width: 64,
        value: value.hsvHue.round().toString(),
        placeholder: 'Hue',
        min: 0,
        max: 360,
        onChanged: (next) => onChanged(value.changeToHSVHue(next.toDouble())),
      ),
      _numberField(
        width: 64,
        value: (value.hsvSat * 100).round().toString(),
        placeholder: 'Sat',
        min: 0,
        max: 100,
        onChanged: (next) => onChanged(value.changeToHSVSaturation(next / 100)),
      ),
      _numberField(
        width: 64,
        value: (value.hsvValue * 100).round().toString(),
        placeholder: 'Val',
        min: 0,
        max: 100,
        onChanged: (next) => onChanged(value.changeToHSVValue(next / 100)),
      ),
      if (showAlpha)
        _numberField(
          width: 64,
          value: (value.opacity * 100).round().toString(),
          placeholder: 'Alpha',
          min: 0,
          max: 100,
          onChanged: (next) => onChanged(value.changeToOpacity(next / 100)),
        ),
    ];
  }

  List<_GroupedFieldData> _buildHexFields() {
    return [
      _GroupedFieldData(
        width: 104,
        builder: (scaledWidth, index, length) => _PickerFieldFrame(
          width: scaledWidth,
          height: fieldHeight,
          fieldRadius: fieldRadius,
          style: style,
          groupIndex: index,
          groupLength: length,
          child: _ValueField(
            value: _colorToHex(value.color, showAlpha: false),
            placeholder: 'HEX',
            style: style,
            keyboardType: material.TextInputType.text,
            inputFormatters: const [_HexTextFormatter()],
            onChanged: (raw) {
              final parsed = _tryParseHex(raw);
              if (parsed != null) {
                onChanged(
                  value
                      .changeToColorRed(_red(parsed).toDouble())
                      .changeToColorGreen(_green(parsed).toDouble())
                      .changeToColorBlue(_blue(parsed).toDouble()),
                );
              }
            },
          ),
        ),
      ),
      if (showAlpha)
        _numberField(
          width: 64,
          value: (value.opacity * 100).round().toString(),
          placeholder: 'Alpha',
          min: 0,
          max: 100,
          onChanged: (next) => onChanged(value.changeToOpacity(next / 100)),
        ),
    ];
  }

  _GroupedFieldData _numberField({
    required double width,
    required String value,
    required String placeholder,
    required int min,
    required int max,
    required material.ValueChanged<int> onChanged,
  }) {
    return _GroupedFieldData(
      width: width,
      builder: (scaledWidth, index, length) => _PickerFieldFrame(
        width: scaledWidth,
        height: fieldHeight,
        fieldRadius: fieldRadius,
        style: style,
        groupIndex: index,
        groupLength: length,
        child: _ValueField(
          value: value,
          placeholder: placeholder,
          style: style,
          keyboardType: material.TextInputType.number,
          inputFormatters: [_IntegerRangeFormatter(min: min, max: max)],
          onChanged: (raw) {
            final parsed = int.tryParse(raw);
            if (parsed != null) {
              onChanged(parsed.clamp(min, max));
            }
          },
        ),
      ),
    );
  }
}

class _GroupedFieldData {
  const _GroupedFieldData({required this.width, required this.builder});

  final double width;
  final material.Widget Function(double width, int index, int length) builder;
}

double _pickerControlsWidth({
  required BetterColorPickerMode mode,
  required bool showAlpha,
}) {
  final widths = <double>[
    96,
    ...switch (mode) {
      BetterColorPickerMode.rgb => [64, 64, 64, if (showAlpha) 64],
      BetterColorPickerMode.hsl => [64, 64, 64, if (showAlpha) 64],
      BetterColorPickerMode.hsv => [64, 64, 64, if (showAlpha) 64],
      BetterColorPickerMode.hex => [104, if (showAlpha) 64],
    },
  ];

  // Grouped fields overlap borders by 1px to avoid double-width separators.
  return widths.reduce((sum, width) => sum + width) - (widths.length - 1);
}

double _rgbPickerControlsWidth({required bool showAlpha}) {
  return _pickerControlsWidth(
    mode: BetterColorPickerMode.rgb,
    showAlpha: showAlpha,
  );
}

List<double> _scaleGroupedFieldWidths({
  required List<double> widths,
  required double targetWidth,
}) {
  if (widths.isEmpty) {
    return const [];
  }

  final overlapCount = widths.length - 1;
  final totalBaseWidth = widths.reduce((sum, width) => sum + width);
  final scale = (targetWidth + overlapCount) / totalBaseWidth;

  return [for (final width in widths) width * scale];
}

double _pickerScaleFactor({required double pickerWidth}) {
  return pickerWidth / _rgbPickerControlsWidth(showAlpha: false);
}

class _ModeField extends material.StatelessWidget {
  const _ModeField({
    required this.value,
    required this.width,
    required this.fieldHeight,
    required this.fieldRadius,
    required this.style,
    required this.palette,
    required this.groupIndex,
    required this.groupLength,
    required this.onChanged,
  });

  final BetterColorPickerMode value;
  final double width;
  final double fieldHeight;
  final double fieldRadius;
  final BetterColorPickerStyle style;
  final BetterColorPickerPalette palette;
  final int groupIndex;
  final int groupLength;
  final material.ValueChanged<BetterColorPickerMode> onChanged;

  @override
  material.Widget build(material.BuildContext context) {
    return _PickerFieldFrame(
      width: width,
      height: fieldHeight,
      fieldRadius: fieldRadius,
      style: style,
      groupIndex: groupIndex,
      groupLength: groupLength,
      child: ShadSelect<BetterColorPickerMode>(
        initialValue: value,
        minWidth: width,
        maxWidth: width,
        maxHeight: 180,
        padding: const material.EdgeInsets.symmetric(horizontal: 12),
        optionsPadding: const material.EdgeInsets.all(4),
        decoration: ShadDecoration.none,
        selectedOptionBuilder: (context, mode) {
          return material.Text(
            _modeLabel(mode),
            style: _textStyle(context, style).copyWith(
              color: palette.foreground,
            ),
          );
        },
        trailing: material.Icon(
          material.Icons.unfold_more,
          size: 16,
          color: palette.mutedForeground,
        ),
        options: [
          for (final mode in BetterColorPickerMode.values)
            ShadOption(
              value: mode,
              child: material.Text(_modeLabel(mode)),
            ),
        ],
        onChanged: (mode) {
          if (mode != null) {
            onChanged(mode);
          }
        },
      ),
    );
  }
}

class _PickerFieldFrame extends material.StatelessWidget {
  const _PickerFieldFrame({
    required this.width,
    required this.height,
    required this.fieldRadius,
    required this.style,
    required this.groupIndex,
    required this.groupLength,
    required this.child,
  });

  final double width;
  final double height;
  final double fieldRadius;
  final BetterColorPickerStyle style;
  final int groupIndex;
  final int groupLength;
  final material.Widget child;

  @override
  material.Widget build(material.BuildContext context) {
    final palette = style.paletteFor(material.Theme.of(context).brightness);
    final field = material.Container(
      width: width,
      height: height,
      decoration: material.BoxDecoration(
        color: palette.fieldFill,
        borderRadius: _groupRadius(),
        border: material.Border.all(color: palette.inputBorder),
      ),
      child: child,
    );
    if (groupIndex == 0) {
      return field;
    }
    return material.Transform.translate(
      offset: material.Offset(-groupIndex.toDouble(), 0),
      child: field,
    );
  }

  material.BorderRadius _groupRadius() {
    final radius = material.Radius.circular(fieldRadius);
    if (groupLength == 1) {
      return material.BorderRadius.all(radius);
    }
    if (groupIndex == 0) {
      return material.BorderRadius.horizontal(left: radius);
    }
    if (groupIndex == groupLength - 1) {
      return material.BorderRadius.horizontal(right: radius);
    }
    return material.BorderRadius.zero;
  }
}

class _ValueField extends material.StatefulWidget {
  const _ValueField({
    required this.value,
    required this.placeholder,
    required this.style,
    this.onChanged,
    this.inputFormatters,
    this.keyboardType,
  });

  final String value;
  final String placeholder;
  final BetterColorPickerStyle style;
  final material.ValueChanged<String>? onChanged;
  final List<TextInputFormatter>? inputFormatters;
  final material.TextInputType? keyboardType;

  @override
  material.State<_ValueField> createState() => _ValueFieldState();
}

class _ValueFieldState extends material.State<_ValueField> {
  late final material.TextEditingController _controller;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _controller = material.TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _ValueField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focused && oldWidget.value != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  material.Widget build(material.BuildContext context) {
    final palette = widget.style.paletteFor(
      material.Theme.of(context).brightness,
    );
    return material.Focus(
      onFocusChange: (focused) {
        setState(() {
          _focused = focused;
        });
      },
      child: material.TextField(
        controller: _controller,
        onChanged: widget.onChanged == null
            ? null
            : (value) {
                if (_focused) {
                  widget.onChanged!(value);
                }
              },
        keyboardType: widget.keyboardType,
        inputFormatters: widget.inputFormatters,
        maxLines: 1,
        textAlignVertical: material.TextAlignVertical.center,
        style: _monoTextStyle(
          context,
          widget.style,
        ).copyWith(color: palette.foreground),
        decoration: material.InputDecoration(
          isDense: true,
          border: material.InputBorder.none,
          contentPadding: const material.EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          hintText: widget.placeholder,
          hintStyle: _textStyle(
            context,
            widget.style,
          ).copyWith(color: palette.mutedForeground),
        ),
      ),
    );
  }
}

class _PickerValue {
  const _PickerValue._({
    required this.color,
    required this.hsv,
    required this.hsl,
  });

  factory _PickerValue.fromColor(material.Color color) {
    return _PickerValue._(
      color: color,
      hsv: material.HSVColor.fromColor(color),
      hsl: material.HSLColor.fromColor(color),
    );
  }

  factory _PickerValue.fromHSV(material.HSVColor hsv) {
    final color = hsv.toColor();
    return _PickerValue._(
      color: color,
      hsv: hsv,
      hsl: material.HSLColor.fromColor(color),
    );
  }

  factory _PickerValue.fromHSL(material.HSLColor hsl) {
    final color = hsl.toColor();
    return _PickerValue._(
      color: color,
      hsv: material.HSVColor.fromColor(color),
      hsl: hsl,
    );
  }

  final material.Color color;
  final material.HSVColor hsv;
  final material.HSLColor hsl;

  int get red => _red(color);
  int get green => _green(color);
  int get blue => _blue(color);
  double get opacity => color.a.clamp(0, 1);
  double get hsvHue => hsv.hue;
  double get hsvSat => hsv.saturation;
  double get hsvValue => hsv.value;
  double get hslHue => hsl.hue;
  double get hslSat => hsl.saturation;
  double get hslLightness => hsl.lightness;

  _PickerValue changeToColorRed(double value) {
    return _PickerValue.fromColor(
      material.Color.fromARGB(
        _alpha(color),
        value.round().clamp(0, 255),
        green,
        blue,
      ),
    );
  }

  _PickerValue changeToColorGreen(double value) {
    return _PickerValue.fromColor(
      material.Color.fromARGB(
        _alpha(color),
        red,
        value.round().clamp(0, 255),
        blue,
      ),
    );
  }

  _PickerValue changeToColorBlue(double value) {
    return _PickerValue.fromColor(
      material.Color.fromARGB(
        _alpha(color),
        red,
        green,
        value.round().clamp(0, 255),
      ),
    );
  }

  _PickerValue changeToOpacity(double value) {
    return _PickerValue.fromHSV(hsv.withAlpha(value.clamp(0, 1)));
  }

  _PickerValue changeToHSVHue(double value) {
    return _PickerValue.fromHSV(hsv.withHue(value));
  }

  _PickerValue changeToHSVSaturation(double value) {
    return _PickerValue.fromHSV(hsv.withSaturation(value.clamp(0, 1)));
  }

  _PickerValue changeToHSVValue(double value) {
    return _PickerValue.fromHSV(hsv.withValue(value.clamp(0, 1)));
  }

  _PickerValue changeToHSLHue(double value) {
    return _PickerValue.fromHSL(hsl.withHue(value));
  }

  _PickerValue changeToHSLSaturation(double value) {
    return _PickerValue.fromHSL(hsl.withSaturation(value.clamp(0, 1)));
  }

  _PickerValue changeToHSLLightness(double value) {
    return _PickerValue.fromHSL(hsl.withLightness(value.clamp(0, 1)));
  }
}

enum _HSVSliderType { hue, satVal, alpha }

class _HSVColorSlider extends material.StatefulWidget {
  const _HSVColorSlider({
    required this.value,
    required this.sliderType,
    required this.radius,
    this.cursorDiameter = 16,
    this.cursorBorderWidth = 2,
    this.alphaCheckboardSize = 8,
    this.onChanging,
    this.onChanged,
    this.reverse = false,
  });

  final material.HSVColor value;
  final _HSVSliderType sliderType;
  final material.Radius radius;
  final double cursorDiameter;
  final double cursorBorderWidth;
  final double alphaCheckboardSize;
  final material.ValueChanged<material.HSVColor>? onChanging;
  final material.ValueChanged<material.HSVColor>? onChanged;
  final bool reverse;

  @override
  material.State<_HSVColorSlider> createState() => _HSVColorSliderState();
}

class _HSVColorSliderState extends material.State<_HSVColorSlider> {
  late double _currentHorizontal;
  late double _currentVertical;
  late double _hue;
  late double _saturation;
  late double _value;
  late double _alpha;

  @override
  void initState() {
    super.initState();
    _syncFromWidget();
  }

  @override
  void didUpdateWidget(covariant _HSVColorSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _syncFromWidget();
    }
  }

  void _syncFromWidget() {
    final hsv = widget.value;
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value;
    _alpha = hsv.alpha;
    _currentHorizontal = horizontal;
    _currentVertical = vertical;
  }

  @override
  material.Widget build(material.BuildContext context) {
    final cursorDiameter = widget.cursorDiameter;
    final radiusDivisor =
        widget.sliderType == _HSVSliderType.satVal ? 2.0 : 4.0;
    return material.GestureDetector(
      onTapDown: (details) {
        _updateColor(details.localPosition, context.size!);
        widget.onChanged?.call(_currentColor);
      },
      onPanUpdate: (details) {
        setState(() {
          _updateColor(details.localPosition, context.size!);
        });
      },
      onPanEnd: (_) => widget.onChanged?.call(_currentColor),
      child: material.Stack(
        clipBehavior: material.Clip.none,
        children: [
          if (widget.sliderType == _HSVSliderType.alpha)
            material.Positioned.fill(
              child: material.RepaintBoundary(
                child: material.ClipRRect(
                  borderRadius: material.BorderRadius.all(widget.radius),
                  child: material.CustomPaint(
                    painter: _AlphaPainter(
                      checkboardSize: widget.alphaCheckboardSize,
                    ),
                  ),
                ),
              ),
            ),
          material.Positioned.fill(
            child: material.RepaintBoundary(
              child: material.ClipRRect(
                borderRadius: material.BorderRadius.all(widget.radius),
                child: material.CustomPaint(
                  painter: _HSVColorSliderPainter(
                    sliderType: widget.sliderType,
                    color: _currentColor,
                    reverse: widget.reverse,
                  ),
                ),
              ),
            ),
          ),
          material.Positioned(
            left: -cursorDiameter / radiusDivisor,
            right: -cursorDiameter / radiusDivisor,
            top: -cursorDiameter / radiusDivisor,
            bottom: -cursorDiameter / radiusDivisor,
            child: widget.sliderType == _HSVSliderType.satVal
                ? material.Align(
                    alignment: material.Alignment(
                      (_currentHorizontal.clamp(0, 1) * 2) - 1,
                      (_currentVertical.clamp(0, 1) * 2) - 1,
                    ),
                    child: material.Container(
                      width: cursorDiameter,
                      height: cursorDiameter,
                      decoration: material.BoxDecoration(
                        shape: material.BoxShape.circle,
                        color: _currentColor.toColor(),
                        border: material.Border.all(
                          color: material.Colors.white,
                          width: widget.cursorBorderWidth,
                        ),
                      ),
                    ),
                  )
                : _SingleAxisCursor(
                    reverse: widget.reverse,
                    horizontal: _currentHorizontal,
                    vertical: _currentVertical,
                    radius: widget.radius,
                    thickness: cursorDiameter,
                    borderWidth: widget.cursorBorderWidth,
                    color: _currentColor.toColor(),
                  ),
          ),
        ],
      ),
    );
  }

  material.HSVColor get _currentColor {
    return material.HSVColor.fromAHSV(
      _alpha.clamp(0, 1),
      _hue.clamp(0, 360),
      _saturation.clamp(0, 1),
      _value.clamp(0, 1),
    );
  }

  void _updateColor(material.Offset localPosition, material.Size size) {
    _currentHorizontal = (localPosition.dx / size.width).clamp(0, 1);
    _currentVertical = (localPosition.dy / size.height).clamp(0, 1);
    switch (widget.sliderType) {
      case _HSVSliderType.hue:
        _hue = (widget.reverse ? _currentHorizontal : _currentVertical) * 360;
        break;
      case _HSVSliderType.alpha:
        _alpha = widget.reverse ? _currentHorizontal : _currentVertical;
        break;
      case _HSVSliderType.satVal:
        if (widget.reverse) {
          _saturation = _currentHorizontal;
          _value = _currentVertical;
        } else {
          _saturation = _currentVertical;
          _value = _currentHorizontal;
        }
        break;
    }
    widget.onChanging?.call(_currentColor);
  }

  double get vertical {
    switch (widget.sliderType) {
      case _HSVSliderType.hue:
        return widget.value.hue / 360;
      case _HSVSliderType.alpha:
        return widget.value.alpha;
      case _HSVSliderType.satVal:
        return widget.reverse ? widget.value.value : widget.value.saturation;
    }
  }

  double get horizontal {
    switch (widget.sliderType) {
      case _HSVSliderType.hue:
        return widget.value.hue / 360;
      case _HSVSliderType.alpha:
        return widget.value.alpha;
      case _HSVSliderType.satVal:
        return widget.reverse ? widget.value.saturation : widget.value.value;
    }
  }
}

class _HSLColorSlider extends material.StatefulWidget {
  const _HSLColorSlider({
    required this.color,
    required this.radius,
    this.cursorDiameter = 16,
    this.cursorBorderWidth = 2,
    this.onChanging,
    this.onChanged,
  });

  final material.HSLColor color;
  final material.Radius radius;
  final double cursorDiameter;
  final double cursorBorderWidth;
  final material.ValueChanged<material.HSLColor>? onChanging;
  final material.ValueChanged<material.HSLColor>? onChanged;

  @override
  material.State<_HSLColorSlider> createState() => _HSLColorSliderState();
}

class _HSLColorSliderState extends material.State<_HSLColorSlider> {
  late double _currentHorizontal;
  late double _currentVertical;
  late double _hue;
  late double _saturation;
  late double _lightness;
  late double _alpha;

  @override
  void initState() {
    super.initState();
    _syncFromWidget();
  }

  @override
  void didUpdateWidget(covariant _HSLColorSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color) {
      _syncFromWidget();
    }
  }

  void _syncFromWidget() {
    final hsl = widget.color;
    _hue = hsl.hue;
    _saturation = hsl.saturation;
    _lightness = hsl.lightness;
    _alpha = hsl.alpha;
    _currentHorizontal = horizontal;
    _currentVertical = vertical;
  }

  @override
  material.Widget build(material.BuildContext context) {
    final cursorDiameter = widget.cursorDiameter;
    return material.GestureDetector(
      onTapDown: (details) {
        _updateColor(details.localPosition, context.size!);
        widget.onChanged?.call(_currentColor);
      },
      onPanUpdate: (details) {
        setState(() {
          _updateColor(details.localPosition, context.size!);
        });
      },
      onPanEnd: (_) => widget.onChanged?.call(_currentColor),
      child: material.Stack(
        clipBehavior: material.Clip.none,
        children: [
          material.Positioned.fill(
            child: material.RepaintBoundary(
              child: material.ClipRRect(
                borderRadius: material.BorderRadius.all(widget.radius),
                child: material.CustomPaint(
                  painter: _HSLColorSliderPainter(color: _currentColor),
                ),
              ),
            ),
          ),
          material.Positioned(
            left: -cursorDiameter / 2,
            right: -cursorDiameter / 2,
            top: -cursorDiameter / 2,
            bottom: -cursorDiameter / 2,
            child: material.Align(
              alignment: material.Alignment(
                (_currentHorizontal.clamp(0, 1) * 2) - 1,
                (_currentVertical.clamp(0, 1) * 2) - 1,
              ),
              child: material.Container(
                width: cursorDiameter,
                height: cursorDiameter,
                decoration: material.BoxDecoration(
                  shape: material.BoxShape.circle,
                  color: _currentColor.toColor(),
                  border: material.Border.all(
                    color: material.Colors.white,
                    width: widget.cursorBorderWidth,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  material.HSLColor get _currentColor {
    return material.HSLColor.fromAHSL(
      _alpha.clamp(0, 1),
      _hue.clamp(0, 360),
      _saturation.clamp(0, 1),
      _lightness.clamp(0, 1),
    );
  }

  void _updateColor(material.Offset localPosition, material.Size size) {
    _currentHorizontal = (localPosition.dx / size.width).clamp(0, 1);
    _currentVertical = (localPosition.dy / size.height).clamp(0, 1);
    _saturation = _currentVertical;
    _lightness = _currentHorizontal;
    widget.onChanging?.call(_currentColor);
  }

  double get vertical => widget.color.saturation;

  double get horizontal => widget.color.lightness;
}

class _SingleAxisCursor extends material.StatelessWidget {
  const _SingleAxisCursor({
    required this.reverse,
    required this.horizontal,
    required this.vertical,
    required this.radius,
    required this.thickness,
    required this.borderWidth,
    required this.color,
  });

  final bool reverse;
  final double horizontal;
  final double vertical;
  final material.Radius radius;
  final double thickness;
  final double borderWidth;
  final material.Color color;

  @override
  material.Widget build(material.BuildContext context) {
    final alignment = material.Alignment(
      (horizontal.clamp(0, 1) * 2) - 1,
      (vertical.clamp(0, 1) * 2) - 1,
    );
    final handleCornerRadius =
        radius.x < thickness / 4 ? radius.x : thickness / 4;
    final handleRadius = material.Radius.circular(handleCornerRadius);
    if (reverse) {
      return material.Align(
        alignment: alignment,
        child: material.Container(
          width: thickness,
          height: double.infinity,
          decoration: material.BoxDecoration(
            color: color,
            border: material.Border.all(
              color: material.Colors.white,
              width: borderWidth,
            ),
            borderRadius: material.BorderRadius.all(handleRadius),
          ),
        ),
      );
    }
    return material.Align(
      alignment: alignment,
      child: material.Container(
        width: double.infinity,
        height: thickness,
        decoration: material.BoxDecoration(
          color: color,
          border: material.Border.all(
            color: material.Colors.white,
            width: borderWidth,
          ),
          borderRadius: material.BorderRadius.all(handleRadius),
        ),
      ),
    );
  }
}

class _AlphaPainter extends material.CustomPainter {
  const _AlphaPainter({required this.checkboardSize});

  static const checkboardPrimary = material.Color(0xFFE0E0E0);
  static const checkboardSecondary = material.Color(0xFFB0B0B0);
  final double checkboardSize;

  @override
  void paint(material.Canvas canvas, material.Size size) {
    final paint = material.Paint()
      ..style = material.PaintingStyle.fill
      ..color = checkboardPrimary;
    canvas.drawRect(material.Offset.zero & size, paint);
    paint.color = checkboardSecondary;
    for (var x = 0.0; x < size.width; x += checkboardSize) {
      for (var y = 0.0; y < size.height; y += checkboardSize) {
        final isEvenColumn = (x / checkboardSize).floor().isEven;
        final isEvenRow = (y / checkboardSize).floor().isEven;
        if (isEvenColumn == isEvenRow) {
          canvas.drawRect(
            material.Rect.fromLTWH(x, y, checkboardSize, checkboardSize),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AlphaPainter oldDelegate) {
    return oldDelegate.checkboardSize != checkboardSize;
  }
}

class _HSVColorSliderPainter extends material.CustomPainter {
  _HSVColorSliderPainter({
    required this.sliderType,
    required this.color,
    required this.reverse,
  });

  final _HSVSliderType sliderType;
  final material.HSVColor color;
  final bool reverse;

  @override
  void paint(material.Canvas canvas, material.Size size) {
    final paint = material.Paint()
      ..isAntiAlias = false
      ..style = material.PaintingStyle.fill;

    switch (sliderType) {
      case _HSVSliderType.satVal:
        final width = size.width / 100;
        final height = size.height / 100;
        for (var i = 0; i < 100; i++) {
          for (var j = 0; j < 100; j++) {
            paint.color = material.HSVColor.fromAHSV(
              1,
              color.hue,
              reverse ? i / 100 : j / 100,
              reverse ? j / 100 : i / 100,
            ).toColor();
            canvas.drawRect(
              material.Rect.fromLTWH(i * width, j * height, width, height),
              paint,
            );
          }
        }
        break;
      case _HSVSliderType.hue:
        if (reverse) {
          final width = size.width / 360;
          for (var i = 0; i < 360; i++) {
            paint.color = material.HSVColor.fromAHSV(
              1,
              i.toDouble(),
              color.saturation,
              color.value,
            ).toColor();
            canvas.drawRect(
              material.Rect.fromLTWH(i * width, 0, width, size.height),
              paint,
            );
          }
        } else {
          final height = size.height / 360;
          for (var i = 0; i < 360; i++) {
            paint.color = material.HSVColor.fromAHSV(
              1,
              i.toDouble(),
              color.saturation,
              color.value,
            ).toColor();
            canvas.drawRect(
              material.Rect.fromLTWH(0, i * height, size.width, height),
              paint,
            );
          }
        }
        break;
      case _HSVSliderType.alpha:
        final opaque = material.Color.fromARGB(
          255,
          _red(color.toColor()),
          _green(color.toColor()),
          _blue(color.toColor()),
        );
        paint.shader = material.LinearGradient(
          begin: reverse
              ? material.Alignment.centerLeft
              : material.Alignment.topCenter,
          end: reverse
              ? material.Alignment.centerRight
              : material.Alignment.bottomCenter,
          colors: [opaque.withValues(alpha: 0), opaque],
        ).createShader(material.Offset.zero & size);
        canvas.drawRect(material.Offset.zero & size, paint);
        paint.shader = null;
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _HSVColorSliderPainter oldDelegate) {
    if (oldDelegate.sliderType != sliderType ||
        oldDelegate.reverse != reverse) {
      return true;
    }
    switch (sliderType) {
      case _HSVSliderType.satVal:
        return oldDelegate.color.hue != color.hue;
      case _HSVSliderType.hue:
        return oldDelegate.color.saturation != color.saturation ||
            oldDelegate.color.value != color.value;
      case _HSVSliderType.alpha:
        return oldDelegate.color.hue != color.hue ||
            oldDelegate.color.saturation != color.saturation ||
            oldDelegate.color.value != color.value;
    }
  }
}

class _HSLColorSliderPainter extends material.CustomPainter {
  _HSLColorSliderPainter({required this.color});

  final material.HSLColor color;

  @override
  void paint(material.Canvas canvas, material.Size size) {
    final paint = material.Paint()
      ..isAntiAlias = false
      ..style = material.PaintingStyle.fill;
    final width = size.width / 100;
    final height = size.height / 100;
    for (var i = 0; i < 100; i++) {
      for (var j = 0; j < 100; j++) {
        paint.color = material.HSLColor.fromAHSL(
          1,
          color.hue,
          j / 100,
          i / 100,
        ).toColor();
        canvas.drawRect(
          material.Rect.fromLTWH(i * width, j * height, width, height),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HSLColorSliderPainter oldDelegate) {
    return oldDelegate.color.hue != color.hue;
  }
}

class _IntegerRangeFormatter extends TextInputFormatter {
  _IntegerRangeFormatter({required this.min, required this.max});

  final int min;
  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) {
      return newValue;
    }
    if (!RegExp(r'^\d+$').hasMatch(text)) {
      return oldValue;
    }
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < min || parsed > max) {
      return oldValue;
    }
    return newValue;
  }
}

class _HexTextFormatter extends TextInputFormatter {
  const _HexTextFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text.toUpperCase().replaceAll(
          RegExp(r'[^0-9A-F#]'),
          '',
        );
    if (text.isEmpty) {
      return newValue.copyWith(text: '');
    }
    if (!text.startsWith('#')) {
      text = '#$text';
    }
    if (text.length > 7) {
      text = text.substring(0, 7);
    }
    return newValue.copyWith(
      text: text,
      selection: material.TextSelection.collapsed(offset: text.length),
    );
  }
}

class _ColorSwatch extends material.StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.size,
    required this.radius,
  });

  final material.Color color;
  final double size;
  final double radius;

  @override
  material.Widget build(material.BuildContext context) {
    return material.Container(
      width: size,
      height: size,
      decoration: material.BoxDecoration(
        color: color,
        borderRadius: material.BorderRadius.circular(radius),
        border: material.Border.all(
          color: material.Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

material.TextStyle _textStyle(
  material.BuildContext context,
  BetterColorPickerStyle style,
) {
  return style.textStyle ?? material.Theme.of(context).textTheme.bodyMedium!;
}

material.TextStyle _monoTextStyle(
  material.BuildContext context,
  BetterColorPickerStyle style,
) {
  return style.monospaceTextStyle ??
      _textStyle(
        context,
        style,
      ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

material.Color? _tryParseHex(String value) {
  var hex = value.trim().toUpperCase();
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  }
  if (hex.length != 6) {
    return null;
  }
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) {
    return null;
  }
  return material.Color(0xFF000000 | parsed);
}

String _modeLabel(BetterColorPickerMode mode) {
  switch (mode) {
    case BetterColorPickerMode.rgb:
      return 'RGB';
    case BetterColorPickerMode.hsl:
      return 'HSL';
    case BetterColorPickerMode.hsv:
      return 'HSV';
    case BetterColorPickerMode.hex:
      return 'HEX';
  }
}

String _colorToHex(material.Color color, {required bool showAlpha}) {
  final red = _red(color).toRadixString(16).padLeft(2, '0');
  final green = _green(color).toRadixString(16).padLeft(2, '0');
  final blue = _blue(color).toRadixString(16).padLeft(2, '0');
  if (!showAlpha) {
    return '#$red$green$blue'.toUpperCase();
  }
  final alpha = _alpha(color).toRadixString(16).padLeft(2, '0');
  return '#$alpha$red$green$blue'.toUpperCase();
}

int _red(material.Color color) => (color.r * 255).round().clamp(0, 255);

int _green(material.Color color) => (color.g * 255).round().clamp(0, 255);

int _blue(material.Color color) => (color.b * 255).round().clamp(0, 255);

int _alpha(material.Color color) => (color.a * 255).round().clamp(0, 255);
