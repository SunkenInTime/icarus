import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/collab/field_merge.dart' as app;
import 'package:icarus_library/icarus_library.dart' as store;

const _json = DeepCollectionEquality();

final _elementData = <String, Object?>{
  'id': 'jett',
  'elementType': 'agent',
  'position': {'x': 1.5, 'y': 2.0},
};

final _lineupData = <String, Object?>{'id': 'g1', 'links': <Object?>[]};

const _settings = {
  'agentSize': 1.25,
  'abilitySize': 0.75,
  'useNeutralTeamColors': true,
};

const _palette = {
  'base': '#101010',
  'detail': '#202020',
  'highlight': '#303030'
};

final _storeElement = store.ElementPayload(
  kind: store.ElementKind.agent,
  payloadVersion: 2,
  data: _elementData,
);

final _appElement = {
  'kind': 'agent',
  'payloadVersion': 2,
  'data': _elementData,
};

final _storeLineup = store.LineupGroupPayload(
  payloadVersion: 1,
  data: _lineupData,
);

final _appLineup = {
  'kind': 'lineups',
  'payloadVersion': 1,
  'data': _lineupData
};

const _storeSettings = store.PageSettings(
  agentSize: 1.25,
  abilitySize: 0.75,
  useNeutralTeamColors: true,
);

const _storePalette = store.ThemePalette(
  base: '#101010',
  detail: '#202020',
  highlight: '#303030',
);

const _mergeFields = ['position', '@sortIndex', 'caption'];

const _mergeBase = <String, Object?>{
  'position': {'x': 1.0, 'y': 1.0},
  '@sortIndex': 3,
};

