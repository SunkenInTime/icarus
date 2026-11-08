import 'dart:math' as math;

import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/replay/replay_document.dart';

/// A Lotus door's spin. A move can end sooner, when a round's reset cuts it
/// short, but it turns at this pace.
const _spinMs = 10000;

/// How far a move from [startMs] to [endMs] has gone at [timeMs], 0 to 1.
double _progress(ReplayDoorMove move, int timeMs) => move.endMs > timeMs
    ? (timeMs - move.startMs) / (move.endMs - move.startMs)
    : 1.0;

/// What a replay's doors do over time on one map.
class ReplayDoors {
  ReplayDoors(ReplayDocument document, MapValue map)
      : _doors = mapDoorsOf(map),
        _moves = {
          for (final door in mapDoorsOf(map))
            door.id: [
              for (final move in document.doors)
                if (move.actor == door.replayActor) move,
            ],
        };

  final List<MapDoor> _doors;
  final Map<String, List<ReplayDoorMove>> _moves;

  /// The doors changed at [timeMs], in [round], by id, with how far: a wall
  /// drops or breaks towards 1 and stays there for the round, a door spins
  /// through 2, half a turn, then is at rest again, and a door shuts towards
  /// 1 and opens back towards 0. The round's latest move decides. A door at
  /// rest isn't listed, and a door caught moving counts as changed, since a
  /// saved door has two states.
  Map<String, double> at(int timeMs, ReplayRound? round) {
    if (_doors.isEmpty || round == null) return const {};
    final changed = <String, double>{};
    for (final door in _doors) {
      double? amount;
      for (final move in _moves[door.id]!) {
        if (move.startMs < round.startMs || move.startMs > timeMs) continue;
        amount = switch (door.kind) {
          // A move can run past the spin's 10 s, as one a recording's end
          // cuts off does; the door has still turned only half way.
          MapDoorKind.spin when timeMs <= move.endMs =>
            math.min(2.0, (timeMs - move.startMs) / _spinMs * 2),
          MapDoorKind.spin => null,
          MapDoorKind.drop => _progress(move, timeMs),
          MapDoorKind.breakable => 1.0,
          MapDoorKind.shutter when move.toRest => 1 - _progress(move, timeMs),
          MapDoorKind.shutter => _progress(move, timeMs),
        };
      }
      if (amount != null && amount > 0) changed[door.id] = amount;
    }
    return changed;
  }

  /// The doors cones cut against in [changed], as one number, a bit per door
  /// of the map, for the cone worker. A cone only knows a door's two poses,
  /// so a spinning door blocks as closed for the first and last quarter of
  /// its turn and side-on in between, the pose it's drawn nearer, and a
  /// shutting door blocks once it's half way down.
  int mask(Map<String, double> changed) {
    var mask = 0;
    for (var i = 0; i < _doors.length; i++) {
      final amount = changed[_doors[i].id];
      if (amount == null) continue;
      final open = switch (_doors[i].kind) {
        MapDoorKind.spin => amount >= 0.5 && amount < 1.5,
        MapDoorKind.shutter => amount >= 0.5,
        MapDoorKind.drop || MapDoorKind.breakable => true,
      };
      if (open) mask |= 1 << i;
    }
    return mask;
  }
}

/// The ids in [mask], as [ReplayDoors.mask] makes it.
Set<String> replayDoorsOfMask(List<String> doorIds, int mask) => {
      for (var i = 0; i < doorIds.length; i++)
        if (mask & (1 << i) != 0) doorIds[i],
    };
