import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/fold.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

Map<String, Object?> liveContent(StrategyRowSet rows) => {
  for (final row in rows.rows)
    if (switch (row) {
      DeletedElement() || DeletedLineupGroup() => false,
      _ => true,
    })
      '${row.key}': switch (row.toJson()) {
        final Map<String, Object?> json => {
          for (final MapEntry(:key, :value) in json.entries)
            if (key != 'revision' && key != 'updatedAt') key: value,
        },
        final other => other,
      },
};

StrategyOp? opOver(StrategyRowSet rows, Random random, String opId) {
  final live = [
    for (final row in rows.elements)
      if (row is LiveElement) row,
  ];
  if (live.isEmpty) return null;
  final target = live[random.nextInt(live.length)];
  final payload = agentPayload(target.publicId, {
    ...target.payload.data,
    'position': {'dx': random.nextInt(50), 'dy': random.nextInt(50)},
  });
  return switch (random.nextInt(9)) {
    7 => ElementPatchOp(
      opId: opId,
      elementPublicId: target.publicId,
      expectedElementRevision: target.revision,
      payload: payload,
      sortIndex: random.nextInt(3),
      merge: FieldMerge(fields: ['position']),
    ),
    8 => ElementPatchOp(
      opId: opId,
      elementPublicId: target.publicId,
      expectedElementRevision: target.revision,
      payload: payload,
      sortIndex: random.nextInt(3),
      merge: FieldMerge(fields: ['position', placeField]),
    ),
    0 => ElementPatchOp(
      opId: opId,
      elementPublicId: target.publicId,
      expectedElementRevision: target.revision,
      payload: payload,
      sortIndex: random.nextInt(3),
    ),
    1 => ElementPatchOp(
      opId: opId,
      elementPublicId: target.publicId,
      expectedElementRevision: target.revision,
      payload: payload,
      sortIndex: target.sortIndex,
      merge: FieldMerge(fields: ['position']),
    ),
    2 => ElementReorderOp(
      opId: opId,
      elementPublicId: target.publicId,
      pagePublicId: target.pagePublicId,
      sortIndex: random.nextInt(3),
      expectedElementRevision: target.revision,
    ),
    3 => ElementDeleteOp(
      opId: opId,
      elementPublicId: target.publicId,
      pagePublicId: target.pagePublicId,
      expectedElementRevision: target.revision,
    ),
    4 => ElementPatchOp(
      opId: opId,
      elementPublicId: target.publicId,
      expectedElementRevision: target.revision,
      payload: payload,
      pagePublicId: 'page-b',
      sortIndex: 0,
    ),
    _ => ElementAddOp(
      opId: opId,
      elementPublicId: 'new-$opId',
      pagePublicId: 'page-a',
      payload: agentPayload('new-$opId', const {}),
      sortIndex: 0,
    ),
  };
}

StrategyOp? followUp(StrategyRowSet rows, Random random, StrategyOp first) {
  final id = switch (first) {
    ElementAddOp(:final elementPublicId) ||
    ElementPatchOp(:final elementPublicId) ||
    ElementReorderOp(:final elementPublicId) ||
    ElementDeleteOp(:final elementPublicId) => elementPublicId,
    _ => null,
  };
  if (id == null) return null;
  final focused = StrategyRowSet(
    strategy: rows.strategy,
    pages: rows.pages,
    settings: rows.settings,
    elements: [
      for (final row in rows.elements)
        if (row.publicId == id) row,
    ],
  );
  return opOver(focused, random, 'then');
}

void main() {
  test('every pair fold accepts gives the rows the two ops give in '
      'sequence', () {
    final random = Random(7);
    var checked = 0;
    final accepted = <String>{};
    for (var round = 0; round < 4000; round++) {
      final start = initialRows();
      final first = opOver(start, random, 'first');
      if (first == null) continue;
      final afterFirst = switch (applyOp(start, first)) {
        final OpApplied done => start.withRows(done.rows),
        _ => null,
      };
      if (afterFirst == null) continue;
      final then = followUp(afterFirst, random, first);
      if (then == null) continue;
      final inSequence = switch (applyOp(afterFirst, then)) {
        final OpApplied done => afterFirst.withRows(done.rows),
        OpUnchanged() => afterFirst,
        OpRefused() => null,
      };
      if (inSequence == null) continue;
      switch (fold(first, then)) {
        case FoldedOp(op: final folded):
          final once = switch (applyOp(start, folded)) {
            final OpApplied done => start.withRows(done.rows),
            OpUnchanged() => start,
            final OpRefused refused => fail(
              'folded ${first.type.wireName} + ${then.type.wireName} '
              'is refused: ${refused.refusal}',
            ),
          };
          expect(
            liveContent(once),
            liveContent(inSequence),
            reason: '${first.toJson()} then ${then.toJson()}',
          );
          accepted.add('${first.type.wireName}+${then.type.wireName}');
          checked++;
        case CancelsOut():
          expect(
            liveContent(start),
            liveContent(inSequence),
            reason: '${first.toJson()} then ${then.toJson()}',
          );
          accepted.add('${first.type.wireName}+${then.type.wireName} cancel');
          checked++;
        case KeptApart():
          break;
      }
    }
    expect(checked, greaterThan(200));
    expect(accepted, {
      'element.patch+element.patch',
      'element.add+element.patch',
      'element.add+element.delete cancel',
    });
  });

  test('a fold never happens into an entry that is held', () {
    final client = Client();
    client.edit(movePatch('first'));
    final attempt = client.claim(['first']);
    client.must(
      OpAnswered(
        attempt,
        const RejectedAnswer(
          'first',
          RejectionReason.revisionMismatch,
          NoServerCopy(),
        ),
      ),
    );
    client.edit(movePatch('second', expected: 2, x: 20));
    client.edit(movePatch('third', expected: 3, x: 30));
    expect(client.queue.entries.map((entry) => entry.id), [
      'first',
      'second',
      'third',
    ]);
  });
}
