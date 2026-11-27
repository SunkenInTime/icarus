import 'dart:convert';

import 'results.dart';

sealed class Migration {
  const Migration();
}

final class MigrationNotStarted extends Migration {
  const MigrationNotStarted();
}

final class MigrationUnreadable extends Migration {
  const MigrationUnreadable(this.problem);

  final String problem;
}

sealed class RecordedMigration extends Migration {
  const RecordedMigration();
}

final class MigrationCopying extends RecordedMigration {
  const MigrationCopying(this.startedAt);

  final DateTime startedAt;
}

final class MigrationFinished extends RecordedMigration {
  MigrationFinished({
    required this.startedAt,
    required this.finishedAt,
    required List<LeftBehind> strategies,
    required List<LeftBehind> folders,
    this.leftBehindClosed = false,
  }) : strategies = List.unmodifiable(strategies),
       folders = List.unmodifiable(folders);

  final DateTime startedAt;
  final DateTime finishedAt;
  final List<LeftBehind> strategies;
  final List<LeftBehind> folders;
  final bool leftBehindClosed;

  MigrationFinished closedLeftBehind() => MigrationFinished(
    startedAt: startedAt,
    finishedAt: finishedAt,
    strategies: strategies,
    folders: folders,
    leftBehindClosed: true,
  );
}

final class LeftBehind {
  const LeftBehind(this.publicId, this.name, this.reason);

  final String publicId;
  final String name;
  final String reason;
}

typedef MigrationRecordResult = Saving<RecordedMigration, Never>;

String migrationToJson(RecordedMigration migration) =>
    jsonEncode(switch (migration) {
      MigrationCopying(:final startedAt) => {
        'state': 'copying',
        'startedAt': startedAt.toUtc().microsecondsSinceEpoch,
      },
      MigrationFinished(
        :final startedAt,
        :final finishedAt,
        :final strategies,
        :final folders,
        :final leftBehindClosed,
      ) =>
        {
          'state': 'finished',
          'startedAt': startedAt.toUtc().microsecondsSinceEpoch,
          'finishedAt': finishedAt.toUtc().microsecondsSinceEpoch,
          'strategies': [for (final left in strategies) _leftToJson(left)],
          'folders': [for (final left in folders) _leftToJson(left)],
          'leftBehindClosed': leftBehindClosed,
        },
    });

Map<String, Object?> _leftToJson(LeftBehind left) => {
  'id': left.publicId,
  'name': left.name,
  'reason': left.reason,
};

Migration migrationFromText(String text) {
  try {
    return switch (jsonDecode(text)) {
      {'state': 'copying', 'startedAt': final int startedAt} =>
        MigrationCopying(_time(startedAt)),
      {
        'state': 'finished',
        'startedAt': final int startedAt,
        'finishedAt': final int finishedAt,
        'strategies': final List<Object?> strategies,
        'folders': final List<Object?> folders,
        'leftBehindClosed': final bool leftBehindClosed,
      } =>
        MigrationFinished(
          startedAt: _time(startedAt),
          finishedAt: _time(finishedAt),
          strategies: [for (final left in strategies) _leftFromJson(left)],
          folders: [for (final left in folders) _leftFromJson(left)],
          leftBehindClosed: leftBehindClosed,
        ),
      _ => const MigrationUnreadable('not a migration record'),
    };
  } on FormatException catch (error) {
    return MigrationUnreadable(error.message);
  } on ArgumentError catch (error) {
    return MigrationUnreadable('${error.message}');
  }
}

DateTime _time(int microseconds) =>
    DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);

LeftBehind _leftFromJson(Object? json) => switch (json) {
  {
    'id': final String id,
    'name': final String name,
    'reason': final String reason,
  } =>
    LeftBehind(id, name, reason),
  _ => throw const FormatException('a left-behind entry is unreadable'),
};
