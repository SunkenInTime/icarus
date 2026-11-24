import 'package:icarus_library/icarus_library.dart';

import 'cloud_support.dart';
import 'support.dart';

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
            if (key != 'revision' &&
                key != 'updatedAt' &&
                key != 'sortIndex' &&
                key != 'createdAt')
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
  int nextLife = addedLife;
  final heldIds = <String>{};

  Server copy() => Server()
    ..rows = rows
    ..exists = exists
    ..recorded.addAll(recorded)
    ..firstClient.addAll(firstClient)
    ..received = received
    ..sends = sends
    ..nextLife = nextLife
    ..heldIds.addAll(heldIds)
    ..appliedBeforePurge.addAll(appliedBeforePurge);

  final appliedBeforePurge = <String>{};

  void purgeAfterThirtyDays() {
    for (final opId in firstClient.keys) {
      if (landed(opId)) appliedBeforePurge.add(opId);
    }
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

  void create() {
    final life = nextLife++;
    rows = StrategyRowSet(
      strategy: strategyRow(
        revision: 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(life, isUtc: true),
      ),
      pages: [bornIn(page('p', sortIndex: 0, name: 'Page 1'), life) as PageRow],
      settings: [bornIn(settings('p'), life) as PageSettingsRow],
      elements: const [],
      lineupGroups: const [],
    );
  }

  List<QueueEvent> answer(String client, SendBatch batch) =>
      createdAtOf(rows.strategy) != batch.strategyLife
      ? [BatchRefused(batch.attempt, BatchRefusal.strategyReplaced)]
      : [
          for (final op in batch.ops)
            OpAnswered(
              batch.attempt,
              apply(client, op, expectedLife: batch.lives[op.opId]),
            ),
        ];

  void reupload() {
    heldIds.addAll([
      for (final row in rows.elements) row.publicId,
      for (final row in rows.lineupGroups) row.publicId,
    ]);
    rows = reuploaded(rows, nextLife++);
    recorded.clear();
    firstClient.clear();
  }

  ServerCopy currentOf(StrategyOp op) {
    final target = checkTargetOf(op);
    final row = switch (target) {
      StrategyTarget() => rows.strategy,
      PageTarget(:final pagePublicId) => rows.page(pagePublicId),
      SettingsTarget(:final pagePublicId) => rows.settingsOf(pagePublicId),
      ElementTarget(:final elementPublicId) => rows.element(elementPublicId),
      LineupTarget(:final lineupPublicId) => rows.lineupGroup(lineupPublicId),
    };
    final version = switch (row == null
        ? null
        : (createdAtOf(row), revisionOfRowForTest(row))) {
      (final life?, final revision?) => Version(life, revision),
      _ => null,
    };
    if (row == null || version == null || row is TrashedPage) {
      return const NoServerCopy();
    }
    final (kind, value) = switch (row) {
      ReadableStrategy(:final name, :final mapData) => (
        SnapshotTarget.strategy,
        <String, Object?>{'name': name, 'mapData': mapData},
      ),
      ReadablePageRow(:final name, :final sortIndex, :final isAttack) => (
        SnapshotTarget.page,
        <String, Object?>{
          'name': name,
          'sortIndex': sortIndex,
          'isAttack': isAttack,
        },
      ),
      ReadablePageSettings(:final settings) => (
        SnapshotTarget.pageContent,
        <String, Object?>{'settings': settings?.toJson()},
      ),
      ReadableElementRow(:final payload) => (
        SnapshotTarget.element,
        payload.toJson(),
      ),
      ReadableLineupGroupRow(:final payload) => (
        SnapshotTarget.lineup,
        payload.toJson(),
      ),
      _ => throw StateError('no copy of $row'),
    };
    return ServerSnapshot(
      target: kind,
      revision: version.revisionOnTheWire,
      life: version.lifeOnTheWire,
      value: value,
    );
  }

  void write(OpApplied done) => rows = rows.withRows([
    for (final row in done.rows) bornIn(row, nextLife++),
  ]);

  OpAnswer apply(String client, StrategyOp op, {int? expectedLife}) {
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
      case RecordedAnswer(answer: AppliedAnswer(:final revision, :final life)):
        return NoopAnswer(
          op.opId,
          revision: revision,
          replay: NoopReplay.appliedWhenFirstReceived,
          life: life,
        );
      case RecordedAnswer(answer: RejectedAnswer(:final reason)):
        return RejectedAnswer(op.opId, reason, currentOf(op));
      case RecordedAnswer(:final answer):
        return answer;
      case null:
        break;
    }
    final heldBy = switch (op) {
      ElementAddOp(:final elementPublicId)
          when heldIds.contains(elementPublicId) =>
        RejectionReason.elementStrategyMismatch,
      LineupGroupAddOp(:final lineupPublicId)
          when heldIds.contains(lineupPublicId) =>
        RejectionReason.lineupStrategyMismatch,
      ElementAddOp(:final elementPublicId, expectedElementRevision: _?)
          when rows.element(elementPublicId) == null =>
        RejectionReason.notFound,
      LineupGroupAddOp(:final lineupPublicId, expectedLineupRevision: _?)
          when rows.lineupGroup(lineupPublicId) == null =>
        RejectionReason.notFound,
      _ => null,
    };
    if (heldBy != null) {
      final refused = RejectedAnswer(op.opId, heldBy, const NoServerCopy());
      recorded[key] = RecordedAnswer(refused, applied: false);
      return refused;
    }
    if ((expectedLife, lifeOfCheckedRowForTest(rows, op)) case (
      final expected?,
      final life?,
    ) when expected != life) {
      final refused = RejectedAnswer(
        op.opId,
        RejectionReason.rowReplaced,
        currentOf(op),
      );
      recorded[key] = RecordedAnswer(refused, applied: false);
      return refused;
    }
    final OpAnswer answer;
    var applied = false;
    switch (applyOp(rows, op)) {
      case final OpApplied done:
        write(done);
        applied = true;
        answer = AppliedAnswer(
          op.opId,
          revision: visibleRevision(rows, op)!,
          life: lifeOfCheckedRowForTest(rows, op)!,
        );
      case OpUnchanged():
        final revision = visibleRevision(rows, op);
        answer = revision == null
            ? NoopWithoutRevision(op.opId)
            : NoopAnswer(
                op.opId,
                revision: revision,
                replay: NoopReplay.notApplied,
                life: lifeOfCheckedRowForTest(rows, op)!,
              );
      case OpRefused(refusal: Rejected(:final reason)):
        answer = RejectedAnswer(op.opId, reason, switch (reason) {
          RejectionReason.revisionMismatch ||
          RejectionReason.fieldConflict ||
          RejectionReason.mergeInvalid => currentOf(op),
          _ => const NoServerCopy(),
        });
      case OpRefused(refusal: Failed(:final code)):
        answer = FailedAnswer(op.opId, KnownFailure(code), code.wireName);
      case OpRefused(refusal: UnreadableTarget(:final key)):
        throw StateError('no unreadable rows here: $key');
    }
    recorded[key] = RecordedAnswer(answer, applied: applied);
    return answer;
  }

  bool landed(String opId) =>
      appliedBeforePurge.contains(opId) || _landedNow(opId);

  bool _landedNow(String opId) => switch (firstClient[opId]) {
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

StrategyRowSet reuploaded(StrategyRowSet rows, int life) {
  final born = jsonObject({'createdAt': life});
  final strategy = rows.strategy;
  return StrategyRowSet(
    strategy: ReadableStrategy(
      publicId: strategy.publicId,
      name: strategy.name,
      mapData: strategy.mapData,
      themeProfileId: strategy.themeProfileId,
      revision: rows.pages.whereType<LivePage>().length - 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(life, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(life, isUtc: true),
    ),
    pages: [
      for (final row in rows.pages)
        if (row is LivePage)
          LivePage(
            publicId: row.publicId,
            strategyPublicId: row.strategyPublicId,
            name: row.name,
            isAutoNamed: row.isAutoNamed,
            sortIndex: row.sortIndex,
            isAttack: row.isAttack,
            revision: 1,
            unknownFields: born,
          ),
    ],
    settings: [
      for (final row in rows.settings)
        if (row is ReadablePageSettings &&
            rows.page(row.pagePublicId) is LivePage)
          ReadablePageSettings(
            pagePublicId: row.pagePublicId,
            settings: row.settings,
            revision: 1,
            unknownFields: born,
          ),
    ],
    elements: const [],
    lineupGroups: const [],
  );
}
