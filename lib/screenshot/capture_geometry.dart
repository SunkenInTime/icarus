import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/services/app_assets.dart';

bool pageNeedsCaptureGeometry(StrategyPage page) =>
    page.agentData.any((agent) => agent is PlacedViewConeAgent) ||
    page.utilityData.any((utility) => UtilityData.isViewCone(utility.type)) ||
    // A rectangle is cut to the map's floor, which comes from the same model.
    page.utilityData
        .any((utility) => utility.type == UtilityType.customRectangle) ||
    page.abilityData.any((ability) =>
        ability.visualState.showVisionCone &&
        AbilityVisionConeSpec.forAbility(ability.data) != null);

/// Waits for sightlines before the first PNG or video frame, and keeps them
/// loaded across video pages that temporarily contain no cone widgets.
/// Close the returned subscription after the last capture.
Future<CaptureGeometryLease?> prepareCaptureGeometry(
  ProviderContainer container,
  MapValue map,
  Iterable<StrategyPage> pages,
) async {
  if (!pages.any(pageNeedsCaptureGeometry)) return null;
  if (hasSvgHeightRuntime(map) &&
      container.read(worldGeometryEnabledProvider(map))) {
    final provider = svgHeightRuntimeProvider(map);
    final subscription = container.listen(provider, (_, __) {});
    try {
      final runtime = await _stopIfFilesGoMissing(
        container.read(provider.future),
        map,
      );
      if (runtime == null) {
        throw StateError('Sightline geometry is unavailable for ${map.name}.');
      }
      return CaptureGeometryLease(subscription.close, () async {});
    } catch (_) {
      subscription.close();
      rethrow;
    }
  }
  final provider = viewConeGeometryProvider(map);
  final subscription = container.listen(provider, (_, __) {});
  try {
    final geometry = await container.read(provider.future);
    if (container.read(worldGeometryEnabledProvider(map)) && geometry == null) {
      throw StateError('Sightline geometry is unavailable for ${map.name}.');
    }
    return CaptureGeometryLease(subscription.close, () async {});
  } catch (_) {
    subscription.close();
    rethrow;
  }
}

/// The read behind sightlines waits for the connection, so a capture watches
/// for one of their files failing, or it would wait as long as the user is
/// offline. A slow connection isn't a failure, so there's no time limit.
Future<T> _stopIfFilesGoMissing<T>(Future<T> work, MapValue map) {
  final registration = svgHeightRegistrationFor(map)!;
  final files = {
    for (final isAttack in [true, false]) ...[
      registration.modelAsset(isAttack),
      registration.artworkAsset(isAttack),
    ],
  };
  final stopped = Completer<T>();
  void check() {
    if (!stopped.isCompleted && appAssets.missing.value.any(files.contains)) {
      stopped.completeError(
        const CaptureImagesUnavailable.fetchFailed(
          'Sightlines have not loaded.',
        ),
      );
    }
  }

  appAssets.missing.addListener(check);
  check();
  return Future.any([work, stopped.future]).whenComplete(() {
    appAssets.missing.removeListener(check);
  });
}

class CaptureGeometryLease {
  CaptureGeometryLease(this.close, this.waitForFrame);
  final void Function() close;
  final Future<void> Function() waitForFrame;
}
