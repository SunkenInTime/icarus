import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

LineupGroupPayload _group(String notes, {String id = 'g1'}) =>
    LineupGroupPayload(
      payloadVersion: 1,
      data: {
        'id': id,
        'origins': [
          {
            'id': 'o1',
            'agent': {'type': 'sova'},
          },
        ],
        'landings': [
          {
            'id': 'l1',
            'ability': {'type': 'recon'},
          },
        ],
        'links': [
          {'id': 'k1', 'originId': 'o1', 'landingId': 'l1', 'notes': notes},
        ],
      },
    );

void main() {
  final rows = strategyRows(
    elements: [
      element('jett', fields: {'isAlly': true, 'caption': 'entry'}),
      element('sage', pageId: 'page-b'),
    ],
    lineupGroups: [
      LiveLineupGroup(
        strategyPublicId: strategyId,
        publicId: 'g1',
        pagePublicId: 'page-a',
        payload: _group(''),
        sortIndex: 0,
        revision: 1,
      ),
    ],
  ).withRows([deletedElement('omen', revision: 4)]);

  final edited = agentPayload('jett', {'isAlly': false});

  final ops = <String, StrategyOp>{
    'strategy.patch': const StrategyPatchOp(
      opId: 'op',
      expectedStrategyRevision: 1,
      name: 'Execute A',
      themeProfile: SetValue('ember'),
    ),
    'page.add': const PageAddOp(
      opId: 'op',
      pagePublicId: 'page-new',
      sortIndex: 0,
      expectedStrategyRevision: 1,
      name: 'Page 1',
      isAutoNamed: true,
      settings: defaultSettings,
    ),
    'page.add copying a page': const PageAddOp(
      opId: 'op',
      pagePublicId: 'page-new',
      sortIndex: 1,
      expectedStrategyRevision: 1,
      copyContentFromPagePublicId: 'page-a',
    ),
    'page.patch': const PagePatchOp(
      opId: 'op',
      pagePublicId: 'page-a',
      expectedPageRevision: 1,
      name: 'Default',
      isAttack: false,
    ),
    'page.delete': const PageDeleteOp(
      opId: 'op',
      pagePublicId: 'page-a',
      expectedStrategyRevision: 1,
    ),
    'page.reorder': const PageReorderOp(
      opId: 'op',
      pagePublicId: 'page-a',
      sortIndex: 1,
      expectedStrategyRevision: 1,
    ),
    'pageContent.patch': const PageSettingsPatchOp(
      opId: 'op',
      pagePublicId: 'page-a',
      settings: PageSettings(
        agentSize: 2,
        abilitySize: 1,
        useNeutralTeamColors: true,
      ),
      expectedPageSettingsRevision: 1,
    ),
    'element.add': ElementAddOp(
      opId: 'op',
      elementPublicId: 'viper',
      pagePublicId: 'page-a',
      payload: agentPayload('viper', {}),
      sortIndex: 2,
    ),
    'element.add bringing back a deleted agent': ElementAddOp(
      opId: 'op',
      elementPublicId: 'omen',
      pagePublicId: 'page-b',
      payload: agentPayload('omen', {}),
      sortIndex: 3,
      expectedElementRevision: 4,
    ),
    'element.patch written whole': ElementPatchOp(
      opId: 'op',
      elementPublicId: 'jett',
      expectedElementRevision: 1,
      payload: edited,
      sortIndex: 4,
      pagePublicId: 'page-b',
    ),
    'element.patch merged': ElementPatchOp(
      opId: 'op',
      elementPublicId: 'jett',
      expectedElementRevision: 1,
      payload: edited,
      sortIndex: 4,
      merge: FieldMerge(fields: ['isAlly', '@sortIndex']),
    ),
    'element.patch merged with a base': ElementPatchOp(
      opId: 'op',
      elementPublicId: 'jett',
      expectedElementRevision: 1,
      payload: edited,
      merge: FieldMerge(fields: ['isAlly'], base: {'isAlly': true}),
    ),
    'element.delete': const ElementDeleteOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'page-a',
      expectedElementRevision: 1,
    ),
    'element.delete, last writer wins': const ElementDeleteOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'page-a',
      expectedElementRevision: 1,
      lastWriterWins: true,
    ),
    'element.reorder': const ElementReorderOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'page-a',
      sortIndex: 9,
      expectedElementRevision: 1,
    ),
    'lineup.add': LineupGroupAddOp(
      opId: 'op',
      lineupPublicId: 'g2',
      pagePublicId: 'page-b',
      payload: _group('', id: 'g2'),
      sortIndex: 0,
    ),
    'lineup.patch written whole': LineupGroupPatchOp(
      opId: 'op',
      lineupPublicId: 'g1',
      expectedLineupRevision: 1,
      payload: _group('jump throw'),
      sortIndex: 2,
    ),
    'lineup.patch merged': LineupGroupPatchOp(
      opId: 'op',
      lineupPublicId: 'g1',
      expectedLineupRevision: 1,
      payload: _group('jump throw'),
      merge: FieldMerge(fields: ['links/k1']),
    ),
    'lineup.delete': const LineupGroupDeleteOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'page-a',
      expectedLineupRevision: 1,
    ),
    'lineup.reorder': const LineupGroupReorderOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'page-a',
      sortIndex: 3,
      expectedLineupRevision: 1,
    ),
  };

  test('the cases cover every op type', () {
    expect({for (final op in ops.values) op.type}, OpType.values.toSet());
  });

  for (final MapEntry(key: name, value: op) in ops.entries) {
    test('$name found again at startup leaves the rows as one apply did', () {
      final ids = Ids();
      final once = rows.withRows(
        applied(applyOp(rows, op, newId: ids.call)).rows,
      );
      final again = applyOp(once, op, newId: ids.call);
      expect(describe(again), 'unchanged');
      expect(once, isNot(rows));
    });
  }
}
