import 'package:flutter/material.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
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
