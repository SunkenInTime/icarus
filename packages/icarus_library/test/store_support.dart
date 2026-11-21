import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

const readsKnownKinds = CanRead(
  element: _anyElement,
  lineupGroup: notesAreText,
);

bool _anyElement(ElementPayload payload) => true;

bool notesAreText(LineupGroupPayload payload) =>
    switch (payload.data['links']) {
      final JsonList links => links.every(
        (link) => switch (link) {
          final JsonObject link when link.containsKey('notes') =>
            link['notes'] == null || link['notes'] is String,
          _ => true,
        },
      ),
      _ => true,
    };

final editedAt = DateTime.utc(2026, 11, 20, 12);

DateTime fixedClock() => editedAt;

typedef Contents = Map<String, Map<String, String>>;

const _contentsEqual = DeepCollectionEquality();

bool sameContents(Contents left, Contents right) =>
    _contentsEqual.equals(left, right);

String pageName(String page) => 'page/${digestOf(page)}';

String settingsName(String page) => 'settings/${digestOf(page)}';

String elementName(String page, String id) =>
    'content/${digestOf(page)}/e/${digestOf(id)}';

String lineupName(String page, String id) =>
    'content/${digestOf(page)}/l/${digestOf(id)}';

String summaryName(String strategy) => 'summary/${digestOf(strategy)}';

String folderName(String folder) => 'folder/${digestOf(folder)}';

String canonicalRow(Row row) => jsonEncode(sortedJson(row.toJson()));

Object? sortedJson(Object? value) => switch (value) {
  final Map<String, Object?> map => {
    for (final key in map.keys.toList()..sort()) key: sortedJson(map[key]),
  },
  final List<Object?> list => [for (final item in list) sortedJson(item)],
  _ => value,
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

Future<LibraryStore> openOn(Contents contents) =>
    openStore(MemoryEngine(MemoryStorage(contents)));

Future<Contents> settled(Contents disk) async {
  final storage = MemoryStorage(disk);
  await (await openStore(MemoryEngine(storage))).close();
  return storage.contents;
}

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

LibraryList listOf(LibraryStore store) => switch (store.library) {
  LibraryOpen(:final list) => list,
  LibraryShut(:final failure) => fail('the library is shut: $failure'),
};

ReadableStrategy headerOf(StrategyContent content) =>
    switch (content.strategy) {
      final ReadableStrategy header => header,
      final other => fail('the strategy row is unreadable: $other'),
    };

ElementRow elementOn(PageContent page, String id) =>
    page.elements.firstWhere((row) => row.publicId == id);

final class WrappingEngine implements StorageEngine {
  WrappingEngine(this.inner, this.wrap);

  final StorageEngine inner;
  final StorageLease Function(StorageLease lease) wrap;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
    Leased(:final lease) => Leased(wrap(lease)),
    final other => other,
  };
}

