import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class CustomCircleUtilityWidget extends ConsumerWidget {
  const CustomCircleUtilityWidget({
    super.key,
    required this.id,
    this.diameterMeters,
    this.colorValue,
    this.opacityPercent,
    this.mapScale,
    this.showCenterMarker = true,
  });

  final String? id;
  final double? diameterMeters;
  final int? colorValue;
  final int? opacityPercent;
  final double? mapScale;
  final bool showCenterMarker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coord = CoordinateSystem.instance;
    final utility = _getUtility(ref);
    final effectiveMapScale = mapScale ?? 1.0;

    final effectiveDiameterMeters = diameterMeters ?? utility?.customDiameter;
    final effectiveColorValue = colorValue ?? utility?.customColorValue;
    final effectiveOpacityPercent =
        opacityPercent ?? utility?.customOpacityPercent;
    final hasAllRequiredValues = effectiveDiameterMeters != null &&
        effectiveColorValue != null &&
        effectiveOpacityPercent != null;
    assert(
      hasAllRequiredValues,
      'CustomCircleUtilityWidget requires explicit diameter/color/opacity values.',
    );
    if (!hasAllRequiredValues) {
      if (kDebugMode) {
        debugPrint(
            'Skipping custom circle render due to missing explicit values (id: $id).');
      }
      return const SizedBox.shrink();
    }

    final color = Color(effectiveColorValue);
    final fillOpacity = (effectiveOpacityPercent / 100).clamp(0.0, 1.0);
    final diameterInVirtual = CustomCircleUtility.diameterInVirtual(
      diameterMeters: effectiveDiameterMeters,
      mapScale: effectiveMapScale,
    );
    final maxDiameterInVirtual =
        CustomCircleUtility.maxDiameterInVirtual(effectiveMapScale);
    final scaledDiameter = coord.scale(diameterInVirtual);
    final scaledMaxDiameter = coord.scale(maxDiameterInVirtual);
    final iconSize = coord.scale(Settings.utilityIconSize);

    return SizedBox(
      width: scaledMaxDiameter,
      height: scaledMaxDiameter,
      child: Stack(
        children: [
          Center(
            child: IgnorePointer(
              child: SizedBox(
                width: scaledDiameter,
                height: scaledDiameter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: fillOpacity),
                    border: Border.all(color: color, width: coord.scale(2)),
                  ),
                ),
              ),
            ),
          ),
          if (showCenterMarker)
            Center(
              child: MouseWatch(
                cursor: SystemMouseCursors.click,
                deleteTarget: (id?.isNotEmpty ?? false)
                    ? HoveredDeleteTarget.utility(id: id!, ownerToken: Object())
                    : null,
                child: Container(
                  width: iconSize * 0.8,
                  height: iconSize * 0.8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.9),
                    border:
                        Border.all(color: Colors.white, width: coord.scale(2)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  PlacedUtility? _getUtility(WidgetRef ref) {
    if (id == null) return null;
    try {
      return ref
          .watch(utilityProvider)
          .firstWhere((element) => element.id == id);
    } catch (_) {
      return null;
    }
  }
}
