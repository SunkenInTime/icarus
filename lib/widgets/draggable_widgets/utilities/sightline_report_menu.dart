import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/view_cone/sightline_report.dart';
import 'package:icarus/view_cone/sightline_report_image.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// One click turns "this cone looks wrong" into everything we need to fix it:
/// the report on the clipboard, and the same report plus a crop on disk.
ShadContextMenuItem buildSightlineReportMenuItem({
  required MapValue map,
  required bool isAttack,
  required SvgHeightVisibility? model,
  required Offset canonicalOrigin,
  required double rotation,
  required double coneAngleDegrees,
  required double lengthVirtual,
  required double? visionElevationCm,
}) {
  return ShadContextMenuItem(
    leading: const Icon(Icons.bug_report_outlined),
    onPressed: () => copySightlineReport(
      map: map,
      isAttack: isAttack,
      model: model,
      canonicalOrigin: canonicalOrigin,
      rotation: rotation,
      coneAngleDegrees: coneAngleDegrees,
      lengthVirtual: lengthVirtual,
      visionElevationCm: visionElevationCm,
    ),
    child: const Text('Copy sightline report'),
  );
}

/// Copies first and saves after, so the toast never waits on the disk.
void copySightlineReport({
  required MapValue map,
  required bool isAttack,
  required SvgHeightVisibility? model,
  required Offset canonicalOrigin,
  required double rotation,
  required double coneAngleDegrees,
  required double lengthVirtual,
  required double? visionElevationCm,
}) {
  final coordinates = CoordinateSystem.instance;
  final transform = SvgHeightMapTransform.forMap(map);
  final sideOrigin = coordinates.positionForSide(
    canonicalPosition: canonicalOrigin,
    reflectionOffset: Offset.zero,
    isAttack: isAttack,
  );
  final svgOrigin =
      transform.sourceFromSideWorld(sideOrigin, isAttack: isAttack);
  final mapName = Maps.mapNames[map] ?? map.name;
  final SightlineReport report;
  final String encoded;
  try {
    report = buildSightlineReport(
      map: mapName,
      isAttack: isAttack,
      appVersion: Settings.versionName,
      canonicalOrigin: canonicalOrigin,
      svgOrigin: svgOrigin,
      facingRadians: rotation - math.pi / 2,
      apertureRadians: coneAngleDegrees * math.pi / 180,
      rangeSvg:
          coordinates.virtualLengthToWorld(lengthVirtual) / transform.scale,
      savedElevationCm: visionElevationCm,
      model: model,
    );
    // Encoded inside the guard: a value JSON cannot hold is a report problem,
    // and the user must hear it as one, not as a crash mid-gesture.
    encoded = report.encode();
  } catch (error, stack) {
    AppErrorReporter.reportError(
      'Could not build the sightline report.',
      error: error,
      stackTrace: stack,
      source: 'copySightlineReport.$mapName',
    );
    return;
  }

  unawaited(Clipboard.setData(ClipboardData(text: encoded)));
  Settings.showToast(
    message: 'Sightline report copied',
    backgroundColor: Settings.tacticalVioletTheme.primary,
  );

  unawaited(_saveSightlineReport(
    report: report,
    encoded: encoded,
    model: model,
    svgOrigin: svgOrigin,
    stem: sightlineReportFileStem(mapName, isAttack, DateTime.now()),
    label: '$mapName ${isAttack ? 'attack' : 'defense'} · eye '
        '${report.eyeElevationMeters?.toStringAsFixed(2) ?? '—'} m',
  ));
}

Future<void> _saveSightlineReport({
  required SightlineReport report,
  required String encoded,
  required SvgHeightVisibility? model,
  required Offset svgOrigin,
  required String stem,
  required String label,
}) async {
  try {
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}'
      '${Platform.pathSeparator}sightline-reports',
    );
    await directory.create(recursive: true);
    final path = '${directory.path}${Platform.pathSeparator}$stem';
    await File('$path.json').writeAsString(encoded);
    if (model == null) return;
    final crop = await renderSightlineReportCrop(
      model: model,
      origin: svgOrigin,
      visibility: report.visibleArea,
      eyeElevationMeters: report.eyeElevationMeters,
      label: label,
    );
    if (crop != null) await File('$path.png').writeAsBytes(crop);
  } catch (error, stack) {
    AppErrorReporter.reportError(
      'Sightline report copied, but its files could not be saved.',
      error: error,
      stackTrace: stack,
      source: 'copySightlineReport.save',
    );
  }
}