abstract base class ForwardingLease implements StorageLease {
  ForwardingLease(this.inner);

  final StorageLease inner;

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  LeaseStatus get status => inner.status;

  @override
  Future<KeyRead> read(String area, String key) => inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      inner.keys(area, prefix);

  @override
  Future<Stored<List<String>>> areas(String prefix) => inner.areas(prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      inner.entries(area, prefix);

  @override
  Future<Committing> commit(List<Change> changes) => inner.commit(changes);

  @override
  Future<Releasing> release() => inner.release();
}

final class Counts {
  final reads = <(String, String)>[];
  final areaListings = <String>[];
  final keyListings = <(String, String)>[];
  final entryListings = <(String, String)>[];
  final listedEntries = <(String, String)>[];
  final written = <(String, String)>[];
  final deleted = <(String, String)>[];
  int listedKeys = 0;
  int commits = 0;

  int get keyWrites => written.length + deleted.length;

  void reset() {
    reads.clear();
    areaListings.clear();
    keyListings.clear();
    entryListings.clear();
    listedEntries.clear();
    written.clear();
    deleted.clear();
    listedKeys = 0;
    commits = 0;
  }
}

final class CountingLease extends ForwardingLease {
  CountingLease(super.inner, this.counts);

  final Counts counts;

  @override
  Future<KeyRead> read(String area, String key) {
    counts.reads.add((area, key));
    return super.read(area, key);
  }

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async {
    counts.entryListings.add((area, prefix));
    final result = await super.entries(area, prefix);
    if (result case Done(:final value)) {
      counts.listedEntries.addAll([
        for (final entry in value) (area, entry.key),
      ]);
    }
    return result;
  }

  @override
  Future<Stored<List<String>>> areas(String prefix) {
    counts.areaListings.add(prefix);
    return super.areas(prefix);
  }

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async {
    counts.keyListings.add((area, prefix));
    final result = await super.keys(area, prefix);
    if (result case Done(:final value)) counts.listedKeys += value.length;
    return result;
  }

  @override
  Future<Committing> commit(List<Change> changes) {
    counts.commits++;
    for (final change in changes) {
      switch (change) {
        case Put(:final area, :final key):
          counts.written.add((area, key));
        case Delete(:final area, :final key):
          counts.deleted.add((area, key));
        case ClearArea(:final area):
          counts.deleted.add((area, '*'));
      }
    }
    return super.commit(changes);
  }
}

(StorageEngine, Counts) counting(StorageEngine inner) {
  final counts = Counts();
  return (
    WrappingEngine(inner, (lease) => CountingLease(lease, counts)),
    counts,
  );
}

enum Failing { refused, landed, lost }

final class FlakyLease extends ForwardingLease {
  FlakyLease(super.inner, this.failing);

  final Map<int, Failing> failing;
  int calls = 0;

  @override
  Future<Committing> commit(List<Change> changes) async {
    switch (failing[calls++]) {
      case null:
        return super.commit(changes);
      case Failing.refused:
        return const CommitRefused(DeviceFailure('disk full'));
      case Failing.landed:
        await super.commit(changes);
        return const CommitUnknown(DeviceFailure('lost the reply'));
      case Failing.lost:
        return const CommitUnknown(DeviceFailure('lost the request'));
    }
  }
}

StorageEngine flaky(StorageEngine inner, Map<int, Failing> failing) =>
    WrappingEngine(inner, (lease) => FlakyLease(lease, failing));

final class LimitedLease extends ForwardingLease {
  LimitedLease(super.inner, this.maxKeyLength);

  @override
  final int maxKeyLength;
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

LiveLineupGroup lineupGroup(
  String id, {
  String pageId = 'page-a',
  String strategy = strategyId,
}) => LiveLineupGroup(
  strategyPublicId: strategy,
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

StrategyRowSet sampleStrategy({String id = strategyId, String prefix = ''}) =>
    StrategyRowSet(
      strategy: strategyRow(publicId: id),
      pages: [
        LivePage(
          publicId: '${prefix}page-a',
          strategyPublicId: id,
          name: 'Page 1',
          sortIndex: 0,
          isAttack: true,
          revision: 1,
        ),
        LivePage(
          publicId: '${prefix}page-b',
          strategyPublicId: id,
          name: 'Page 2',
          sortIndex: 1,
          isAttack: true,
          revision: 1,
        ),
        LivePage(
          publicId: '${prefix}page-c',
          strategyPublicId: id,
          name: 'Page 3',
          sortIndex: 2,
          isAttack: false,
          revision: 1,
        ),
      ],
      settings: [
        settings('${prefix}page-a'),
        settings('${prefix}page-b'),
        settings('${prefix}page-c'),
      ],
      elements: [
        agent('${prefix}jett', pageId: '${prefix}page-a'),
        agent(
          '${prefix}sova',
          type: 'sova',
          sortIndex: 1,
          pageId: '${prefix}page-a',
        ),
        drawing('${prefix}line', pageId: '${prefix}page-a'),
        agent('${prefix}omen', type: 'omen', pageId: '${prefix}page-b'),
        agent('${prefix}kayo', type: 'kayo', pageId: '${prefix}page-c'),
      ],
      lineupGroups: [
        lineupGroup('${prefix}g1', pageId: '${prefix}page-a', strategy: id),
      ],
    );

final sampleArea = strategyArea(strategyId);

final pinName = 'content/${digestOf('page-a')}/pin/${digestOf('pin-1')}';

Future<Contents> seededClean() async {
  final storage = MemoryStorage();
  final store = await openStore(MemoryEngine(storage));
  savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
  await store.close();
  return storage.contents;
}

Future<Contents> seededContents() async {
  final storage = MemoryStorage();
  final engine = MemoryEngine(storage);
  final store = await openStore(engine);
  savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
  await store.close();
  final withRaw = {
    ...storage.contents,
    sampleArea: {
      ...storage.contents[sampleArea]!,
      elementName('page-a', 'smoke'): unreadableElementJson,
      pinName: unknownRowJson,
      elementName('page-a', 'garbled'): garbledJson,
    },
  };
  final rebuilding = MemoryStorage(withRaw);
  final store2 = await openStore(MemoryEngine(rebuilding));
  savedValue(await store2.rebuildSummary(strategyId));
  await store2.close();
  return rebuilding.contents;
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
    copyContentFromPagePublicId: 'page-b',
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

final moveJett = everyOpType()['element.patch']!;
