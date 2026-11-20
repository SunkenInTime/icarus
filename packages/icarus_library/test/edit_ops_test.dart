import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

ElementPayload _with(LiveElement row, Map<String, Object?> changes) =>
    ElementPayload(
      kind: row.payload.kind,
      payloadVersion: row.payload.payloadVersion,
      data: {...row.payload.data, ...changes},
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
      drawnRevision: 4,
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
      drawnRevision: 4,
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
      drawnRevision: 3,
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
      drawnRevision: 2,
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
    expect(elementPayloadAtMergeBase(payload, merge).data, {
      ...jett.payload.data,
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
}
