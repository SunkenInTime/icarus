import 'package:flutter/material.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

ShadContextMenuItem buildViewConeElevationMenuItem({
  required VisionGeometryMap geometry,
  required double? selectedElevation,
  required double automaticElevation,
  required ValueChanged<double?> onChanged,
}) {
  return ShadContextMenuItem(
    leading: const Icon(LucideIcons.layers, size: 16),
    trailing: Text(
      selectedElevation == null
          ? 'Auto ${formatVisionElevation(automaticElevation)}'
          : formatVisionElevation(selectedElevation),
    ),
    items: [
      _elevationItem(
        label: 'Automatic (${formatVisionElevation(automaticElevation)})',
        selected: selectedElevation == null,
        onPressed: () => onChanged(null),
      ),
      for (final elevation in geometry.elevations)
        _elevationItem(
          label: formatVisionElevation(elevation),
          selected: selectedElevation != null &&
              (selectedElevation - elevation).abs() < 0.001,
          onPressed: () => onChanged(elevation),
        ),
    ],
    child: const Text('View elevation'),
  );
}

ShadContextMenuItem buildSvgHeightElevationMenuItem({
  required AppLocalizations l10n,
  required SvgHeightVisibility model,
  required Offset origin,
  required double? selectedElevationCm,
  required ValueChanged<double?> onChanged,
}) {
  final support =
      model.supportForAbsoluteEyeElevation(origin, selectedElevationCm);
  final choices = model
      .supportsAt(origin)
      .where((candidate) => candidate.surfaceElevationMeters != null)
      .toList(growable: false);
  final automatic = model.automaticSupportAt(origin);
  final groundEye = model.groundEyeElevationAt(origin);
  final groundSelected =
      model.isGroundEyeElevation(origin, selectedElevationCm);
  final unmatched =
      selectedElevationCm != null && support == null && !groundSelected;
  final automaticSelected = selectedElevationCm == null || unmatched;
  final automaticSurface =
      automatic?.label ?? l10n.canvasItemViewElevationGround;
  return ShadContextMenuItem(
    leading: const Icon(Icons.layers_outlined),
    trailing: Text(automaticSelected
        ? (unmatched
            ? l10n.canvasItemViewElevationAutoUnmatchedTrailing(
                automaticSurface)
            : l10n.canvasItemViewElevationAutoTrailing(automaticSurface))
        : support?.label ?? l10n.canvasItemViewElevationGround),
    items: [
      _elevationItem(
        label: unmatched
            ? l10n.canvasItemViewElevationAutomaticUnavailable
            : l10n.canvasItemViewElevationAutomatic(automaticSurface),
        selected: automaticSelected,
        onPressed: () => onChanged(null),
      ),
      if (groundEye != null && automatic != null)
        _elevationItem(
          label: l10n.canvasItemViewElevationGroundHeight(
              formatVisionElevation(groundEye * 100)),
          selected: groundSelected && !automaticSelected,
          onPressed: () => onChanged(groundEye * 100),
        ),
      for (final choice in choices)
        _elevationItem(
          label: l10n.canvasItemViewElevationSurfaceHeight(
              choice.label ?? choice.id,
              formatVisionElevation(choice.surfaceElevationAt(origin)! * 100 +
                  model.defaultCameraHeightMeters * 100)),
          selected: !automaticSelected && identical(choice, support),
          onPressed: () => onChanged(
            choice.surfaceElevationAt(origin)! * 100 +
                model.defaultCameraHeightMeters * 100,
          ),
        ),
    ],
    child: Text(l10n.canvasItemViewElevationMenu),
  );
}

String formatVisionElevation(double elevation) {
  final meters = elevation / 100;
  final wholeMeters = meters.roundToDouble() == meters;
  return '${meters >= 0 ? '+' : ''}'
      '${meters.toStringAsFixed(wholeMeters ? 0 : 2)} m';
}

ShadContextMenuItem buildViewConeDebugMenuItem({
  required bool enabled,
  required ValueChanged<bool> onChanged,
}) {
  return ShadContextMenuItem(
    leading: Icon(enabled ? LucideIcons.eye : LucideIcons.eyeOff, size: 16),
    trailing: Text(enabled ? 'On' : 'Off'),
    onPressed: () => onChanged(!enabled),
    child: const Text('Vision calibration'),
  );
}

ShadContextMenuItem _elevationItem({
  required String label,
  required bool selected,
  required VoidCallback onPressed,
}) {
  return ShadContextMenuItem(
    leading: Icon(
      selected ? LucideIcons.circleDot : LucideIcons.circle,
      size: 16,
    ),
    onPressed: onPressed,
    child: Text(label),
  );
}
