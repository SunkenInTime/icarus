import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

final _jett = element(
  'jett',
  fields: {
    'type': 'jett',
    'position': {'x': 1, 'y': 1},
    'isAlly': true,
  },
);

ElementPatchOp _move(Session session, String opId, Object? position) {
  final row = session.rows.element('jett')! as LiveElement;
  return elementEditOp(
    opId: opId,
    base: row,
    drawn: DrawnAt(row.revision),
    payload: row.payload.withData({
      ...row.payload.data.toJson(),
      'position': position,
    }),
    sortIndex: row.sortIndex,
    connection: Connection.live,
  );
}

TypeMatcher<UndoBlocked> _blockedBy<T extends UndoBlock>() =>
    isA<UndoBlocked>().having((blocked) => blocked.block, 'block', isA<T>());

List<Object?> _linkIds(LineupGroupPayload payload) => [
  for (final link in (payload.data.toJson()['links']! as List<Object?>))
    (link! as Map<String, Object?>)['id'],
];

Map<String, Object?> _item(String id, String key, Map<String, Object?> body) =>
    {'id': id, key: body};

LineupGroupPayload _group(String id, List<String> links) => LineupGroupPayload(
  payloadVersion: 1,
  data: {
    'id': id,
    'origins': [
      _item('$id-o', 'agent', {'type': 'sova', 'lineUpID': '$id-o'}),
    ],
    'landings': [
      _item('$id-l', 'ability', {'type': 'recon', 'lineUpID': '$id-l'}),
    ],
    'links': [
      for (final link in links)
        {'id': link, 'originId': '$id-o', 'landingId': '$id-l', 'notes': link},
    ],
  },
);

LineupGroupPatchOp _linksTo(
  Session session,
  String opId,
  List<Object?> Function(List<Object?> links) change,
) {
  final row = session.groupAt('g1') as LiveLineupGroup;
  final data = row.payload.data.toJson();
  return lineupEditOp(
    opId: opId,
    base: row,
    drawn: DrawnAt(row.revision),
    payload: row.payload.withData({
      ...data,
      'links': change(data['links']! as List<Object?>),
    }),
    sortIndex: row.sortIndex,
    connection: Connection.live,
  );
}

