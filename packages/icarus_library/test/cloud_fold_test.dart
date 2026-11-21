import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/fold.dart';
import 'package:icarus_library/src/json.dart';
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

int stamp = 0;

const drawnFields = ['position', 'rotation', 'scale'];

FieldMerge mergeOf(Random random, LiveElement target, {required bool base}) {
  final fields = [
    for (final field in drawnFields)
      if (random.nextBool()) field,
    if (random.nextInt(4) == 0) placeField,
  ];
  if (fields.isEmpty) fields.add(drawnFields[random.nextInt(3)]);
  final data = target.payload.data;
  return FieldMerge(
    fields: fields,
    base: base
        ? {
            for (final field in fields)
              if (field == placeField)
                field: target.sortIndex
              else if (data.containsKey(field))
                field: plainJson(data[field]),
          }
        : null,
  );
}

StrategyOp? opOver(StrategyRowSet rows, Random random, String opId) {
  final live = [
    for (final row in rows.elements)
      if (row is LiveElement) row,
  ];
  if (live.isEmpty) return null;
  final target = live[random.nextInt(live.length)];
  final payload = agentPayload(target.publicId, {
    ...target.payload.data.toJson(),
    'position': {'dx': random.nextInt(50), 'dy': random.nextInt(50)},
    'rotation': ++stamp,
    'scale': ++stamp,
  });
  ElementPatchOp patch({FieldMerge? merge, String? pageId, int? sortIndex}) =>
      ElementPatchOp(
        opId: opId,
        elementPublicId: target.publicId,
        expectedElementRevision: target.revision,
        payload: payload,
        pagePublicId: pageId,
        sortIndex: sortIndex ?? random.nextInt(3),
        merge: merge,
      );
  return switch (random.nextInt(11)) {
    7 || 8 || 9 => patch(merge: mergeOf(random, target, base: true)),
    10 || 1 => patch(merge: mergeOf(random, target, base: false)),
    0 => patch(),
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
    4 => patch(pageId: 'page-b', sortIndex: 0),
    _ => ElementAddOp(
      opId: opId,
      elementPublicId: 'new-$opId',
      pagePublicId: 'page-a',
      payload: agentPayload('new-$opId', {'rotation': ++stamp}),
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

StrategyRowSet teammateChanged(StrategyRowSet rows, Random random) {
  final live = [
    for (final row in rows.elements)
      if (row is LiveElement) row,
  ];
  final target = live[random.nextInt(live.length)];
  final field = drawnFields[random.nextInt(drawnFields.length)];
  final change = ElementPatchOp(
    opId: 'teammate',
    elementPublicId: target.publicId,
    expectedElementRevision: target.revision,
    payload: agentPayload(target.publicId, {
      ...target.payload.data.toJson(),
      field: field == 'position' ? {'dx': -1, 'dy': -1} : -1,
    }),
    sortIndex: target.sortIndex,
  );
  return switch (applyOp(rows, change)) {
    final OpApplied done => rows.withRows(done.rows),
    _ => rows,
  };
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

  StrategyRowSet skipping(StrategyRowSet rows, List<StrategyOp> ops) {
    var at = rows;
    for (final op in ops) {
      if (applyOp(at, op) case final OpApplied done) {
        at = at.withRows(done.rows);
      }
    }
    return at;
  }

  StrategyRowSet chained(StrategyRowSet rows, List<StrategyOp> ops) {
    var at = rows;
    for (final op in ops) {
      switch (applyOp(at, op)) {
        case final OpApplied done:
          at = at.withRows(done.rows);
        case OpUnchanged():
          break;
        case OpRefused():
          return at;
      }
    }
    return at;
  }

  test('a fold behind a claimed edit of the same row equals sending all '
      'three, whether that edit is then applied or refused', () {
    final random = Random(11);
    var checked = 0;
    for (var round = 0; round < 4000; round++) {
      final start = initialRows();
      final before = opOver(start, random, 'before');
      if (before is! ElementPatchOp) continue;
      final afterBefore = skipping(start, [before]);
      final first = followUp(afterBefore, random, before);
      if (first == null) continue;
      final afterFirst = skipping(afterBefore, [first]);
      final then = followUp(afterFirst, random, first);
      if (then == null) continue;
      if (fold(first, then) case FoldedOp(op: final folded)) {
        final moved = teammateChanged(afterBefore, random);
        for (final (label, server) in [
          ('applied', afterBefore),
          ('refused', start),
          ('teammate', moved),
        ]) {
          expect(
            liveContent(chained(server, [folded])),
            liveContent(chained(server, [first, then])),
            reason: '$label: ${first.toJson()} then ${then.toJson()}',
          );
        }
        checked++;
      }
    }
    expect(checked, greaterThan(100));
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
