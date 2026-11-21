import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

Map<String, Object?> origin(String id) => {
  'id': id,
  'agent': {'type': 'sova', 'lineUpID': id},
};

Map<String, Object?> landing(String id) => {
  'id': id,
  'ability': {'type': 'recon', 'lineUpID': id},
};

Map<String, Object?> link(
  String id,
  String from,
  String to, {
  String notes = '',
}) => {'id': id, 'originId': from, 'landingId': to, 'notes': notes};

LineupGroupPayload group(
  String id, {
  required List<Map<String, Object?>> origins,
  required List<Map<String, Object?>> landings,
  required List<Map<String, Object?>> links,
}) => LineupGroupPayload(
  payloadVersion: 1,
  data: {'id': id, 'origins': origins, 'landings': landings, 'links': links},
);

void main() {
  final oneLineup = group(
    'g1',
    origins: [origin('o1')],
    landings: [landing('l1')],
    links: [link('k1', 'o1', 'l1')],
  );
  final row = LiveLineupGroup(
    strategyPublicId: strategyId,
    publicId: 'g1',
    pagePublicId: 'page-a',
    payload: oneLineup,
    sortIndex: 0,
    revision: 1,
  );

  LineupGroupPatchOp patch(
    String opId,
    LineupGroupPayload payload,
    List<String> fields, {
    int expected = 1,
  }) => LineupGroupPatchOp(
    opId: opId,
    lineupPublicId: 'g1',
    expectedLineupRevision: expected,
    payload: payload,
    merge: FieldMerge(fields: fields),
  );

  test('a lineup added by a teammate stays when I edit the notes of mine', () {
    final session = Session(strategyRows(lineupGroups: [row]));
    session.apply(
      patch(
        'teammate',
        group(
          'g1',
          origins: [origin('o1'), origin('o2')],
          landings: [landing('l1')],
          links: [link('k1', 'o1', 'l1'), link('k2', 'o2', 'l1')],
        ),
        ['origins/o2', 'links/k2'],
      ),
    );
    session.apply(
      patch(
        'mine',
        group(
          'g1',
          origins: [origin('o1')],
          landings: [landing('l1')],
          links: [link('k1', 'o1', 'l1', notes: 'jump throw')],
        ),
        ['links/k1'],
      ),
    );
    final data = session.groupAt('g1').payload.data.toJson();
    expect(data['links'], [
      link('k1', 'o1', 'l1', notes: 'jump throw'),
      link('k2', 'o2', 'l1'),
    ]);
    expect(data['origins'], [origin('o1'), origin('o2')]);
  });

  test(
    'a lineup whose spot a teammate removed is refused as merge invalid',
    () {
      final session = Session(
        strategyRows(
          lineupGroups: [
            LiveLineupGroup(
              strategyPublicId: strategyId,
              publicId: 'g1',
              pagePublicId: 'page-a',
              payload: group(
                'g1',
                origins: [origin('o1'), origin('o2')],
                landings: [landing('l1')],
                links: [link('k1', 'o1', 'l1'), link('k2', 'o2', 'l1')],
              ),
              sortIndex: 0,
              revision: 1,
            ),
          ],
        ),
      );
      session.apply(patch('teammate', oneLineup, ['links/k2', 'origins/o2']));
      final mine = patch(
        'mine',
        group(
          'g1',
          origins: [origin('o1'), origin('o2')],
          landings: [landing('l1')],
          links: [
            link('k1', 'o1', 'l1'),
            link('k2', 'o2', 'l1'),
            link('k3', 'o2', 'l1'),
          ],
        ),
        ['links/k3'],
      );
      expect(
        refused(session.attempt(mine)),
        const Rejected(RejectionReason.mergeInvalid),
      );
    },
  );

  test('a group that would share a spot with another group fails', () {
    final session = Session(strategyRows(lineupGroups: [row]));
    final overlapping = LineupGroupAddOp(
      opId: 'add',
      lineupPublicId: 'g2',
      pagePublicId: 'page-a',
      payload: group(
        'g2',
        origins: [origin('o1')],
        landings: [landing('l9')],
        links: [link('k9', 'o1', 'l9')],
      ),
      sortIndex: 1,
    );
    expect(
      refused(session.attempt(overlapping)),
      const Failed(FailureCode.invalidLineupPayloadData),
    );
  });

  test('a lineup group never moves to another page', () {
    final session = Session(strategyRows(lineupGroups: [row]));
    expect(
      refused(
        session.attempt(
          LineupGroupPatchOp(
            opId: 'move',
            lineupPublicId: 'g1',
            pagePublicId: 'page-b',
            expectedLineupRevision: 1,
            payload: oneLineup,
          ),
        ),
      ),
      const Failed(FailureCode.lineupPageMismatch),
    );
  });

  test("undo of my notes edit keeps a teammate's new lineup", () {
    final session = Session(strategyRows(lineupGroups: [row]));
    final edited = session.apply(
      patch(
        'mine',
        group(
          'g1',
          origins: [origin('o1')],
          landings: [landing('l1')],
          links: [link('k1', 'o1', 'l1', notes: 'jump throw')],
        ),
        ['links/k1'],
      ),
    );
    session.apply(
      patch(
        'teammate',
        group(
          'g1',
          origins: [origin('o1'), origin('o2')],
          landings: [landing('l1')],
          links: [
            link('k1', 'o1', 'l1', notes: 'jump throw'),
            link('k2', 'o2', 'l1'),
          ],
        ),
        ['origins/o2', 'links/k2'],
        expected: 2,
      ),
    );
    session.apply(undoOp(edited));
    final data = session.groupAt('g1').payload.data.toJson();
    expect(data['links'], [link('k1', 'o1', 'l1'), link('k2', 'o2', 'l1')]);
  });

  test('putting two lineups of a group in a new order saves the order', () {
    final twoLinks = group(
      'g1',
      origins: [origin('o1')],
      landings: [landing('l1')],
      links: [link('a', 'o1', 'l1'), link('b', 'o1', 'l1')],
    );
    final session = Session(
      strategyRows(
        lineupGroups: [
          LiveLineupGroup(
            strategyPublicId: strategyId,
            publicId: 'g1',
            pagePublicId: 'page-a',
            payload: twoLinks,
            sortIndex: 0,
            revision: 1,
          ),
        ],
      ),
    );
    final reordered = session.apply(
      LineupGroupPatchOp(
        opId: 'reorder-links',
        lineupPublicId: 'g1',
        expectedLineupRevision: 1,
        payload: group(
          'g1',
          origins: [origin('o1')],
          landings: [landing('l1')],
          links: [link('b', 'o1', 'l1'), link('a', 'o1', 'l1')],
        ),
      ),
    );
    final links =
        session.groupAt('g1').payload.data.toJson()['links']! as List<Object?>;
    expect(
      [for (final link in links.cast<Map<String, Object?>>()) link['id']],
      ['b', 'a'],
    );
    session.apply(undoOp(reordered));
    expect(session.groupAt('g1').payload, twoLinks);
  });

  test('the same lineup group id in two strategies names two rows', () {
    expect(
      const LineupGroupKey('strategy-1', 'g1'),
      isNot(const LineupGroupKey('strategy-2', 'g1')),
    );
    expect(row.key, const LineupGroupKey(strategyId, 'g1'));
  });
}