void main() {
  test(
    'an undo is not built over a teammate\'s later change to the same field',
    () {
      final session = Session(strategyRows(elements: [_jett]));
      final mine = session.apply(_move(session, 'mine', {'x': 5, 'y': 5}));
      session.apply(_move(session, 'teammate', {'x': 9, 'y': 9}));
      expect(
        session.buildUndoOf(mine),
        _blockedBy<ChangedSince>().having(
          (blocked) => (blocked.block as ChangedSince).fields,
          'fields',
          ['data/position'],
        ),
      );
    },
  );

  test('an undo whose field is already back has nothing to do', () {
    final session = Session(strategyRows(elements: [_jett]));
    final mine = session.apply(_move(session, 'mine', {'x': 5, 'y': 5}));
    session.apply(_move(session, 'teammate', {'x': 1, 'y': 1}));
    expect(session.buildUndoOf(mine), isA<NothingToUndo>());
  });

  test('an undo of an edit to an element deleted since is not built', () {
    final session = Session(strategyRows(elements: [_jett]));
    final mine = session.apply(_move(session, 'mine', {'x': 5, 'y': 5}));
    session.apply(
      ElementDeleteOp(
        opId: 'gone',
        elementPublicId: 'jett',
        pagePublicId: 'page-a',
        expectedElementRevision: session.revisionOf('jett'),
      ),
    );
    expect(session.buildUndoOf(mine), _blockedBy<TargetGone>());
  });

  test(
    'an undo built after other edits carries the revision of that moment',
    () {
      final session = Session(strategyRows());
      final renamed = session.apply(
        const PagePatchOp(
          opId: 'rename',
          pagePublicId: 'page-a',
          expectedPageRevision: 1,
          name: 'Retake',
        ),
      );
      session.apply(
        const PagePatchOp(
          opId: 'side',
          pagePublicId: 'page-a',
          expectedPageRevision: 2,
          isAttack: false,
        ),
      );
      final undo = session.undo(renamed) as PagePatchOp;
      expect(undo.expectedPageRevision, 3);
      expect(undo.name, 'Page 1');
      expect(undo.isAttack, isNull);
      session.apply(undo);
      expect(session.pageAt('page-a').name, 'Page 1');
      expect(session.pageAt('page-a').isAttack, isFalse);
    },
  );

  test('an undo of a page delete asks for the page back from the trash', () {
    final session = Session(strategyRows());
    final deleted = session.apply(
      const PageDeleteOp(
        opId: 'delete',
        pagePublicId: 'page-b',
        expectedStrategyRevision: 1,
      ),
    );
    expect(
      session.buildUndoOf(deleted),
      isA<RestoreFromTrash>().having(
        (restore) => restore.pagePublicId,
        'page',
        'page-b',
      ),
    );
  });

  test('a removed lineup link is put back with the place it had', () {
    final group = LiveLineupGroup(
      strategyPublicId: strategyId,
      publicId: 'g1',
      pagePublicId: 'page-a',
      payload: LineupGroupPayload(
        payloadVersion: 1,
        data: {
          'id': 'g1',
          'origins': [
            {
              'id': 'o1',
              'agent': {'type': 'sova', 'lineUpID': 'o1'},
            },
          ],
          'landings': [
            {
              'id': 'l1',
              'ability': {'type': 'recon', 'lineUpID': 'l1'},
            },
          ],
          'links': [
            for (final id in ['k1', 'k2'])
              {'id': id, 'originId': 'o1', 'landingId': 'l1', 'notes': id},
          ],
        },
      ),
      sortIndex: 0,
      revision: 1,
    );
    final session = Session(strategyRows(lineupGroups: [group]));
    final removed = session.apply(
      lineupEditOp(
        opId: 'remove',
        base: group,
        drawn: const DrawnAt(1),
        payload: group.payload.withData({
          ...group.payload.data.toJson(),
          'links': [
            (group.payload.data.toJson()['links']! as List<Object?>).last,
          ],
        }),
        sortIndex: 0,
        connection: Connection.live,
      ),
    );
    expect((removed.undo as RestoreGroupFields).indexBefore('links/k1'), 0);
    final undo = session.undo(removed) as LineupGroupPatchOp;
    expect(_linkIds(undo.payload!), ['k1', 'k2']);
    session.apply(undo);
    expect(_linkIds(session.groupAt('g1').payload), ['k2', 'k1']);
  });

  test(
    'a link that came back last does not stop undoing the add of its group',
    () {
      final session = Session(strategyRows());
      final added = session.apply(
        LineupGroupAddOp(
          opId: 'add',
          lineupPublicId: 'g1',
          pagePublicId: 'page-a',
          payload: _group('g1', ['k1', 'k2']),
          sortIndex: 0,
        ),
      );
      final removed = session.apply(
        _linksTo(session, 'remove', (links) => links.skip(1).toList()),
      );
      session.apply(session.undo(removed));
      expect(_linkIds(session.groupAt('g1').payload), ['k2', 'k1']);
      expect(session.buildUndoOf(added), isA<UndoReady>());
      session.apply(session.undo(added));
      expect(session.groupAt('g1'), isA<DeletedLineupGroup>());
    },
  );

  group('a default made explicit', () {
    final agent = element(
      'agent',
      fields: {
        'type': 'jett',
        'visualState': {'showRange': true},
      },
    );

    ElementPatchOp whole(Session session, String opId, Object? visualState) {
      final row = session.rows.element('agent')! as LiveElement;
      return ElementPatchOp(
        opId: opId,
        elementPublicId: 'agent',
        expectedElementRevision: row.revision,
        payload: row.payload.withData({
          ...row.payload.data.toJson(),
          'visualState': visualState,
        }),
      );
    }

    test('does not stop an older undo of the same field', () {
      final session = Session(strategyRows(elements: [agent]));
      final hidden = session.apply(
        whole(session, 'hide', {'showRange': false}),
      );
      session.apply(
        whole(session, 'explicit', {
          'showRange': false,
          'showVisionCone': true,
        }),
      );
      session.apply(session.undo(hidden));
      expect(
        (session.dataOf('agent')['visualState']! as Map)['showRange'],
        isTrue,
      );
    });

    test('alone leaves nothing to undo', () {
      final session = Session(strategyRows(elements: [agent]));
      final explicit = session.apply(
        whole(session, 'explicit', {'showRange': true, 'showVisionCone': true}),
      );
      expect(session.buildUndoOf(explicit), isA<NothingToUndo>());
    });
  });

  test(
    'undoing a reorder of links puts back their order and keeps a teammate\'s later landing move',
    () {
      final session = Session(
        strategyRows(
          lineupGroups: [
            LiveLineupGroup(
              strategyPublicId: strategyId,
              publicId: 'g1',
              pagePublicId: 'page-a',
              payload: _group('g1', ['k1', 'k2', 'k3']),
              sortIndex: 0,
              revision: 1,
            ),
          ],
        ),
      );
      final row = session.groupAt('g1');
      final reversed = session.apply(
        LineupGroupPatchOp(
          opId: 'reverse',
          lineupPublicId: 'g1',
          expectedLineupRevision: row.revision,
          payload: row.payload.withData({
            ...row.payload.data.toJson(),
            'links': (row.payload.data.toJson()['links']! as List<Object?>)
                .reversed
                .toList(),
          }),
        ),
      );
      final moved = session.groupAt('g1') as LiveLineupGroup;
      final data = moved.payload.data.toJson();
      session.apply(
        lineupEditOp(
          opId: 'teammate',
          base: moved,
          drawn: DrawnAt(moved.revision),
          payload: moved.payload.withData({
            ...data,
            'landings': [
              _item('g1-l', 'ability', {
                'type': 'recon',
                'lineUpID': 'g1-l',
                'position': {'x': 9, 'y': 9},
              }),
            ],
          }),
          sortIndex: moved.sortIndex,
          connection: Connection.live,
        ),
      );
      session.apply(session.undo(reversed));
      final after = session.groupAt('g1').payload;
      expect(_linkIds(after), ['k1', 'k2', 'k3']);
      expect(
        ((after.data.toJson()['landings']! as List).single! as Map)['ability'],
        containsPair('position', {'x': 9, 'y': 9}),
      );
    },
  );

  test(
    'an old undo of a delete does not bring back a row a teammate re-added and deleted since',
    () {
      final session = Session(strategyRows(elements: [_jett]));
      final deleted = session.apply(
        const ElementDeleteOp(
          opId: 'delete',
          elementPublicId: 'jett',
          pagePublicId: 'page-a',
          expectedElementRevision: 1,
        ),
      );
      session.apply(
        ElementAddOp(
          opId: 'teammate-add',
          elementPublicId: 'jett',
          pagePublicId: 'page-a',
          payload: agentPayload('jett', {'type': 'jett', 'caption': 'theirs'}),
          sortIndex: 0,
          expectedElementRevision: session.revisionOf('jett'),
        ),
      );
      session.apply(
        ElementDeleteOp(
          opId: 'teammate-delete',
          elementPublicId: 'jett',
          pagePublicId: 'page-a',
          expectedElementRevision: session.revisionOf('jett'),
        ),
      );
      expect(session.buildUndoOf(deleted), _blockedBy<ChangedSince>());
    },
  );

  test('an image scale undo is not built once a teammate has moved the image, '
      'as the server would refuse it', () {
    final photo = LiveElement(
      publicId: 'photo',
      pagePublicId: 'page-a',
      payload: ElementPayload(
        kind: ElementKind.image,
        payloadVersion: 1,
        data: {
          'id': 'photo',
          'elementType': 'image',
          'position': {'x': 10, 'y': 10},
          'scale': 1,
        },
      ),
      sortIndex: 0,
      revision: 1,
    );
    final session = Session(strategyRows(elements: [photo]));
    LiveElement now() => session.rows.element('photo')! as LiveElement;
    ElementPatchOp edit(String opId, Map<String, Object?> change) =>
        elementEditOp(
          opId: opId,
          base: now(),
          drawn: DrawnAt(now().revision),
          payload: now().payload.withData({
            ...now().payload.data.toJson(),
            ...change,
          }),
          sortIndex: 0,
          connection: Connection.live,
        );
    final scaled = session.apply(edit('scale', {'scale': 2}));
    session.apply(
      edit('teammate', {
        'position': {'x': 1, 'y': 1},
      }),
    );
    expect(session.buildUndoOf(scaled), _blockedBy<ChangedSince>());
  });
}
