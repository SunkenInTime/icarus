// Match-only metadata for strategies imported from Valorant match JSON.
//
// This intentionally does NOT change StrategyPage. Pages remain generic canvas
// state, and this data "extends" pages by referencing StrategyPage.id.

import 'dart:convert';

enum ValorantEventType {
  roundOverview,
  kill,
  note,
}

class ValorantMatchStrategyData {
  final int schemaVersion;

  final String matchId;
  final String riotMapId;
  final String allyTeamId;
  final String? povSubject;

  final List<ValorantMatchPlayer> players;
  final List<ValorantMatchRound> rounds;
  final List<ValorantPageMeta> pageMeta;

  const ValorantMatchStrategyData({
    this.schemaVersion = 2,
    required this.matchId,
    required this.riotMapId,
    required this.allyTeamId,
    this.povSubject,
    this.players = const [],
    this.rounds = const [],
    this.pageMeta = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'matchId': matchId,
      'riotMapId': riotMapId,
      'allyTeamId': allyTeamId,
      'povSubject': povSubject,
      'players': players.map((p) => p.toJson()).toList(),
      'rounds': rounds.map((r) => r.toJson()).toList(),
      'pageMeta': pageMeta.map((m) => m.toJson()).toList(),
    };
  }

  String toJsonString() {
    return jsonEncode(toJson());
  }

  static ValorantMatchStrategyData? tryFromJsonString(String? json) {
    if (json == null || json.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      return fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  static ValorantMatchStrategyData fromJson(Map<String, dynamic> json) {
    final playersJson = (json['players'] as List?) ?? const [];
    final roundsJson = (json['rounds'] as List?) ?? const [];
    final metaJson = (json['pageMeta'] as List?) ?? const [];

    return ValorantMatchStrategyData(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 2,
      matchId: (json['matchId'] as String?) ?? '',
      riotMapId: (json['riotMapId'] as String?) ?? '',
      allyTeamId: (json['allyTeamId'] as String?) ?? '',
      povSubject: json['povSubject'] as String?,
      players: [
        for (final p in playersJson)
          if (p is Map) ValorantMatchPlayer.fromJson(p.cast<String, dynamic>()),
      ],
      rounds: [
        for (final r in roundsJson)
          if (r is Map) ValorantMatchRound.fromJson(r.cast<String, dynamic>()),
      ],
      pageMeta: [
        for (final m in metaJson)
          if (m is Map) ValorantPageMeta.fromJson(m.cast<String, dynamic>()),
      ],
    );
  }
}

class ValorantMatchPlayer {
  final String subject;
  final String gameName;
  final String tagLine;
  final String teamId;
  final String characterId;

  const ValorantMatchPlayer({
    required this.subject,
    required this.gameName,
    required this.tagLine,
    required this.teamId,
    required this.characterId,
  });

  Map<String, dynamic> toJson() {
    return {
      'subject': subject,
      'gameName': gameName,
      'tagLine': tagLine,
      'teamId': teamId,
      'characterId': characterId,
    };
  }

  static ValorantMatchPlayer fromJson(Map<String, dynamic> json) {
    return ValorantMatchPlayer(
      subject: (json['subject'] as String?) ?? '',
      gameName: (json['gameName'] as String?) ?? '',
      tagLine: (json['tagLine'] as String?) ?? '',
      teamId: (json['teamId'] as String?) ?? '',
      characterId: (json['characterId'] as String?) ?? '',
    );
  }
}

class ValorantMatchRound {
  final int roundIndex;
  final String? winningTeamId;
  final String? winningTeamRole;
  final bool allyIsAttack;

  const ValorantMatchRound({
    required this.roundIndex,
    required this.allyIsAttack,
    this.winningTeamId,
    this.winningTeamRole,
  });

  Map<String, dynamic> toJson() {
    return {
      'roundIndex': roundIndex,
      'winningTeamId': winningTeamId,
      'winningTeamRole': winningTeamRole,
      'allyIsAttack': allyIsAttack,
    };
  }

  static ValorantMatchRound fromJson(Map<String, dynamic> json) {
    return ValorantMatchRound(
      roundIndex: (json['roundIndex'] as num?)?.toInt() ?? 0,
      winningTeamId: json['winningTeamId'] as String?,
      winningTeamRole: json['winningTeamRole'] as String?,
      allyIsAttack: (json['allyIsAttack'] as bool?) ?? true,
    );
  }
}

class ValorantPageMeta {
  final String pageId;
  final int roundIndex;
  final int orderInRound;
  final ValorantEventType type;

  final int? roundTimeMs;
  final int? gameTimeMs;

  final String? killerSubject;
  final String? victimSubject;
  final List<String> assistantSubjects;

  // Stored in CoordinateSystem normalized coordinate space.
  final double? killerX;
  final double? killerY;
  final double? victimX;
  final double? victimY;

  const ValorantPageMeta({
    required this.pageId,
    required this.roundIndex,
    required this.orderInRound,
    required this.type,
    this.roundTimeMs,
    this.gameTimeMs,
    this.killerSubject,
    this.victimSubject,
    this.assistantSubjects = const [],
    this.killerX,
    this.killerY,
    this.victimX,
    this.victimY,
  });

  Map<String, dynamic> toJson() {
    return {
      'pageId': pageId,
      'roundIndex': roundIndex,
      'orderInRound': orderInRound,
      'type': type.name,
      'roundTimeMs': roundTimeMs,
      'gameTimeMs': gameTimeMs,
      'killerSubject': killerSubject,
      'victimSubject': victimSubject,
      'assistantSubjects': assistantSubjects,
      'killerX': killerX,
      'killerY': killerY,
      'victimX': victimX,
      'victimY': victimY,
    };
  }

  static ValorantPageMeta fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String?;
    ValorantEventType? type;
    if (typeStr != null) {
      for (final t in ValorantEventType.values) {
        if (t.name == typeStr) {
          type = t;
          break;
        }
      }
    }
    final assistants = (json['assistantSubjects'] as List?) ?? const [];
    return ValorantPageMeta(
      pageId: (json['pageId'] as String?) ?? '',
      roundIndex: (json['roundIndex'] as num?)?.toInt() ?? 0,
      orderInRound: (json['orderInRound'] as num?)?.toInt() ?? 0,
      type: type ?? ValorantEventType.note,
      roundTimeMs: (json['roundTimeMs'] as num?)?.toInt(),
      gameTimeMs: (json['gameTimeMs'] as num?)?.toInt(),
      killerSubject: json['killerSubject'] as String?,
      victimSubject: json['victimSubject'] as String?,
      assistantSubjects: [
        for (final a in assistants)
          if (a is String) a,
      ],
      killerX: (json['killerX'] as num?)?.toDouble(),
      killerY: (json['killerY'] as num?)?.toDouble(),
      victimX: (json['victimX'] as num?)?.toDouble(),
      victimY: (json['victimY'] as num?)?.toDouble(),
    );
  }
}
