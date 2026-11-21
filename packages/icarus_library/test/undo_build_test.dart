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
    expect(
      [
        for (final link
            in (undo.payload!.data.toJson()['links']! as List<Object?>))
          (link! as Map<String, Object?>)['id'],
      ],
      ['k1', 'k2'],
    );
  });
}
