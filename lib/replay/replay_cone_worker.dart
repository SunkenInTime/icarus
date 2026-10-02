import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';

/// One view cone to cut, in a side's height-model space.
class ReplayConeRequest {
  const ReplayConeRequest({
    required this.isAttack,
    required this.origin,
    required this.directionRadians,
    required this.range,
    required this.apertureRadians,
    this.elevationCm,
  });

  final bool isAttack;

  /// Where the agent stands; the worker moves it out of wall ink first, as
  /// the cone widget does.
  final Offset origin;
  final double directionRadians, range, apertureRadians;

  /// The saved eye height choosing the level, as on a placed agent.
  final double? elevationCm;
}

/// A cut cone: where it stands (after any nudge out of wall ink) and what
/// it sees there by a horizontal sightline. Null [origin] means there is
/// nowhere to stand nearby and no cone to draw.
class ReplayConeResult {
  const ReplayConeResult(this.origin, this.cone);

  final Offset? origin;
  final SvgVisibilityCone? cone;
}

/// Cuts view cones against a map's walls on a worker isolate, so replay
/// playback keeps the UI thread for drawing. The worker holds its own copy
/// of both sides' height models (and its own native acceleration); it
/// answers in the order asked.
///
/// The cut is [SvgHeightVisibility.horizontalCone]. Where a map overlooks
/// reviewed floors (`withSightlineFloors`), that pass uses `dart:ui` paths
/// and is left to the caller on the root isolate.
class ReplayConeWorker {
  ReplayConeWorker._(this._isolate, this._requests, this._responses);

  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _responses;
  final _pending = <int, Completer<ReplayConeResult>>{};
  var _nextTicket = 0;
  var _closed = false;

  /// Starts a worker on the gzip-compressed height models of a map's two
  /// sides, as bundled.
  static Future<ReplayConeWorker> start({
    required Uint8List attackModel,
    required Uint8List defenseModel,
  }) async {
    final responses = ReceivePort();
    final ready = Completer<SendPort>();
    late final ReplayConeWorker worker;
    responses.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is List && message.length == 2) {
        worker._answer(message[0] as int, message[1]);
      } else if (message is List && message.length == 3) {
        // [error, stack, ticket]: a bad request, not a dead worker.
        worker._fail(message[2] as int?, message[0] as String);
      }
    });
    final isolate = await Isolate.spawn(
      _workerMain,
      (
        responses.sendPort,
        TransferableTypedData.fromList([attackModel]),
        TransferableTypedData.fromList([defenseModel]),
      ),
      errorsAreFatal: false,
      debugName: 'replay cone worker',
    );
    worker = ReplayConeWorker._(isolate, await ready.future, responses);
    return worker;
  }

  /// Cuts [request]'s cone.
  Future<ReplayConeResult> cut(ReplayConeRequest request) {
    if (_closed) return Future.error(StateError('Cone worker is closed.'));
    final ticket = _nextTicket++;
    final completer = Completer<ReplayConeResult>();
    _pending[ticket] = completer;
    _requests.send(Float64List.fromList([
      ticket.toDouble(),
      request.isAttack ? 1 : 0,
      request.origin.dx,
      request.origin.dy,
      request.directionRadians,
      request.range,
      request.apertureRadians,
      request.elevationCm ?? double.nan,
    ]));
    return completer.future;
  }

  void _answer(int ticket, Object? payload) {
    final completer = _pending.remove(ticket);
    if (completer == null) return;
    if (payload is! Float64List) {
      completer.complete(const ReplayConeResult(null, null));
      return;
    }
    // [originX, originY, eyeAboveFloor, eyeElevation, x0, y0, x1, y1, ...]
    final polygon = [
      for (var i = 4; i + 1 < payload.length; i += 2)
        Offset(payload[i], payload[i + 1]),
    ];
    completer.complete(ReplayConeResult(
      Offset(payload[0], payload[1]),
      SvgVisibilityCone(
        polygon,
        payload[2],
        const SvgVisibilityStats(0, 0, 0, 0, 0),
        eyeElevationMeters: payload[3].isNaN ? null : payload[3],
      ),
    ));
  }

  void _fail(int? ticket, String error) {
    final completer = ticket == null ? null : _pending.remove(ticket);
    completer?.completeError(StateError(error));
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _responses.close();
    for (final completer in _pending.values) {
      completer.completeError(StateError('Cone worker is closed.'));
    }
    _pending.clear();
  }
}

SvgHeightVisibility _model(TransferableTypedData bytes) {
  final model = SvgHeightVisibility.fromJson(jsonDecode(
          utf8.decode(decodeWorldGzip(bytes.materialize().asUint8List())))
      as Map<String, dynamic>);
  model.enableNativeAcceleration();
  return model;
}

void _workerMain(
    (SendPort, TransferableTypedData, TransferableTypedData) setup) {
  final (replies, attackBytes, defenseBytes) = setup;
  final attack = _model(attackBytes);
  final defense = _model(defenseBytes);
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  requests.listen((message) {
    final request = message as Float64List;
    final ticket = request[0].toInt();
    try {
      final model = request[1] == 1 ? attack : defense;
      final standing = model.standablePointNear(Offset(request[2], request[3]));
      if (standing == null) {
        replies.send([ticket, null]);
        return;
      }
      final elevation = request[7];
      final support = model.standingSupportAt(standing,
          savedEyeElevationCm: elevation.isNaN ? null : elevation);
      final cone = model.horizontalCone(
        origin: standing,
        directionRadians: request[4],
        range: request[5],
        apertureRadians: request[6],
        supportId: support?.id,
      );
      final polygon = cone.polygon;
      final payload = Float64List(4 + polygon.length * 2)
        ..[0] = standing.dx
        ..[1] = standing.dy
        ..[2] = cone.eyeHeightAboveFloorMeters
        ..[3] = cone.eyeElevationMeters ?? double.nan;
      for (var i = 0; i < polygon.length; i++) {
        payload[4 + i * 2] = polygon[i].dx;
        payload[5 + i * 2] = polygon[i].dy;
      }
      replies.send([ticket, payload]);
    } catch (error, stack) {
      replies.send(['$error', '$stack', ticket]);
    }
  });
}
