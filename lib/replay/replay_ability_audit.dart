import 'package:flutter/material.dart';

enum ReplayAbilityAuditTargetType { abilityCast, utilityActor }

class ReplayAbilityAuditTarget {
  const ReplayAbilityAuditTarget({
    required this.type,
    required this.id,
    required this.label,
    this.evidence = const <String, dynamic>{},
  });

  final ReplayAbilityAuditTargetType type;
  final String id;
  final String label;

  /// Parser evidence captured when the user selected the rendered target.
  ///
  /// This is deliberately carried by the selection instead of looked up again
  /// when an annotation is exported. Replay parsing will keep evolving; an
  /// audit must continue to describe the exact interpretation the user saw.
  final Map<String, dynamic> evidence;

  bool matches(ReplayAbilityAuditTargetType otherType, String otherId) =>
      type == otherType && id == otherId;

  Map<String, dynamic> snapshotEvidence() => _snapshotJsonMap(evidence);
}

enum ReplayAbilityAuditIssue {
  correct,
  missing,
  wrongAbility,
  falsePositive,
  wrongPosition,
  startsEarlier,
  startsLater,
  endsEarlier,
  endsLater,
  customNote,
}

extension ReplayAbilityAuditIssueLabel on ReplayAbilityAuditIssue {
  String get label => switch (this) {
        ReplayAbilityAuditIssue.correct => 'Looks correct',
        ReplayAbilityAuditIssue.missing => 'Missing ability',
        ReplayAbilityAuditIssue.wrongAbility => 'Wrong ability',
        ReplayAbilityAuditIssue.falsePositive => 'Should not exist',
        ReplayAbilityAuditIssue.wrongPosition => 'Wrong position',
        ReplayAbilityAuditIssue.startsEarlier => 'Starts earlier',
        ReplayAbilityAuditIssue.startsLater => 'Starts later',
        ReplayAbilityAuditIssue.endsEarlier => 'Ends earlier',
        ReplayAbilityAuditIssue.endsLater => 'Ends later',
        ReplayAbilityAuditIssue.customNote => 'Custom note',
      };

  String get jsonValue => name;

  bool get needsMapPoint =>
      this == ReplayAbilityAuditIssue.missing ||
      this == ReplayAbilityAuditIssue.wrongPosition;
}

class ReplayAbilityAuditEntry {
  const ReplayAbilityAuditEntry({
    required this.id,
    required this.issue,
    required this.timeMs,
    this.castId,
    this.targetType,
    this.targetId,
    this.parsedLabel,
    this.targetEvidence,
    this.icarusPosition,
    this.note,
  });

  final String id;
  final ReplayAbilityAuditIssue issue;
  final int timeMs;
  final String? castId;
  final ReplayAbilityAuditTargetType? targetType;
  final String? targetId;
  final String? parsedLabel;

  /// Immutable-at-annotation-time evidence for [targetId].
  ///
  /// Older audit entries do not have this field, so it remains optional in the
  /// JSON schema for backwards compatibility.
  final Map<String, dynamic>? targetEvidence;
  final Offset? icarusPosition;
  final String? note;

  Map<String, dynamic> toJson() => {
        'id': id,
        'issue': issue.jsonValue,
        'timeMs': timeMs,
        if (castId != null) 'castId': castId,
        if (targetType != null) 'targetType': targetType!.name,
        if (targetId != null) 'targetId': targetId,
        if (parsedLabel != null) 'parsedLabel': parsedLabel,
        if (targetEvidence != null)
          'targetEvidence': _snapshotJsonMap(targetEvidence!),
        if (note != null) 'note': note,
        if (icarusPosition != null)
          'icarusPosition': {
            'x': icarusPosition!.dx,
            'y': icarusPosition!.dy,
          },
      };
}

Map<String, dynamic> _snapshotJsonMap(Map<String, dynamic> source) {
  return Map<String, dynamic>.unmodifiable({
    for (final entry in source.entries)
      entry.key: _snapshotJsonValue(entry.value),
  });
}

dynamic _snapshotJsonValue(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        entry.key.toString(): _snapshotJsonValue(entry.value),
    });
  }
  if (value is Iterable) {
    return List<dynamic>.unmodifiable(value.map(_snapshotJsonValue));
  }
  return value;
}
