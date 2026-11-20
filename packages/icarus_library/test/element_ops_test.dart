import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

ElementPatchOp moveAgent(
  String opId,
  ElementRow? row,
  Map<String, Object?> fields, {
  List<String>? merged,
  Map<String, Object?>? base,
  int? expectedRevision,
}) {
  final (payload, revision) = switch (row) {
    ReadableElementRow(:final payload, :final revision) => (payload, revision),
    final other => fail('Cannot edit $other'),
  };
  return ElementPatchOp(
    opId: opId,
    elementPublicId: row.publicId,
    expectedElementRevision: expectedRevision ?? revision,
    payload: ElementPayload(
      kind: payload.kind,
      payloadVersion: payload.payloadVersion,
      data: {...payload.data, ...fields},
    ),
    merge: merged == null ? null : FieldMerge(fields: merged, base: base),
  );
}

void main() {
  final jett = element(
    'jett',
    fields: {
      'position': {'x': 1, 'y': 1},
      'isAlly': true,
    },
  );

  test('an accepted edit raises the revision by one and keeps the id', () {
    final session = Session(strategyRows(elements: [jett]));
    session.apply(
      moveAgent('op-1', jett, {
        'position': {'x': 5, 'y': 5},
      }),
    );
    expect(session.revisionOf('jett'), 2);
    expect(session.dataOf('jett')['position'], {'x': 5, 'y': 5});
  });

  test('two people editing different fields of one agent both keep theirs', () {
    final session = Session(strategyRows(elements: [jett]));
    final mine = moveAgent(
      'mine',
      jett,
      {
        'position': {'x': 5, 'y': 5},
      },
      merged: ['position'],
    );
    session.apply(
      moveAgent('teammate', jett, {'isAlly': false}, merged: ['isAlly']),
    );
    session.apply(mine);
    expect(session.dataOf('jett')['position'], {'x': 5, 'y': 5});
    expect(session.dataOf('jett')['isAlly'], false);
    expect(session.revisionOf('jett'), 3);
  });

  test('undo restores exactly the fields the action changed and leaves a '
      "teammate's change to another field alone", () {
    final session = Session(strategyRows(elements: [jett]));
    final moved = session.apply(
      moveAgent(
        'mine',
        jett,
        {
          'position': {'x': 9, 'y': 9},
        },
        merged: ['position'],
      ),
    );
    session.apply(
      moveAgent(
        'teammate',
        session.rows.element('jett'),
        {'isAlly': false},
        merged: ['isAlly'],
      ),
    );
    session.apply(undoOp(moved));
    expect(session.dataOf('jett')['position'], {'x': 1, 'y': 1});
    expect(session.dataOf('jett')['isAlly'], false);
  });

  test('undo of a whole write still names only what that write changed', () {
    final session = Session(strategyRows(elements: [jett]));
    final moved = session.apply(
      moveAgent('mine', jett, {
        'position': {'x': 9, 'y': 9},
      }),
    );
    final undo = undoOp(moved) as ElementPatchOp;
    expect(undo.merge?.fields, ['position']);
    session.apply(
      moveAgent(
        'teammate',
        session.rows.element('jett'),
        {'isAlly': false},
        merged: ['isAlly'],
      ),
    );
    session.apply(undo);
    expect(session.dataOf('jett'), {
      'id': 'jett',
      'elementType': 'agent',
      'position': {'x': 1, 'y': 1},
      'isAlly': false,
    });
  });

  test('a whole write made on an old revision is refused', () {
    final session = Session(strategyRows(elements: [jett]));
    session.apply(moveAgent('teammate', jett, {'isAlly': false}));
    expect(
      refused(
        session.attempt(
          moveAgent('mine', jett, {
            'position': {'x': 2, 'y': 2},
          }),
        ),
      ),
      const Rejected(RejectionReason.revisionMismatch),
    );
  });

  test('offline work that collides with a teammate on the same field asks', () {
    final session = Session(strategyRows(elements: [jett]));
    session.apply(
      moveAgent(
        'teammate',
        jett,
        {
          'position': {'x': 3, 'y': 3},
        },
        merged: ['position'],
      ),
    );
    final offline = moveAgent(
      'offline',
      jett,
      {
        'position': {'x': 7, 'y': 7},
      },
      merged: ['position'],
      base: {
        'position': {'x': 1, 'y': 1},
      },
    );
    expect(
      refused(session.attempt(offline)),
      const Rejected(RejectionReason.fieldConflict),
    );
  });

  test('offline work lands when the field already holds what it writes', () {
    final session = Session(strategyRows(elements: [jett]));
    session.apply(
      moveAgent(
        'teammate',
        jett,
        {
          'position': {'x': 7, 'y': 7},
        },
        merged: ['position'],
      ),
    );
    final offline = moveAgent(
      'offline',
      jett,
      {
        'position': {'x': 7, 'y': 7},
      },
      merged: ['position'],
      base: {
        'position': {'x': 1, 'y': 1},
      },
    );
    expect(session.attempt(offline), isA<OpUnchanged>());
  });

  test('a delete leaves a tombstone and undo brings the agent back', () {
    final session = Session(strategyRows(elements: [jett]));
    final deleted = session.apply(
      const ElementDeleteOp(
        opId: 'delete',
        elementPublicId: 'jett',
        pagePublicId: 'page-a',
        expectedElementRevision: 1,
      ),
    );
    final tombstone = session.rows.element('jett');
    expect(tombstone, isA<DeletedElement>());
    expect((tombstone! as DeletedElement).payload, jett.payload);
    expect(session.revisionOf('jett'), 2);

    session.apply(undoOp(deleted));
    final restored = session.rows.element('jett');
    expect(restored, isA<LiveElement>());
    expect((restored! as LiveElement).payload, jett.payload);
    expect(session.revisionOf('jett'), 3);
  });

  test('a live delete wins over an edit a teammate made a moment before', () {
    final session = Session(strategyRows(elements: [jett]));
    session.apply(moveAgent('teammate', jett, {'isAlly': false}));
    session.apply(
      const ElementDeleteOp(
        opId: 'delete',
        elementPublicId: 'jett',
        pagePublicId: 'page-a',
        expectedElementRevision: 1,
        lastWriterWins: true,
      ),
    );
    expect(session.rows.element('jett'), isA<DeletedElement>());
  });

  test('an edit to an agent a teammate deleted is refused as deleted', () {
    final session = Session(strategyRows(elements: [jett]));
    session.apply(
      const ElementDeleteOp(
        opId: 'teammate-delete',
        elementPublicId: 'jett',
        pagePublicId: 'page-a',
        expectedElementRevision: 1,
      ),
    );
    expect(
      refused(session.attempt(moveAgent('mine', jett, {'isAlly': false}))),
      const Rejected(RejectionReason.deleted),
    );
  });

  test('re-adding a deleted agent needs the tombstone revision', () {
    final session = Session(strategyRows(elements: [deletedElement('jett')]));
    final readd = ElementAddOp(
      opId: 'readd',
      elementPublicId: 'jett',
      pagePublicId: 'page-a',
      payload: agentPayload('jett', {}),
      sortIndex: 0,
    );
    expect(
      refused(session.attempt(readd)),
      const Rejected(RejectionReason.missingExpectedRevision),
    );
  });

  test('editing an element that does not exist is refused as not found', () {
    final session = Session(strategyRows());
    expect(
      refused(session.attempt(moveAgent('mine', jett, {'isAlly': false}))),
      const Rejected(RejectionReason.notFound),
    );
  });

  test('adding to a page that is not in this strategy fails', () {
    final session = Session(strategyRows());
    expect(
      refused(
        session.attempt(
          ElementAddOp(
            opId: 'add',
            elementPublicId: 'sage',
            pagePublicId: 'page-elsewhere',
            payload: agentPayload('sage', {}),
            sortIndex: 0,
          ),
        ),
      ),
      const Failed(FailureCode.pageStrategyMismatch),
    );
  });

  test('a write from a build that predates captions keeps the caption', () {
    final captioned = element(
      'jett',
      fields: {
        'position': {'x': 1, 'y': 1},
        'caption': 'entry',
      },
    );
    final session = Session(strategyRows(elements: [captioned]));
    session.apply(
      ElementPatchOp(
        opId: 'old-build',
        elementPublicId: 'jett',
        expectedElementRevision: 1,
        payload: agentPayload('jett', {
          'position': {'x': 4, 'y': 4},
        }),
      ),
    );
    expect(session.dataOf('jett')['caption'], 'entry');
    expect(session.dataOf('jett')['position'], {'x': 4, 'y': 4});
  });

  test('a moved place is written only when the merge names it', () {
    final session = Session(strategyRows(elements: [jett]));
    final payload = agentPayload('jett', {'isAlly': false});
    session.apply(
      ElementPatchOp(
        opId: 'edit',
        elementPublicId: 'jett',
        expectedElementRevision: 1,
        payload: payload,
        sortIndex: 4,
        merge: FieldMerge(fields: ['isAlly']),
      ),
    );
    expect((session.rows.element('jett')! as LiveElement).sortIndex, 0);
    session.apply(
      ElementPatchOp(
        opId: 'restack',
        elementPublicId: 'jett',
        expectedElementRevision: 2,
        sortIndex: 4,
        merge: FieldMerge(fields: ['@sortIndex']),
      ),
    );
    expect((session.rows.element('jett')! as LiveElement).sortIndex, 4);
  });

  test('the changes name the row and the fields an edit touched', () {
    final session = Session(strategyRows(elements: [jett]));
    final result = session.apply(
      moveAgent(
        'mine',
        jett,
        {
          'position': {'x': 2, 'y': 2},
        },
        merged: ['position'],
      ),
    );
    final write = result.writes.single as RowChanged;
    expect(write.key, const ElementKey('jett'));
    expect(write.fields, isEmpty);
    expect(write.dataFields, {'position'});
  });
}
