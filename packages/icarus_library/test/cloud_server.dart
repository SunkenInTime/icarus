import 'package:icarus_library/icarus_library.dart';

import 'cloud_support.dart';

sealed class ServerRecord {
  const ServerRecord();
}

final class RecordedAnswer extends ServerRecord {
  const RecordedAnswer(this.answer, {required this.applied});

  final OpAnswer answer;
  final bool applied;
}

Map<String, Object?> liveContent(StrategyRowSet rows) => {
  for (final row in rows.rows)
    if (switch (row) {
      DeletedElement() || DeletedLineupGroup() => false,
      _ => true,
    })
      '${row.key}': switch (row.toJson()) {
        final Map<String, Object?> json => {
          for (final MapEntry(:key, :value) in json.entries)
            if (key != 'revision' && key != 'updatedAt' && key != 'sortIndex')
              key: value,
        },
        final other => other,
      },
};

StrategyRowSet withoutPage(StrategyRowSet rows, String pageId) =>
    StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages.where((page) => page.publicId != pageId),
      settings: rows.settings.where((row) => row.pagePublicId != pageId),
      elements: rows.elements.where((row) => row.pagePublicId != pageId),
      lineupGroups: rows.lineupGroups.where(
        (row) => row.pagePublicId != pageId,
      ),
    );

final class Server {
  StrategyRowSet rows = initialRows();
  bool exists = true;
  final recorded = <String, ServerRecord>{};
  final firstClient = <String, String>{};
  int received = 0;
  int sends = 0;

  Server copy() => Server()
    ..rows = rows
    ..exists = exists
    ..recorded.addAll(recorded)
    ..firstClient.addAll(firstClient)
    ..received = received
    ..sends = sends;

  void purgeAfterThirtyDays() {
    recorded.clear();
    firstClient.clear();
    rows = StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: [
        for (final row in rows.elements)
          if (row is! DeletedElement) row,
      ],
      lineupGroups: [
        for (final row in rows.lineupGroups)
          if (row is! DeletedLineupGroup) row,
      ],
    );
  }

  OpAnswer apply(String client, StrategyOp op) {
    sends++;
    final owner = firstClient.putIfAbsent(op.opId, () {
      received++;
      return client;
    });
    if (owner != client) {
      throw StateError('${op.opId} was sent under $owner and $client');
    }
    final key = '$client|${op.opId}';
    switch (recorded[key]) {
      case RecordedAnswer(answer: AppliedAnswer(:final revision)):
        return NoopAnswer(
          op.opId,
          revision: revision,
          replay: NoopReplay.appliedWhenFirstReceived,
        );
      case RecordedAnswer(:final answer):
        return answer;
      case null:
        break;
    }
    final OpAnswer answer;
    var applied = false;
    switch (applyOp(rows, op)) {
      case final OpApplied done:
        rows = rows.withRows(done.rows);
        applied = true;
        answer = AppliedAnswer(op.opId, revision: visibleRevision(rows, op)!);
      case OpUnchanged():
        final revision = visibleRevision(rows, op);
        answer = revision == null
            ? NoopWithoutRevision(op.opId)
            : NoopAnswer(
                op.opId,
                revision: revision,
                replay: NoopReplay.notApplied,
              );
      case OpRefused(refusal: Rejected(:final reason)):
        answer = RejectedAnswer(op.opId, reason, const NoServerCopy());
      case OpRefused(refusal: Failed(:final code)):
        answer = FailedAnswer(op.opId, KnownFailure(code), code.wireName);
      case OpRefused(refusal: UnreadableTarget(:final key)):
        throw StateError('no unreadable rows here: $key');
    }
    recorded[key] = RecordedAnswer(answer, applied: applied);
    return answer;
  }

  bool landed(String opId) => switch (firstClient[opId]) {
    final client? => switch (recorded['$client|$opId']) {
      RecordedAnswer(:final applied) => applied,
      null => false,
    },
    null => false,
  };

  bool refused(String opId) => switch (firstClient[opId]) {
    final client? => switch (recorded['$client|$opId']) {
      RecordedAnswer(answer: RejectedAnswer() || FailedAnswer()) => true,
      _ => false,
    },
    null => false,
  };
}
