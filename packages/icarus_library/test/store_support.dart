import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

bool readsKnownKinds(ElementPayload payload) => true;

final createdAt = DateTime.utc(2026, 1, 2, 3);

final editedAt = DateTime.utc(2026, 11, 20, 12);

DateTime fixedClock() => editedAt;

typedef Contents = Map<String, Map<String, String>>;

const _contentsEqual = DeepCollectionEquality();

bool sameContents(Contents left, Contents right) =>
    _contentsEqual.equals(left, right);

String canonicalRow(Row row) => jsonEncode(sortedJson(row.toJson()));

Object? sortedJson(Object? value) => switch (value) {
  final Map<String, Object?> map => {
    for (final key in map.keys.toList()..sort()) key: sortedJson(map[key]),
  },
  final List<Object?> list => [for (final item in list) sortedJson(item)],
  _ => value,
};

Future<Contents> settledContentsOf(Contents disk) async {
  final engine = MemoryEngine(disk);
  await (await openStore(engine)).close();
  return engine.contents;
}

Contents withoutJournal(Contents contents) => {
  for (final MapEntry(:key, :value) in contents.entries)
    if (key != 'journal') key: value,
};

Future<LibraryStore> openStore(StorageEngine engine) async =>
    switch (await LibraryStore.open(
      engine,
      canRead: readsKnownKinds,
      clock: fixedClock,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('store did not open: $problem'),
    };

T savedValue<T, R>(Saving<T, R> result) => switch (result) {
  Saved(:final value) => value,
  final other => fail('expected a save, got ${describeSaving(other)}'),
};

String describeSaving<S, R>(Saving<S, R> result) => switch (result) {
  Saved() => 'saved',
  NothingToSave() => 'nothing to save',
  Refused(:final reason) => 'refused: $reason',
  NotSaved(:final failure) => 'not saved: $failure',
  SaveInDoubt(:final failure) => 'in doubt: $failure',
};

PageContent pageOf(Reading<PageContent> reading) => switch (reading) {
  Found(:final value) => value,
  final other => fail('expected the page, got $other'),
};

StrategyContent strategyOf(Reading<StrategyContent> reading) =>
    switch (reading) {
      Found(:final value) => value,
      final other => fail('expected the strategy, got $other'),
    };

final class CountingEngine implements StorageEngine {
  CountingEngine(this.inner);

  final StorageEngine inner;
  final reads = <(String, String)>[];
  final listings = <(String, String)>[];
  final written = <(String, String)>[];
  final deleted = <(String, String)>[];

  int get keyWrites => written.length + deleted.length;

  void reset() {
    reads.clear();
    listings.clear();
    written.clear();
    deleted.clear();
  }

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  Future<Stored<String?>> read(String area, String key) {
    reads.add((area, key));
    return inner.read(area, key);
  }

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) {
    listings.add((area, prefix));
    return inner.keys(area, prefix);
  }

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) {
    written.addAll([for (final key in values.keys) (area, key)]);
    return inner.write(area, values);
  }

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) {
    final all = keys.toList();
    deleted.addAll([for (final key in all) (area, key)]);
    return inner.delete(area, all);
  }
}

const crashed = DeviceFailure('the app stopped');

final class CrashingEngine implements StorageEngine {
  CrashingEngine(this.inner, {required int afterWrites}) : _left = afterWrites;

  final StorageEngine inner;
  int _left;

  bool get hasCrashed => _left < 0;

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  Future<Stored<String?>> read(String area, String key) => hasCrashed
      ? Future.value(const StorageFailed(crashed))
      : inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) => hasCrashed
      ? Future.value(const StorageFailed(crashed))
      : inner.keys(area, prefix);

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) async {
    final allowed = Map.fromEntries(values.entries.take(_spend(values.length)));
    if (allowed.isNotEmpty) await inner.write(area, allowed);
    return allowed.length == values.length
        ? const Done(null)
        : const StorageFailed(crashed);
  }

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) async {
    final all = keys.toList();
    final allowed = all.take(_spend(all.length)).toList();
    if (allowed.isNotEmpty) await inner.delete(area, allowed);
    return allowed.length == all.length
        ? const Done(null)
        : const StorageFailed(crashed);
  }

  int _spend(int wanted) {
    if (hasCrashed) return 0;
    if (wanted <= _left) {
      _left -= wanted;
      return wanted;
    }
    final spent = _left;
    _left = -1;
    return spent;
  }
}

