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

ElementPatchOp mergePatch(
  StrategyRowSet rows,
  Random random, {
  required String opId,
  required String elementId,
  required List<String> fields,
  required bool base,
}) {
  final target = rows.elements.whereType<LiveElement>().firstWhere(
    (row) => row.publicId == elementId,
  );
  final data = target.payload.data.toJson();
  for (final field in fields) {
    if (field == 'position') {
      data[field] = {'dx': random.nextInt(4), 'dy': random.nextInt(4)};
    } else if (field != placeField) {
      data[field] = random.nextInt(4);
    }
  }
  final merge = FieldMerge(fields: fields, base: null);
  return ElementPatchOp(
    opId: opId,
    elementPublicId: elementId,
    expectedElementRevision: target.revision,
    payload: agentPayload(elementId, data),
    sortIndex: fields.contains(placeField)
        ? random.nextInt(3)
        : target.sortIndex,
    merge: base
        ? FieldMerge(
            fields: fields,
            base: {
              for (final field in fields)
                if (field == placeField)
                  field: target.sortIndex
                else if (target.payload.data.containsKey(field))
                  field: plainJson(target.payload.data[field]),
            },
          )
        : merge,
  );
}

List<String> fieldsOf(Random random) {
  final fields = [
    for (final field in drawnFields)
      if (random.nextBool()) field,
    if (random.nextInt(4) == 0) placeField,
  ];
  return fields.isEmpty ? [drawnFields[random.nextInt(3)]] : fields;
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

sealed class Delivery {
  const Delivery();
}

final class Landed extends Delivery {
  const Landed(this.rows);

  final StrategyRowSet rows;
}

final class HeldForUser extends Delivery {
  const HeldForUser();
}

Delivery deliver(StrategyRowSet server, List<StrategyOp> ops) {
  var at = server;
  for (final op in ops) {
    switch (applyOp(at, op)) {
      case final OpApplied done:
        at = at.withRows(done.rows);
      case OpUnchanged():
        break;
      case OpRefused():
        return const HeldForUser();
    }
  }
  return Landed(at);
}

StrategyRowSet? applied(StrategyRowSet rows, StrategyOp op) =>
    switch (applyOp(rows, op)) {
      final OpApplied done => rows.withRows(done.rows),
      OpUnchanged() => rows,
      OpRefused() => null,
    };

void expectUserValues(StrategyRowSet rows, ElementPatchOp then, String reason) {
  final row = rows.elements.whereType<LiveElement>().firstWhere(
    (row) => row.publicId == then.elementPublicId,
  );
  for (final field in then.merge!.fields) {
    expect(
      field == placeField ? row.sortIndex : plainJson(row.payload.data[field]),
      field == placeField
          ? then.sortIndex
          : plainJson(then.payload!.data[field]),
      reason: '$field after $reason',
    );
  }
}

void main() {
  test('only a field edit folds into an earlier field edit of the same row '
      'naming exactly the same fields', () {
    final random = Random(7);
    final folded = <String>{};
    var tried = 0;
    for (var round = 0; round < 4000; round++) {
      final start = initialRows();
      final first = opOver(start, random, 'first');
      if (first == null) continue;
      final afterFirst = applied(start, first);
      if (afterFirst == null) continue;
      final then = followUp(afterFirst, random, first);
      if (then == null) continue;
      tried++;
      if (fold(first, then) case FoldedOp(op: final op)) {
        final (ElementPatchOp a, ElementPatchOp b) = (
          first as ElementPatchOp,
          then as ElementPatchOp,
        );
        expect(a.merge!.fields.toSet(), b.merge!.fields.toSet());
        expect(a.merge!.base == null, b.merge!.base == null);
        expect(op, isA<ElementPatchOp>());
        folded.add('${first.type.wireName}+${then.type.wireName}');
      }
    }
    expect(tried, greaterThan(1000));
    expect(folded, {'element.patch+element.patch'});
    final add = ElementAddOp(
      opId: 'add',
      elementPublicId: 'new',
      pagePublicId: 'page-a',
      payload: agentPayload('new', {'rotation': 1}),
      sortIndex: 0,
    );
    final added = initialRows().withRows(
      (applyOp(initialRows(), add) as OpApplied).rows,
    );
    for (final then in [
      mergePatch(
        added,
        random,
        opId: 'patch',
        elementId: 'new',
        fields: ['rotation'],
        base: true,
      ),
      const ElementDeleteOp(
        opId: 'delete',
        elementPublicId: 'new',
        pagePublicId: 'page-a',
        expectedElementRevision: 1,
      ),
    ]) {
      expect(fold(add, then), isA<KeptApart>());
    }
    final whole = movePatch('whole');
    expect(fold(whole, movePatch('again', x: 30)), isA<KeptApart>());
  });

  test('a folded field edit gives what sending both gives, or is held for '
      'the user with the server value and the user value both kept', () {
    final random = Random(13);
    final outcomes = <String>{};
    for (var round = 0; round < 3000; round++) {
      final start = initialRows();
      final elementId = 'e${random.nextInt(2) + 1}';
      final fields = fieldsOf(random);
      final base = random.nextInt(4) != 0;
      final first = mergePatch(
        start,
        random,
        opId: 'first',
        elementId: elementId,
        fields: fields,
        base: base,
      );
      final afterFirst = applied(start, first)!;
      final then = mergePatch(
        afterFirst,
        random,
        opId: 'then',
        elementId: elementId,
        fields: fields,
        base: base,
      );
      final op = switch (fold(first, then)) {
        FoldedOp(:final op) => op as ElementPatchOp,
        KeptApart() => fail('${first.toJson()} then ${then.toJson()}'),
      };
      for (final field in fields.where((field) => field != placeField)) {
        expect(
          plainJson(op.payload!.data[field]),
          plainJson(then.payload!.data[field]),
        );
      }
      for (final (label, server) in [
        ('untouched', start),
        ('already at the first value', afterFirst),
        ('teammate', teammateChanged(start, random)),
      ]) {
        final reason = '$label: ${first.toJson()} then ${then.toJson()}';
        switch ((deliver(server, [op]), deliver(server, [first, then]))) {
          case (Landed(rows: final once), Landed(rows: final twice)):
            expect(liveContent(once), liveContent(twice), reason: reason);
            outcomes.add('$label same');
          case (HeldForUser(), HeldForUser()):
            outcomes.add('$label both held');
          case (HeldForUser(), Landed()):
            expect(label, isNot('untouched'), reason: reason);
            outcomes.add('$label held');
          case (Landed(rows: final once), HeldForUser()):
            expectUserValues(once, then, reason);
            outcomes.add('$label landed at the last value');
        }
      }
    }
    expect(outcomes, contains('untouched same'));
    expect(outcomes, contains('already at the first value held'));
    expect(outcomes, contains('teammate same'));
  });

  test('a fold behind a claimed edit of the same row gives what sending all '
      'three gives, or is held, whether that edit is applied or refused', () {
    final random = Random(11);
    var checked = 0;
    for (var round = 0; round < 3000; round++) {
      final start = initialRows();
      final elementId = 'e${random.nextInt(2) + 1}';
      final before = mergePatch(
        start,
        random,
        opId: 'before',
        elementId: elementId,
        fields: fieldsOf(random),
        base: true,
      );
      final afterBefore = applied(start, before)!;
      final fields = fieldsOf(random);
      final first = mergePatch(
        afterBefore,
        random,
        opId: 'first',
        elementId: elementId,
        fields: fields,
        base: true,
      );
      final afterFirst = applied(afterBefore, first)!;
      final then = mergePatch(
        afterFirst,
        random,
        opId: 'then',
        elementId: elementId,
        fields: fields,
        base: true,
      );
      final op = (fold(first, then) as FoldedOp).op;
      for (final (label, server) in [
        ('applied', afterBefore),
        ('refused', start),
        ('teammate', teammateChanged(afterBefore, random)),
      ]) {
        final reason = '$label: ${first.toJson()} then ${then.toJson()}';
        switch ((deliver(server, [op]), deliver(server, [first, then]))) {
          case (Landed(rows: final once), Landed(rows: final twice)):
            expect(liveContent(once), liveContent(twice), reason: reason);
          case (HeldForUser(), _):
            break;
          case (Landed(rows: final once), HeldForUser()):
            expectUserValues(once, then, reason);
        }
      }
      checked++;
    }
    expect(checked, 3000);
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
