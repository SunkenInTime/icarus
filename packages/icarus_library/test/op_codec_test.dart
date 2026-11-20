import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final payload = agentPayload('jett', {
    'position': {'x': 1.5, 'y': 2},
  });
  final lineup = LineupGroupPayload(payloadVersion: 1, data: {'id': 'g1'});
  final mergeWithBase = FieldMerge(
    fields: ['position', '@sortIndex', 'caption'],
    base: {
      'position': {'x': 1, 'y': 1},
      '@sortIndex': 2,
    },
  );

  final ops = <StrategyOp>[
    const StrategyPatchOp(opId: 'a', expectedStrategyRevision: 1),
    const StrategyPatchOp(
      opId: 'b',
      expectedStrategyRevision: 1,
      name: 'Retake',
      mapData: 'bind',
      themeProfile: SetValue('ember'),
      themeOverridePalette: SetValue(
        ThemePalette(base: '#000', detail: '#111', highlight: '#222'),
      ),
    ),
    const StrategyPatchOp(
      opId: 'b2',
      expectedStrategyRevision: 1,
      themeProfile: ClearValue(),
      themeOverridePalette: ClearValue(),
    ),
    const PageAddOp(
      opId: 'c',
      pagePublicId: 'p',
      sortIndex: 0,
      expectedStrategyRevision: 1,
    ),
    const PageAddOp(
      opId: 'd',
      pagePublicId: 'p',
      sortIndex: 0,
      expectedStrategyRevision: 1,
      name: 'Page 1',
      isAutoNamed: true,
      isAttack: false,
      settings: defaultSettings,
      copyContentFromPagePublicId: 'q',
    ),
    const PagePatchOp(opId: 'e', pagePublicId: 'p', expectedPageRevision: 1),
    const PagePatchOp(
      opId: 'f',
      pagePublicId: 'p',
      expectedPageRevision: 1,
      name: 'Exec',
      isAutoNamed: false,
      isAttack: true,
    ),
    const PageDeleteOp(
      opId: 'g',
      pagePublicId: 'p',
      expectedStrategyRevision: 2,
    ),
    const PageReorderOp(
      opId: 'h',
      pagePublicId: 'p',
      sortIndex: 3,
      expectedStrategyRevision: 2,
    ),
    const PageSettingsPatchOp(
      opId: 'i',
      pagePublicId: 'p',
      settings: defaultSettings,
      expectedPageSettingsRevision: 4,
    ),
    ElementAddOp(
      opId: 'j',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      payload: payload,
      sortIndex: 0,
    ),
    ElementAddOp(
      opId: 'k',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      payload: payload,
      sortIndex: 0,
      expectedElementRevision: 5,
    ),
    const ElementPatchOp(
      opId: 'l',
      elementPublicId: 'jett',
      expectedElementRevision: 1,
    ),
    ElementPatchOp(
      opId: 'm',
      elementPublicId: 'jett',
      expectedElementRevision: 1,
      pagePublicId: 'p',
      payload: payload,
      sortIndex: 2,
      merge: mergeWithBase,
    ),
    const ElementDeleteOp(
      opId: 'n',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      expectedElementRevision: 1,
    ),
    const ElementDeleteOp(
      opId: 'o',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      expectedElementRevision: 1,
      lastWriterWins: true,
    ),
    const ElementReorderOp(
      opId: 'p',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      sortIndex: 1,
      expectedElementRevision: 1,
    ),
    LineupGroupAddOp(
      opId: 'q',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      payload: lineup,
      sortIndex: 0,
    ),
    LineupGroupPatchOp(
      opId: 'r',
      lineupPublicId: 'g1',
      expectedLineupRevision: 1,
      pagePublicId: 'p',
      payload: lineup,
      sortIndex: 0,
      merge: FieldMerge(fields: ['links/k1']),
    ),
    const LineupGroupDeleteOp(
      opId: 's',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      expectedLineupRevision: 1,
      lastWriterWins: true,
    ),
    const LineupGroupReorderOp(
      opId: 't',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      sortIndex: 2,
      expectedLineupRevision: 1,
    ),
  ];

  test('every op type comes back the same from the JSON it is sent as', () {
    expect({for (final op in ops) op.type}, OpType.values.toSet());
    for (final op in ops) {
      final decoded = readValue(
        StrategyOp.decode(jsonDecode(jsonEncode(op.toJson()))),
      );
      expect(decoded, op, reason: op.opId);
      expect(decoded.runtimeType, op.runtimeType, reason: op.opId);
    }
  });

  test('a merge base names a field that was absent without a value', () {
    expect(mergeWithBase.toJson()['base'], [
      {
        'field': 'position',
        'value': {'x': 1, 'y': 1},
      },
      {'field': '@sortIndex', 'value': 2},
      {'field': 'caption'},
    ]);
  });

  test('numbers that arrive as decimals read as the same whole numbers', () {
    final op = readValue(
      StrategyOp.decode({
        'opId': 'x',
        'type': 'element.reorder',
        'elementPublicId': 'jett',
        'pagePublicId': 'p',
        'sortIndex': 3.0,
        'expectedElementRevision': 2.0,
      }),
    );
    expect(
      op,
      const ElementReorderOp(
        opId: 'x',
        elementPublicId: 'jett',
        pagePublicId: 'p',
        sortIndex: 3,
        expectedElementRevision: 2,
      ),
    );
  });

  test('an op this build cannot read comes back as raw JSON, not a throw', () {
    final unreadable = <Map<String, Object?>>[
      {'opId': 'x', 'type': 'element.teleport'},
      {
        'opId': 'x',
        'type': 'lineup.add',
        'lineupPublicId': 'g1',
        'pagePublicId': 'p',
        'payload': {
          'kind': 'lineupOrigin',
          'payloadVersion': 1,
          'data': <String, Object?>{},
        },
        'sortIndex': 0,
      },
      {
        'opId': 'x',
        'type': 'strategy.patch',
        'payload': {'themeProfileId': 'ember', 'clearThemeProfileId': true},
        'expectedStrategyRevision': 1,
      },
      {
        'opId': 'x',
        'type': 'element.patch',
        'elementPublicId': 'jett',
        'expectedElementRevision': 1,
        'merge': {
          'fields': ['caption'],
          'base': <Object?>[],
        },
      },
      {
        'opId': 'x',
        'type': 'element.patch',
        'elementPublicId': 'jett',
        'expectedElementRevision': 1,
        'merge': {
          'fields': ['caption'],
          'base': [
            {'field': 'caption', 'value': 'a'},
            {'field': 'caption', 'value': 'b'},
          ],
        },
      },
      {
        'opId': 'x',
        'type': 'element.patch',
        'elementPublicId': 'jett',
        'expectedElementRevision': 1,
        'merge': {
          'fields': ['caption', 'caption'],
          'base': [
            {'field': 'caption', 'value': 'a'},
          ],
        },
      },
      {
        'opId': 'x',
        'type': 'lineup.add',
        'lineupPublicId': 'g1',
        'pagePublicId': 'p',
        'payload': {
          'kind': 'lineups',
          'payloadVersion': 2,
          'data': {'id': 'g1'},
        },
        'sortIndex': 0,
      },
      {
        'opId': 'x',
        'type': 'element.reorder',
        'elementPublicId': 'jett',
        'pagePublicId': 'p',
        'sortIndex': 1.5,
        'expectedElementRevision': 1,
      },
    ];
    for (final json in unreadable) {
      final decoded = StrategyOp.decode(json);
      expect(decoded, isA<CouldNotRead<StrategyOp>>(), reason: '$json');
      expect((decoded as CouldNotRead<StrategyOp>).json, same(json));
    }
  });
}