final class LimitedEngine implements StorageEngine {
  LimitedEngine(this.inner, {required this.maxKeyLength});

  final StorageEngine inner;

  @override
  final int maxKeyLength;

  @override
  Future<Stored<String?>> read(String area, String key) =>
      inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      inner.keys(area, prefix);

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) =>
      inner.write(area, values);

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) =>
      inner.delete(area, keys);
}

final class FlakyEngine implements StorageEngine {
  FlakyEngine(this.inner);

  final StorageEngine inner;
  final failing = <int>{};
  final landing = <int>{};
  int _calls = 0;

  int get calls => _calls;

  bool _fails() => failing.contains(_calls++);

  bool _lands() => landing.contains(_calls - 1);

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  Future<Stored<String?>> read(String area, String key) =>
      inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      inner.keys(area, prefix);

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) async {
    if (!_fails()) return inner.write(area, values);
    if (_lands()) await inner.write(area, values);
    return const StorageFailed(DeviceFailure('disk full'));
  }

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) => _fails()
      ? Future.value(const StorageFailed(DeviceFailure('disk full')))
      : inner.delete(area, keys);
}

Map<String, Object?> origin(String id) => {
  'id': id,
  'agent': {'type': 'sova', 'lineUpID': id},
};

Map<String, Object?> landing(String id) => {
  'id': id,
  'ability': {'type': 'recon', 'lineUpID': id},
};

LineupGroupPayload lineupPayload(String id, {String notes = ''}) =>
    LineupGroupPayload(
      payloadVersion: 1,
      data: {
        'id': id,
        'origins': [origin('$id-o')],
        'landings': [landing('$id-l')],
        'links': [
          {
            'id': '$id-k',
            'originId': '$id-o',
            'landingId': '$id-l',
            'notes': notes,
          },
        ],
      },
    );

LiveLineupGroup lineupGroup(String id, {String pageId = 'page-a'}) =>
    LiveLineupGroup(
      strategyPublicId: strategyId,
      publicId: id,
      pagePublicId: pageId,
      payload: lineupPayload(id),
      sortIndex: 0,
      revision: 1,
    );

LiveElement agent(
  String id, {
  String type = 'jett',
  String pageId = 'page-a',
  int sortIndex = 0,
}) => element(
  id,
  pageId: pageId,
  sortIndex: sortIndex,
  fields: {
    'type': type,
    'position': {'dx': 10, 'dy': 20},
  },
);

LiveElement drawing(String id, {String pageId = 'page-a', int points = 40}) =>
    LiveElement(
      publicId: id,
      pagePublicId: pageId,
      payload: ElementPayload(
        kind: ElementKind.drawing,
        payloadVersion: 1,
        data: {
          'id': id,
          'elementType': 'drawing',
          'points': [
            for (var i = 0; i < points; i++) {'dx': i * 1.5, 'dy': i * 0.75},
          ],
        },
      ),
      sortIndex: 0,
      revision: 1,
    );

const unreadableElementJson =
    '{"deleted":false,"pagePublicId":"page-a","payload":{"data":{"flicker":[1,2,3],"id":"smoke"},"kind":"hologram","payloadVersion":1},"publicId":"smoke","revision":7,"sortIndex":5,"newRowField":"kept"}';

const unknownRowJson = '{"publicId":"pin-1","pinned":true}';

const garbledJson = '{"publicId": "half';

StrategyRowSet sampleStrategy() => StrategyRowSet(
  strategy: const StrategyRow(
    publicId: strategyId,
    name: 'Retake B',
    mapData: 'ascent',
    revision: 1,
  ),
  pages: [
    page('page-a', sortIndex: 0),
    page('page-b', sortIndex: 1),
    LivePage(
      publicId: 'page-c',
      strategyPublicId: strategyId,
      name: 'Page 3',
      sortIndex: 2,
      isAttack: false,
      revision: 1,
    ),
  ],
  settings: [settings('page-a'), settings('page-b'), settings('page-c')],
  elements: [
    agent('jett'),
    agent('sova', type: 'sova', sortIndex: 1),
    drawing('line'),
    agent('omen', type: 'omen', pageId: 'page-b'),
    agent('kayo', type: 'kayo', pageId: 'page-c'),
  ],
  lineupGroups: [lineupGroup('g1')],
);

