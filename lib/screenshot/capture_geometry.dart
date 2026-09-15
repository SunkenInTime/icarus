import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/height_runtime_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';

bool pageNeedsCaptureGeometry(StrategyPage page) =>
    page.agentData.any((agent) => agent is PlacedViewConeAgent) ||
    page.utilityData.any((utility) => UtilityData.isViewCone(utility.type)) ||
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
      final runtime = await container.read(provider.future);
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
    if (geometry?.isDirectHeight ?? false) {
      final runtimeProvider = heightRuntimeProvider(map);
      final runtimeLease = container.listen(runtimeProvider, (_, __) {});
      try {
        final runtime = await container.read(runtimeProvider.future);
        return CaptureGeometryLease(() {
          runtimeLease.close();
          subscription.close();
        }, runtime.waitIdle);
      } catch (_) {
        runtimeLease.close();
        rethrow;
      }
    }
    return CaptureGeometryLease(subscription.close, () async {});
  } catch (_) {
    subscription.close();
    rethrow;
  }
}

class CaptureGeometryLease {
  CaptureGeometryLease(this.close, this.waitForFrame);
  final void Function() close;
  final Future<void> Function() waitForFrame;
}
