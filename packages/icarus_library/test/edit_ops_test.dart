import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

ElementPayload _with(LiveElement row, Map<String, Object?> changes) =>
    ElementPayload(
      kind: row.payload.kind,
      payloadVersion: row.payload.payloadVersion,
      data: {...row.payload.data.toMap(), ...changes},
    );

Map<String, Object?> _link(String id, String notes) => {
  'id': id,
  'originId': 'o0',
  'landingId': 'l0',
  'notes': notes,
};

LineupGroupPayload _group(List<Map<String, Object?>> links) =>
    LineupGroupPayload(
      payloadVersion: 1,
      data: {
        'id': 'g0',
        'origins': [
          {'id': 'o0', 'agent': <String, Object?>{}},
        ],
        'landings': [
          {'id': 'l0', 'ability': <String, Object?>{}},
        ],
        'links': links,
      },
    );

void main() {
  final jett = element(
    'jett',
    pageId: 'page-b',
    fields: {
      'type': 'jett',
      'position': {'x': 1, 'y': 1},
      'isAlly': true,
    },
    sortIndex: 2,
    revision: 4,
  );

  test('a live edit names its fields and its page and sends no base', () {
    final op = elementEditOp(
      opId: 'op',
      base: jett,
      drawn: DrawnAt(4),
      payload: _with(jett, {'isAlly': false}),
      sortIndex: 2,
      connection: Connection.live,
    );
    expect(op.pagePublicId, 'page-b');
    expect(op.expectedElementRevision, 4);
    expect(op.merge, FieldMerge(fields: ['isAlly']));
  });

  test('an offline edit carries each field and the place as it saw them', () {
    final op = elementEditOp(
      opId: 'op',
      base: jett,
      drawn: DrawnAt(4),
      payload: _with(jett, {'isAlly': false, 'caption': 'lurk'}),
      sortIndex: 5,
      connection: Connection.offline,
    );
    expect(
      op.merge,
      FieldMerge(
        fields: ['caption', 'isAlly', placeField],
        base: {'isAlly': true, placeField: 2},
      ),
    );
  });

  test('an edit of what the item is writes it whole, claiming only the '
      'revision this client drew', () {
    final op = elementEditOp(
      opId: 'op',
      base: jett,
      drawn: DrawnAt(3),
      payload: _with(jett, {'type': 'sova'}),
      sortIndex: 2,
      connection: Connection.live,
    );
    expect(op.merge, isNull);
    expect(op.expectedElementRevision, 3);
  });

  test('an offline lineup edit carries the item as it saw it', () {
    final base = LiveLineupGroup(
      strategyPublicId: strategyId,
      publicId: 'g0',
      pagePublicId: 'page-a',
      payload: _group([_link('k0', '')]),
      sortIndex: 0,
      revision: 2,
    );
    final op = lineupEditOp(
      opId: 'op',
      base: base,
      drawn: DrawnAt(2),
      payload: _group([_link('k0', 'jump'), _link('k1', '')]),
      sortIndex: 0,
      connection: Connection.offline,
    );
    expect(op.pagePublicId, 'page-a');
    expect(
      op.merge,
      FieldMerge(
        fields: ['links/k0', 'links/k1'],
        base: {'links/k0': _link('k0', '')},
      ),
    );
  });

  test('the payload at a merge\'s base sets back only the merged fields', () {
    final payload = _with(jett, {
      'isAlly': false,
      'caption': 'lurk',
      'position': {'x': 9, 'y': 9},
    });
    final merge = FieldMerge(
      fields: ['caption', 'isAlly'],
      base: {'isAlly': true},
    );
    expect(elementPayloadAtMergeBase(payload, merge).data.toJson(), {
      ...jett.payload.data.toJson(),
      'position': {'x': 9, 'y': 9},
    });
    expect(
      elementPayloadAtMergeBase(payload, FieldMerge(fields: ['isAlly'])),
      payload,
    );
  });

  test('the lineup payload at a merge\'s base puts back the items it saw', () {
    final payload = _group([_link('k0', 'jump'), _link('k1', '')]);
    final merge = FieldMerge(
      fields: ['links/k0', 'links/k1'],
      base: {'links/k0': _link('k0', '')},
    );
    expect(switch (lineupPayloadAtMergeBase(payload, merge)) {
      Merged(:final value) => value,
      final other => other,
    }, _group([_link('k0', '')]));
  });

  test('an edit made behind a pending whole write is whole too, claiming the '
      'same revision', () {
    final op = elementEditOp(
      opId: 'op',
      base: jett,
      drawn: const BehindWholeWrite(3),
      payload: _with(jett, {'isAlly': false}),
      sortIndex: 2,
      connection: Connection.live,
    );
    expect(op.merge, isNull);
    expect(op.expectedElementRevision, 3);
  });

  test('a lineup group written whole claims only the revision this client '
      'drew', () {
    final base = LiveLineupGroup(
      strategyPublicId: strategyId,
      publicId: 'g0',
      pagePublicId: 'page-a',
      payload: _group([_link('k0', '')]),
      sortIndex: 0,
      revision: 4,
    );
    LineupGroupPatchOp edit(Drawn drawn) => lineupEditOp(
      opId: 'op',
      base: base,
      drawn: drawn,
      payload: _group([_link('k0', 'jump')]),
      sortIndex: 0,
      connection: Connection.live,
    );
    expect(
      (
        edit(const BehindWholeWrite(2)).merge,
        edit(const BehindWholeWrite(2)).expectedLineupRevision,
      ),
      (null, 2),
    );
    expect(edit(const DrawnAt(4)).merge, FieldMerge(fields: ['links/k0']));
  });

  const groups = [
    (ElementKind.agent, 'agent', ['length', 'rotation']),
    (ElementKind.ability, 'ability', ['length', 'rotation']),
    (
      ElementKind.drawing,
      'drawing',
      ['boundingBox', 'end', 'lineEnd', 'lineStart', 'listOfPoints', 'start'],
    ),
    (ElementKind.text, 'text', ['fontSize', 'position', 'size', 'sizeVersion']),
    (ElementKind.image, 'image', ['position', 'scale', 'sizeVersion']),
    (
      ElementKind.utility,
      'customRectangle',
      ['customLength', 'customWidth', 'position', 'rotation'],
    ),
    (ElementKind.utility, 'viewCone90', ['length', 'rotation']),
  ];
  for (final (kind, type, members) in groups) {
    for (final member in members) {
      test('changing ${kind.name} ($type) $member names its whole group', () {
        final base = ElementPayload(
          kind: kind,
          payloadVersion: 1,
          data: {
            'id': 'x',
            'elementType': kind.name,
            if (kind == ElementKind.utility) 'type': type,
            for (final field in members) field: 1,
            'isAlly': true,
          },
        );
        final desired = ElementPayload(
          kind: kind,
          payloadVersion: 1,
          data: {...base.data.toMap(), member: 2},
        );
        expect(switch (elementEdit(base, desired)) {
          FieldEdit(:final fields) => fields,
          WholeEdit(:final reason) => reason,
        }, members);
      });
    }
  }
}
