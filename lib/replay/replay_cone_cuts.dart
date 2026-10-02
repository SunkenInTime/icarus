import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/replay/replay_cone_worker.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

/// Where a player's view cone is aimed: everything its cut depends on.
@immutable
class ReplayConeAim {
  const ReplayConeAim({
    required this.origin,
    required this.rotation,
    required this.isAttack,
    this.elevationCm,
  });

  /// Canonical world units, where the cone's apex is drawn.
  final Offset origin;

  /// Canonical rotation, as a placed view cone stores it.
  final double rotation;
  final bool isAttack;
  final double? elevationCm;

  @override
  bool operator ==(Object other) =>
      other is ReplayConeAim &&
      other.origin == origin &&
      other.rotation == rotation &&
      other.isAttack == isAttack &&
      other.elevationCm == elevationCm;

  @override
  int get hashCode => Object.hash(origin, rotation, isAttack, elevationCm);
}

/// A finished cut: the [aim] it was made for, where the cone stands in
/// height-model space, and what it sees. Null [cone] means there is
/// nowhere to stand nearby.
class ReplayConeCut {
  const ReplayConeCut(this.id, this.aim, this.origin, this.cone);

  /// Different for every cut, so a cone knows when to redraw.
  final int id;
  final ReplayConeAim aim;
  final Offset? origin;
  final SvgVisibilityCone? cone;
}

/// The latest cut of each player's view cone, kept fresh by a
/// [ReplayConeWorker] while the UI thread draws. Each player has at most one
/// cut on its way; [want] asks for another once the player has moved. Cones
/// are drawn from their latest cut, carried along with their agent, so the
/// worker's pace sets how often walls are recut, never the frame rate.
class ReplayConeCuts {
  ReplayConeCuts({
    required this.worker,
    required this.map,
    required this.attackModel,
    required this.defenseModel,
    required this.coneLength,
    required this.apertureDegrees,
    required this.onCut,
  });

  final ReplayConeWorker worker;
  final MapValue map;

  /// For the reviewed-floor pass, which only the root isolate can run.
  final SvgHeightVisibility attackModel, defenseModel;

  /// The cones' length and spread, as the editor's view cones take them.
  final double coneLength, apertureDegrees;

  /// Called when a cut arrives, so a paused frame can show it.
  final VoidCallback onCut;

  final _latest = <String, ReplayConeCut>{};
  final _waiting = <String>{};
  var _nextId = 0;
  var _disposed = false;

  ReplayConeCut? latest(String subject) => _latest[subject];

  /// Asks for [subject]'s cone at [aim], unless its latest cut is already
  /// there or another is on its way.
  void want(String subject, ReplayConeAim aim) {
    if (_waiting.contains(subject) || _latest[subject]?.aim == aim) return;
    _waiting.add(subject);
    worker.cut(_request(aim)).then((result) {
      _waiting.remove(subject);
      if (_disposed) return;
      _latest[subject] = ReplayConeCut(
        _nextId++,
        aim,
        result.origin,
        _withFloors(aim, result),
      );
      onCut();
    }, onError: (Object _) {
      _waiting.remove(subject);
    });
  }

  /// The request the cone widget would make for [aim] itself.
  ReplayConeRequest _request(ReplayConeAim aim) {
    final coordinates = CoordinateSystem.instance;
    final transform = SvgHeightMapTransform.forMap(map);
    final side = coordinates.positionForSide(
      canonicalPosition: aim.origin,
      reflectionOffset: Offset.zero,
      isAttack: aim.isAttack,
    );
    final rotation =
        coordinates.rotationForSide(aim.rotation, isAttack: aim.isAttack);
    return ReplayConeRequest(
      isAttack: aim.isAttack,
      origin: transform.sourceFromSideWorld(side, isAttack: aim.isAttack),
      directionRadians: rotation - math.pi / 2,
      range:
          CoordinateSystem.virtualLengthInWorld(coneLength) / transform.scale,
      apertureRadians: apertureDegrees * math.pi / 180,
      elevationCm: aim.elevationCm,
    );
  }

  SvgVisibilityCone? _withFloors(ReplayConeAim aim, ReplayConeResult result) {
    final cone = result.cone;
    final origin = result.origin;
    final model = aim.isAttack ? attackModel : defenseModel;
    if (cone == null || origin == null || !model.hasSightlineFloors) {
      return cone;
    }
    final request = _request(aim);
    return model.withSightlineFloors(
      cone,
      origin: origin,
      directionRadians: request.directionRadians,
      range: request.range,
      apertureRadians: request.apertureRadians,
    );
  }

  void dispose() {
    _disposed = true;
    worker.dispose();
  }
}