final _pairs = <String, (app.StrategyOp, store.StrategyOp)>{
  'strategy.patch without fields': (
    const app.StrategyPatchOp(
      opId: 'op',
      payload: {},
      expectedStrategyRevision: 4,
    ),
    const store.StrategyPatchOp(opId: 'op', expectedStrategyRevision: 4),
  ),
  'strategy.patch setting every field': (
    const app.StrategyPatchOp(
      opId: 'op',
      payload: {
        'name': 'Retake B',
        'mapData': 'bind',
        'themeProfileId': 'ember',
        'themeOverridePalette': _palette,
      },
      expectedStrategyRevision: 4,
    ),
    const store.StrategyPatchOp(
      opId: 'op',
      expectedStrategyRevision: 4,
      name: 'Retake B',
      mapData: 'bind',
      themeProfile: store.SetValue('ember'),
      themeOverridePalette: store.SetValue(_storePalette),
    ),
  ),
  'strategy.patch clearing the theme': (
    const app.StrategyPatchOp(
      opId: 'op',
      payload: {
        'clearThemeProfileId': true,
        'clearThemeOverridePalette': true,
      },
      expectedStrategyRevision: 4,
    ),
    const store.StrategyPatchOp(
      opId: 'op',
      expectedStrategyRevision: 4,
      themeProfile: store.ClearValue(),
      themeOverridePalette: store.ClearValue(),
    ),
  ),
  'page.add without optional fields': (
    const app.PageAddOp(
      opId: 'op',
      pagePublicId: 'p',
      payload: {},
      sortIndex: 1,
      expectedStrategyRevision: 4,
    ),
    const store.PageAddOp(
      opId: 'op',
      pagePublicId: 'p',
      sortIndex: 1,
      expectedStrategyRevision: 4,
    ),
  ),
  'page.add with every field': (
    const app.PageAddOp(
      opId: 'op',
      pagePublicId: 'p',
      payload: {
        'name': 'Page 2',
        'isAutoNamed': true,
        'settings': _settings,
        'isAttack': false,
      },
      sortIndex: 1,
      expectedStrategyRevision: 4,
      copyContentFromPagePublicId: 'q',
    ),
    const store.PageAddOp(
      opId: 'op',
      pagePublicId: 'p',
      sortIndex: 1,
      expectedStrategyRevision: 4,
      name: 'Page 2',
      isAutoNamed: true,
      settings: _storeSettings,
      isAttack: false,
      copyContentFromPagePublicId: 'q',
    ),
  ),
  'page.patch without fields': (
    const app.PagePatchOp(
      opId: 'op',
      pagePublicId: 'p',
      payload: {},
      expectedPageRevision: 2,
    ),
    const store.PagePatchOp(
      opId: 'op',
      pagePublicId: 'p',
      expectedPageRevision: 2,
    ),
  ),
  'page.patch with every field': (
    const app.PagePatchOp(
      opId: 'op',
      pagePublicId: 'p',
      payload: {'name': 'Exec', 'isAutoNamed': false, 'isAttack': true},
      expectedPageRevision: 2,
    ),
    const store.PagePatchOp(
      opId: 'op',
      pagePublicId: 'p',
      expectedPageRevision: 2,
      name: 'Exec',
      isAutoNamed: false,
      isAttack: true,
    ),
  ),
  'page.delete': (
    const app.PageDeleteOp(
      opId: 'op',
      pagePublicId: 'p',
      expectedStrategyRevision: 4,
    ),
    const store.PageDeleteOp(
      opId: 'op',
      pagePublicId: 'p',
      expectedStrategyRevision: 4,
    ),
  ),
  'page.reorder': (
    const app.PageReorderOp(
      opId: 'op',
      pagePublicId: 'p',
      sortIndex: 0,
      expectedStrategyRevision: 4,
    ),
    const store.PageReorderOp(
      opId: 'op',
      pagePublicId: 'p',
      sortIndex: 0,
      expectedStrategyRevision: 4,
    ),
  ),
  'pageContent.patch': (
    const app.PageContentPatchOp(
      opId: 'op',
      pagePublicId: 'p',
      settings: _settings,
      expectedPageContentRevision: 3,
    ),
    const store.PageSettingsPatchOp(
      opId: 'op',
      pagePublicId: 'p',
      settings: _storeSettings,
      expectedPageSettingsRevision: 3,
    ),
  ),
  'element.add of a new element': (
    app.ElementAddOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      payload: _appElement,
      sortIndex: 5,
    ),
    store.ElementAddOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      payload: _storeElement,
      sortIndex: 5,
    ),
  ),
  'element.add bringing one back': (
    app.ElementAddOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      payload: _appElement,
      sortIndex: 5,
      expectedElementRevision: 7,
    ),
    store.ElementAddOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      payload: _storeElement,
      sortIndex: 5,
      expectedElementRevision: 7,
    ),
  ),
  'element.patch without optional fields': (
    const app.ElementPatchOp(
      opId: 'op',
      elementPublicId: 'jett',
      expectedElementRevision: 7,
    ),
    const store.ElementPatchOp(
      opId: 'op',
      elementPublicId: 'jett',
      expectedElementRevision: 7,
    ),
  ),
  'element.patch with every field and a live merge': (
    app.ElementPatchOp(
      opId: 'op',
      elementPublicId: 'jett',
      expectedElementRevision: 7,
      pagePublicId: 'p',
      payload: _appElement,
      sortIndex: 2,
      merge: const app.FieldMerge(fields: _mergeFields),
    ),
    store.ElementPatchOp(
      opId: 'op',
      elementPublicId: 'jett',
      expectedElementRevision: 7,
      pagePublicId: 'p',
      payload: _storeElement,
      sortIndex: 2,
      merge: store.FieldMerge(fields: _mergeFields),
    ),
  ),
  'element.patch with an offline merge': (
    app.ElementPatchOp(
      opId: 'op',
      elementPublicId: 'jett',
      expectedElementRevision: 7,
      payload: _appElement,
      merge: const app.FieldMerge(fields: _mergeFields, base: _mergeBase),
    ),
    store.ElementPatchOp(
      opId: 'op',
      elementPublicId: 'jett',
      expectedElementRevision: 7,
      payload: _storeElement,
      merge: store.FieldMerge(fields: _mergeFields, base: _mergeBase),
    ),
  ),
  'element.delete checked': (
    const app.ElementDeleteOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      expectedElementRevision: 7,
    ),
    const store.ElementDeleteOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      expectedElementRevision: 7,
    ),
  ),
  'element.delete last writer wins': (
    const app.ElementDeleteOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      expectedElementRevision: 7,
      lastWriterWins: true,
    ),
    const store.ElementDeleteOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      expectedElementRevision: 7,
      lastWriterWins: true,
    ),
  ),
  'element.reorder': (
    const app.ElementReorderOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      sortIndex: 9,
      expectedElementRevision: 7,
    ),
    const store.ElementReorderOp(
      opId: 'op',
      elementPublicId: 'jett',
      pagePublicId: 'p',
      sortIndex: 9,
      expectedElementRevision: 7,
    ),
  ),
  'lineup.add of a new group': (
    app.LineupAddOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      payload: _appLineup,
      sortIndex: 0,
    ),
    store.LineupGroupAddOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      payload: _storeLineup,
      sortIndex: 0,
    ),
  ),
  'lineup.add bringing one back': (
    app.LineupAddOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      payload: _appLineup,
      sortIndex: 0,
      expectedLineupRevision: 3,
    ),
    store.LineupGroupAddOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      payload: _storeLineup,
      sortIndex: 0,
      expectedLineupRevision: 3,
    ),
  ),
  'lineup.patch without optional fields': (
    const app.LineupPatchOp(
      opId: 'op',
      lineupPublicId: 'g1',
      expectedLineupRevision: 3,
    ),
    const store.LineupGroupPatchOp(
      opId: 'op',
      lineupPublicId: 'g1',
      expectedLineupRevision: 3,
    ),
  ),
  'lineup.patch with every field': (
    app.LineupPatchOp(
      opId: 'op',
      lineupPublicId: 'g1',
      expectedLineupRevision: 3,
      pagePublicId: 'p',
      payload: _appLineup,
      sortIndex: 1,
      merge: const app.FieldMerge(
        fields: ['links/k1'],
        base: {'links/k1': null},
      ),
    ),
    store.LineupGroupPatchOp(
      opId: 'op',
      lineupPublicId: 'g1',
      expectedLineupRevision: 3,
      pagePublicId: 'p',
      payload: _storeLineup,
      sortIndex: 1,
      merge: store.FieldMerge(
        fields: ['links/k1'],
        base: {'links/k1': null},
      ),
    ),
  ),
  'lineup.delete checked': (
    const app.LineupDeleteOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      expectedLineupRevision: 3,
    ),
    const store.LineupGroupDeleteOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      expectedLineupRevision: 3,
    ),
  ),
  'lineup.delete last writer wins': (
    const app.LineupDeleteOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      expectedLineupRevision: 3,
      lastWriterWins: true,
    ),
    const store.LineupGroupDeleteOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      expectedLineupRevision: 3,
      lastWriterWins: true,
    ),
  ),
  'lineup.reorder': (
    const app.LineupReorderOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      sortIndex: 2,
      expectedLineupRevision: 3,
    ),
    const store.LineupGroupReorderOp(
      opId: 'op',
      lineupPublicId: 'g1',
      pagePublicId: 'p',
      sortIndex: 2,
      expectedLineupRevision: 3,
    ),
  ),
};

void main() {
  test('the cases cover all fourteen op types', () {
    expect(
      {for (final (_, op) in _pairs.values) op.type},
      store.OpType.values.toSet(),
    );
    expect(
      {for (final (op, _) in _pairs.values) op.type.wireName},
      {for (final type in store.OpType.values) type.wireName},
    );
  });

  for (final MapEntry(key: name, value: (appOp, storeOp)) in _pairs.entries) {
    test('$name is sent the same by the app and the library', () {
      final sent = appOp.toConvexJson();
      expect(
        _json.equals(storeOp.toJson(), sent),
        isTrue,
        reason: 'library ${storeOp.toJson()}\napp     $sent',
      );
      final decoded = switch (store.StrategyOp.decode(sent)) {
        store.Read(:final value) => value,
        store.CouldNotRead(:final problem) => fail(problem),
      };
      expect(_json.equals(decoded.toJson(), sent), isTrue);
    });
  }

  test('the library reads the payload versions this build reads', () {
    expect(
      store.newestElementPayloadVersion,
      newestReadableCloudPayloadVersion,
    );
    expect(store.placeField, app.placeMergeField);
  });
}