Future<MemoryEngine> seededEngine() async {
  final engine = MemoryEngine();
  final store = await openStore(engine);
  savedValue(
    await store.editLibrary([
      AddStrategy(sampleStrategy(), createdAt: createdAt, updatedAt: createdAt),
    ]),
  );
  await store.close();
  await engine.write('strategy/$strategyId', {
    'content/page-a/element/smoke': unreadableElementJson,
    'content/page-a/pin/pin-1': unknownRowJson,
    'content/page-a/element/garbled': garbledJson,
  });
  final rebuilding = await openStore(engine);
  savedValue(await rebuilding.rebuildSummary(strategyId));
  await rebuilding.close();
  return engine;
}

Map<String, StrategyOp> everyOpType() => {
  'strategy.patch': const StrategyPatchOp(
    opId: 'op-strategy',
    expectedStrategyRevision: 1,
    name: 'Retake A',
  ),
  'page.add': const PageAddOp(
    opId: 'op-page-add',
    pagePublicId: 'page-new',
    sortIndex: 1,
    expectedStrategyRevision: 1,
    name: 'Fresh',
    settings: defaultSettings,
  ),
  'page.add copying a page': const PageAddOp(
    opId: 'op-page-copy',
    pagePublicId: 'page-copy',
    sortIndex: 3,
    expectedStrategyRevision: 1,
    name: 'Copy',
    settings: defaultSettings,
    copyContentFromPagePublicId: 'page-a',
  ),
  'page.patch': const PagePatchOp(
    opId: 'op-page-patch',
    pagePublicId: 'page-b',
    expectedPageRevision: 1,
    name: 'Retake',
    isAttack: false,
  ),
  'page.delete': const PageDeleteOp(
    opId: 'op-page-delete',
    pagePublicId: 'page-a',
    expectedStrategyRevision: 1,
  ),
  'page.reorder': const PageReorderOp(
    opId: 'op-page-reorder',
    pagePublicId: 'page-c',
    sortIndex: 0,
    expectedStrategyRevision: 1,
  ),
  'pageContent.patch': const PageSettingsPatchOp(
    opId: 'op-settings',
    pagePublicId: 'page-a',
    settings: PageSettings(
      agentSize: 2,
      abilitySize: 1.5,
      useNeutralTeamColors: true,
    ),
    expectedPageSettingsRevision: 1,
  ),
  'element.add': ElementAddOp(
    opId: 'op-element-add',
    elementPublicId: 'raze',
    pagePublicId: 'page-a',
    payload: agent('raze', type: 'raze').payload,
    sortIndex: 4,
  ),
  'element.patch': ElementPatchOp(
    opId: 'op-element-patch',
    elementPublicId: 'jett',
    expectedElementRevision: 1,
    payload: agentPayload('jett', {
      'type': 'jett',
      'position': {'dx': 300, 'dy': 400},
    }),
    merge: FieldMerge(fields: ['position']),
  ),
  'element.patch to another page': const ElementPatchOp(
    opId: 'op-element-move',
    elementPublicId: 'jett',
    expectedElementRevision: 1,
    pagePublicId: 'page-b',
  ),
  'element.delete': const ElementDeleteOp(
    opId: 'op-element-delete',
    elementPublicId: 'sova',
    pagePublicId: 'page-a',
    expectedElementRevision: 1,
  ),
  'element.reorder': const ElementReorderOp(
    opId: 'op-element-reorder',
    elementPublicId: 'line',
    pagePublicId: 'page-a',
    sortIndex: 9,
    expectedElementRevision: 1,
  ),
  'lineup.add': LineupGroupAddOp(
    opId: 'op-lineup-add',
    lineupPublicId: 'g2',
    pagePublicId: 'page-b',
    payload: lineupPayload('g2'),
    sortIndex: 0,
  ),
  'lineup.patch': LineupGroupPatchOp(
    opId: 'op-lineup-patch',
    lineupPublicId: 'g1',
    expectedLineupRevision: 1,
    payload: lineupPayload('g1', notes: 'jump throw'),
  ),
  'lineup.delete': const LineupGroupDeleteOp(
    opId: 'op-lineup-delete',
    lineupPublicId: 'g1',
    pagePublicId: 'page-a',
    expectedLineupRevision: 1,
  ),
  'lineup.reorder': const LineupGroupReorderOp(
    opId: 'op-lineup-reorder',
    lineupPublicId: 'g1',
    pagePublicId: 'page-a',
    sortIndex: 3,
    expectedLineupRevision: 1,
  ),
};
