import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// One decoded Valorant replay, read from the `.icrp` buffer that
/// `native/replay` writes. Facts only, in game units: no Icarus types appear
/// here. The format is specified in `docs/replay-format.md`.
class ReplayDocument {
  ReplayDocument._({
    required this.match,
    required this.players,
    required this.rounds,
    required this.kills,
    required this.utility,
    required this.casts,
    required this.vitals,
    required this.movement,
    required this.quality,
  });

  static const formatVersion = 1;
  static const _magic = [0x49, 0x43, 0x52, 0x50]; // "ICRP"

  final ReplayMatchInfo match;
  final List<ReplayPlayer> players;
  final List<ReplayRound> rounds;
  final List<ReplayKill> kills;
  final List<ReplayUtility> utility;
  final List<ReplayCast> casts;

  /// Health and armor per player, one row per change.
  final Map<String, ReplayVitalsTrack> vitals;
  final Map<String, ReplayMovementTrack> movement;
  final ReplayQuality quality;

  /// Reads a whole `.icrp` buffer. Throws [FormatException] when the bytes
  /// are not a decoded replay of [formatVersion].
  factory ReplayDocument.fromBytes(Uint8List bytes) {
    if (bytes.length < 12) {
      throw const FormatException('Decoded replay is truncated.');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        throw const FormatException('Not a decoded replay.');
      }
    }
    final header = ByteData.sublistView(bytes, 0, 12);
    final version = header.getUint32(4, Endian.little);
    if (version != formatVersion) {
      throw FormatException(
        'Decoded replay format $version is not '
        'supported (expected $formatVersion).',
      );
    }
    final jsonLength = header.getUint32(8, Endian.little);
    final jsonEnd = 12 + jsonLength;
    if (jsonEnd > bytes.length) {
      throw const FormatException('Decoded replay is truncated.');
    }
    final json =
        jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 12, jsonEnd)))
            as Map<String, dynamic>;
    final blobStart = (jsonEnd + 7) & ~7;
    final blob = blobStart <= bytes.length
        ? ByteData.sublistView(bytes, blobStart)
        : ByteData(0);
    return ReplayDocument._fromJson(json, blob);
  }

  factory ReplayDocument._fromJson(Map<String, dynamic> json, ByteData blob) {
    List<Map<String, dynamic>> list(String key) =>
        (json[key] as List? ?? const []).cast<Map<String, dynamic>>();

    final movementJson =
        (json['movement'] as Map? ?? const {}).cast<String, dynamic>();
    final vitalsJson =
        (json['vitals'] as Map? ?? const {}).cast<String, dynamic>();

    return ReplayDocument._(
      match: ReplayMatchInfo.fromJson(json['match'] as Map<String, dynamic>),
      players: [for (final p in list('players')) ReplayPlayer.fromJson(p)],
      rounds: [for (final r in list('rounds')) ReplayRound.fromJson(r)],
      kills: [for (final k in list('kills')) ReplayKill.fromJson(k)]
        ..sort((a, b) => a.timeMs.compareTo(b.timeMs)),
      utility: [for (final u in list('utility')) ReplayUtility.fromJson(u)]
        ..sort((a, b) => a.spawnMs.compareTo(b.spawnMs)),
      casts: [for (final c in list('casts')) ReplayCast.fromJson(c)]
        ..sort((a, b) => a.timeMs.compareTo(b.timeMs)),
      vitals: {
        for (final entry in vitalsJson.entries)
          entry.key: ReplayVitalsTrack.fromJson(entry.value as List),
      },
      movement: {
        for (final entry in movementJson.entries)
          entry.key: ReplayMovementTrack.fromBlob(
            blob,
            offset: (entry.value as Map)['offset'] as int,
            count: (entry.value as Map)['count'] as int,
          ),
      },
      quality: ReplayQuality.fromJson(
        json['quality'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  ReplayPlayer? playerBySubject(String? subject) {
    if (subject == null) return null;
    for (final player in players) {
      if (player.subject == subject) return player;
    }
    return null;
  }

  /// The round whose span holds [timeMs]; before the first round, the first.
  ReplayRound? roundAt(int timeMs) {
    ReplayRound? current;
    for (final round in rounds) {
      if (round.startMs > timeMs) break;
      current = round;
    }
    return current ?? (rounds.isEmpty ? null : rounds.first);
  }
}

/// Valorant's two teams as replicated.
enum ReplayTeam {
  red,
  blue;

  ReplayTeam get other => this == red ? blue : red;

  static ReplayTeam? tryParse(Object? value) => switch (value) {
        'Red' => red,
        'Blue' => blue,
        _ => null,
      };
}

class ReplayMatchInfo {
  const ReplayMatchInfo({
    required this.id,
    required this.mapPath,
    required this.build,
    required this.durationMs,
    this.recordedAt,
    this.gameMode,
  });

  final String id;
  final String mapPath;
  final String build;
  final int durationMs;
  final DateTime? recordedAt;
  final String? gameMode;

  factory ReplayMatchInfo.fromJson(Map<String, dynamic> json) =>
      ReplayMatchInfo(
        id: json['id'] as String,
        mapPath: json['mapPath'] as String,
        build: json['build'] as String,
        durationMs: json['durationMs'] as int,
        recordedAt: DateTime.tryParse(json['recordedAt'] as String? ?? ''),
        gameMode: json['gameMode'] as String?,
      );
}

class ReplayPlayer {
  const ReplayPlayer({
    required this.subject,
    required this.agentId,
    required this.team,
    this.name,
  });

  final String subject;

  /// valorant-api.com agent UUID.
  final String agentId;
  final ReplayTeam team;
  final String? name;

  factory ReplayPlayer.fromJson(Map<String, dynamic> json) => ReplayPlayer(
        subject: json['subject'] as String,
        agentId: (json['agentId'] as String).toLowerCase(),
        team: ReplayTeam.tryParse(json['team']) ??
            (throw FormatException('Player ${json['subject']} has no team.')),
        name: json['name'] as String?,
      );
}

enum ReplayRoundEnd { elimination, detonated, defused, time, surrender }

class ReplayRound {
  const ReplayRound({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.attackingTeam,
    this.combatStartMs,
    this.winningTeam,
    this.endReason,
    this.plant,
    this.defuse,
    this.detonateMs,
    this.economy = const [],
  });

  final int index;
  final int startMs;
  final int? combatStartMs;
  final int endMs;
  final ReplayTeam attackingTeam;
  final ReplayTeam? winningTeam;
  final ReplayRoundEnd? endReason;
  final ReplaySpikePlant? plant;
  final ReplaySpikeDefuse? defuse;
  final int? detonateMs;
  final List<ReplayEconomy> economy;

  /// When the round's play starts: barriers down if known, else round start.
  int get playStartMs => combatStartMs ?? startMs;

  bool contains(int timeMs) => timeMs >= startMs && timeMs < endMs;

  ReplayEconomy? economyFor(String subject) {
    for (final row in economy) {
      if (row.subject == subject) return row;
    }
    return null;
  }

  factory ReplayRound.fromJson(Map<String, dynamic> json) => ReplayRound(
        index: json['index'] as int,
        startMs: json['startMs'] as int,
        combatStartMs: json['combatStartMs'] as int?,
        endMs: json['endMs'] as int,
        attackingTeam: ReplayTeam.tryParse(json['attackingTeam']) ??
            (throw FormatException(
              'Round ${json['index']} has no attacking team.',
            )),
        winningTeam: ReplayTeam.tryParse(json['winningTeam']),
        endReason: ReplayRoundEnd.values
            .where((value) => value.name == json['endReason'])
            .firstOrNull,
        plant: json['plant'] == null
            ? null
            : ReplaySpikePlant.fromJson(json['plant'] as Map<String, dynamic>),
        defuse: json['defuse'] == null
            ? null
            : ReplaySpikeDefuse.fromJson(
                json['defuse'] as Map<String, dynamic>),
        detonateMs: json['detonateMs'] as int?,
        economy: [
          for (final row in (json['economy'] as List? ?? const []))
            ReplayEconomy.fromJson(row as Map<String, dynamic>),
        ],
      );
}

class ReplaySpikePlant {
  const ReplaySpikePlant({
    required this.timeMs,
    required this.position,
    this.site,
    this.subject,
  });

  final int timeMs;
  final ReplayVector position;
  final String? site;
  final String? subject;

  factory ReplaySpikePlant.fromJson(Map<String, dynamic> json) =>
      ReplaySpikePlant(
        timeMs: json['timeMs'] as int,
        position: ReplayVector.fromJson(json['position'] as List),
        site: json['site'] as String?,
        subject: json['subject'] as String?,
      );
}

class ReplaySpikeDefuse {
  const ReplaySpikeDefuse({required this.timeMs, this.subject});

  final int timeMs;
  final String? subject;

  factory ReplaySpikeDefuse.fromJson(Map<String, dynamic> json) =>
      ReplaySpikeDefuse(
        timeMs: json['timeMs'] as int,
        subject: json['subject'] as String?,
      );
}

class ReplayEconomy {
  const ReplayEconomy({
    required this.subject,
    required this.credits,
    required this.loadoutValue,
    this.weapon,
    this.armor,
  });

  final String subject;
  final int credits;
  final int loadoutValue;

  /// Equippable class path of the best weapon carried into the round.
  final String? weapon;

  /// Shield points bought: 25 or 50.
  final int? armor;

  factory ReplayEconomy.fromJson(Map<String, dynamic> json) => ReplayEconomy(
        subject: json['subject'] as String,
        credits: json['credits'] as int,
        loadoutValue: json['loadoutValue'] as int,
        weapon: json['weapon'] as String?,
        armor: json['armor'] as int?,
      );
}

class ReplayKill {
  const ReplayKill({
    required this.timeMs,
    required this.victim,
    this.killer,
    this.assists = const [],
    this.damageSource,
  });

  final int timeMs;
  final String victim;
  final String? killer;
  final List<String> assists;
  final String? damageSource;

  factory ReplayKill.fromJson(Map<String, dynamic> json) => ReplayKill(
        timeMs: json['timeMs'] as int,
        victim: json['victim'] as String,
        killer: json['killer'] as String?,
        assists: (json['assists'] as List? ?? const []).cast<String>(),
        damageSource: json['damageSource'] as String?,
      );
}

class ReplayUtility {
  const ReplayUtility({
    required this.id,
    required this.classPath,
    required this.spawnMs,
    required this.position,
    this.owner,
    this.endMs,
    this.yaw,
    this.path = const [],
    this.points = const [],
  });

  final int id;
  final String classPath;
  final String? owner;
  final int spawnMs;

  /// When the actor closed. Null means it lasted to the end of the replay.
  final int? endMs;
  final ReplayVector position;
  final double? yaw;

  /// Later replicated positions, for projectiles and moving utility.
  final List<ReplayPathPoint> path;

  /// Shape points, for walls and drawn paths.
  final List<ReplayVector> points;

  bool isActiveAt(int timeMs) =>
      timeMs >= spawnMs && (endMs == null || timeMs < endMs!);

  /// Where the utility is at [timeMs]: the last path point reached, else
  /// where it spawned.
  ReplayVector positionAt(int timeMs) {
    var current = position;
    for (final point in path) {
      if (point.timeMs > timeMs) break;
      current = point.position;
    }
    return current;
  }

  factory ReplayUtility.fromJson(Map<String, dynamic> json) => ReplayUtility(
        id: json['id'] as int,
        classPath: json['classPath'] as String,
        owner: json['owner'] as String?,
        spawnMs: json['spawnMs'] as int,
        endMs: json['endMs'] as int?,
        position: ReplayVector.fromJson(json['position'] as List),
        yaw: (json['yaw'] as num?)?.toDouble(),
        path: [
          for (final row in (json['path'] as List? ?? const []))
            ReplayPathPoint.fromJson(row as List),
        ],
        points: [
          for (final row in (json['points'] as List? ?? const []))
            ReplayVector.fromJson(row as List),
        ],
      );
}

class ReplayCast {
  const ReplayCast({
    required this.timeMs,
    required this.subject,
    required this.classPath,
    this.position,
  });

  final int timeMs;
  final String subject;
  final String classPath;
  final ReplayVector? position;

  factory ReplayCast.fromJson(Map<String, dynamic> json) => ReplayCast(
        timeMs: json['timeMs'] as int,
        subject: json['subject'] as String,
        classPath: json['classPath'] as String,
        position: json['position'] == null
            ? null
            : ReplayVector.fromJson(json['position'] as List),
      );
}

class ReplayQuality {
  const ReplayQuality({
    required this.transformVerified,
    required this.decodeErrors,
    this.warnings = const [],
  });

  final bool transformVerified;
  final int decodeErrors;
  final List<String> warnings;

  factory ReplayQuality.fromJson(Map<String, dynamic> json) => ReplayQuality(
        transformVerified: json['transformVerified'] as bool? ?? false,
        decodeErrors: json['decodeErrors'] as int? ?? 0,
        warnings: (json['warnings'] as List? ?? const []).cast<String>(),
      );
}

/// A point in game-world centimetres.
class ReplayVector {
  const ReplayVector(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  factory ReplayVector.fromJson(List json) => ReplayVector(
        (json[0] as num).toDouble(),
        (json[1] as num).toDouble(),
        (json[2] as num).toDouble(),
      );
}

class ReplayPathPoint {
  const ReplayPathPoint(this.timeMs, this.position);

  final int timeMs;
  final ReplayVector position;

  factory ReplayPathPoint.fromJson(List json) => ReplayPathPoint(
        json[0] as int,
        ReplayVector(
          (json[1] as num).toDouble(),
          (json[2] as num).toDouble(),
          (json[3] as num).toDouble(),
        ),
      );
}

/// A player's pose at one moment.
class ReplayPose {
  const ReplayPose({
    required this.position,
    required this.yaw,
    required this.pitch,
  });

  final ReplayVector position;
  final double yaw;
  final double pitch;
}

/// One player's movement, kept as the packed records from the blob.
class ReplayMovementTrack {
  ReplayMovementTrack._(this._records, this.length);

  static const _recordBytes = 24;

  /// Two samples further apart than this are separate stretches (a death, a
  /// round reset): no pose is invented between them.
  static const maxInterpolationGapMs = 500;

  final ByteData _records;
  final int length;

  factory ReplayMovementTrack.fromBlob(
    ByteData blob, {
    required int offset,
    required int count,
  }) {
    final end = offset + count * _recordBytes;
    if (offset < 0 || count < 0 || end > blob.lengthInBytes) {
      throw const FormatException('Movement record range is out of bounds.');
    }
    return ReplayMovementTrack._(
      ByteData.sublistView(blob, offset, end),
      count,
    );
  }

  int timeAt(int index) =>
      _records.getInt32(index * _recordBytes, Endian.little);

  double _f32(int index, int field) =>
      _records.getFloat32(index * _recordBytes + 4 + field * 4, Endian.little);

  ReplayPose poseAtIndex(int index) => ReplayPose(
        position: ReplayVector(_f32(index, 0), _f32(index, 1), _f32(index, 2)),
        yaw: _f32(index, 3),
        pitch: _f32(index, 4),
      );

  /// Index of the last sample at or before [timeMs], or -1.
  int indexAtOrBefore(int timeMs) {
    var low = 0;
    var high = length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (timeAt(mid) <= timeMs) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  /// The pose at [timeMs], interpolated between the samples around it.
  /// Null outside the track or inside a gap longer than
  /// [maxInterpolationGapMs].
  ReplayPose? poseAt(int timeMs) {
    final before = indexAtOrBefore(timeMs);
    if (before < 0) return null;
    final beforeTime = timeAt(before);
    if (before == length - 1) {
      return timeMs - beforeTime <= maxInterpolationGapMs
          ? poseAtIndex(before)
          : null;
    }
    final afterTime = timeAt(before + 1);
    final span = afterTime - beforeTime;
    if (span > maxInterpolationGapMs) {
      return timeMs - beforeTime <= maxInterpolationGapMs
          ? poseAtIndex(before)
          : null;
    }
    final a = poseAtIndex(before);
    final b = poseAtIndex(before + 1);
    final t = span == 0 ? 0.0 : (timeMs - beforeTime) / span;
    double lerp(double from, double to) => from + (to - from) * t;
    return ReplayPose(
      position: ReplayVector(
        lerp(a.position.x, b.position.x),
        lerp(a.position.y, b.position.y),
        lerp(a.position.z, b.position.z),
      ),
      yaw: a.yaw + _shortestAngle(a.yaw, b.yaw) * t,
      pitch: lerp(a.pitch, b.pitch),
    );
  }

  static double _shortestAngle(double from, double to) {
    final delta = (to - from) % 360;
    return delta > 180 ? delta - 360 : delta;
  }
}

/// A player's health and armor, one row per change.
class ReplayVitalsTrack {
  ReplayVitalsTrack._(this._times, this._health, this._armor);

  final Int32List _times;
  final Float32List _health;
  final Float32List _armor;

  factory ReplayVitalsTrack.fromJson(List rows) {
    final times = Int32List(rows.length);
    final health = Float32List(rows.length);
    final armor = Float32List(rows.length);
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i] as List;
      times[i] = row[0] as int;
      health[i] = (row[1] as num).toDouble();
      armor[i] = (row[2] as num).toDouble();
    }
    return ReplayVitalsTrack._(times, health, armor);
  }

  /// Health and armor as of [timeMs], or null before the first row.
  ({double health, double armor})? at(int timeMs) {
    var low = 0;
    var high = _times.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_times[mid] <= timeMs) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (found < 0) return null;
    return (
      health: math.max(0.0, _health[found]),
      armor: math.max(0.0, _armor[found]),
    );
  }
}
