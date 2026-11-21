import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

final _unreadable = {
  elementName('page-a', 'smoke'): unreadableElementJson,
  pinName: unknownRowJson,
  elementName('page-a', 'garbled'): garbledJson,
};

void expectUntouched(Contents contents) {
  for (final MapEntry(:key, :value) in _unreadable.entries) {
    expect(contents[sampleArea]?[key], value, reason: key);
  }
}

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = await seededContents();
  });

  test(
    'every op in turn leaves the rows this build cannot read as stored',
    () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(MemoryEngine(disk));
      for (final MapEntry(key: name, value: op) in everyOpType().entries) {
        final result = await store.commit(strategyId, op);
        expect(
          result,
          isNot(isA<NotSaved<Committed, CommitRefusal>>()),
          reason: name,
        );
        expectUntouched(disk.contents);
      }
      expect(
        await store.rebuildSummary(strategyId),
        isA<NothingToSave<StrategySummary, CommitRefusal>>(),
      );
      await store.close();
      expectUntouched(disk.contents);
      final reopened = await openOn(disk.contents);
      expect(
        await reopened.rebuildSummary(strategyId),
        isA<NothingToSave<StrategySummary, CommitRefusal>>(),
      );
      expectUntouched(disk.contents);
    },
  );

  test('each op type on its own leaves them as stored', () async {
    for (final MapEntry(key: name, value: op) in everyOpType().entries) {
      final disk = MemoryStorage(seeded);
      final store = await openStore(MemoryEngine(disk));
      savedValue(await store.commit(strategyId, op));
      expectUntouched(disk.contents);
      expect(
        reason: name,
        disk.contents[sampleArea]!.length,
        greaterThanOrEqualTo(seeded[sampleArea]!.length),
      );
    }
  });

  test('an op aimed at an element this build cannot read is refused', () async {
    final store = await openOn(seeded);
    final result = await store.commit(
      strategyId,
      const ElementDeleteOp(
        opId: 'delete-smoke',
        elementPublicId: 'smoke',
        pagePublicId: 'page-a',
        expectedElementRevision: 7,
      ),
    );
    expect(
      result,
      isA<Refused<Committed, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<OpRefusal>().having(
          (reason) => reason.refusal,
          'refusal',
          const UnreadableTarget(ElementKey('smoke')),
        ),
      ),
    );
  });

  test('an add over a stored row that is not JSON is refused', () async {
    final disk = MemoryStorage(seeded);
    final store = await openStore(MemoryEngine(disk));
    final result = await store.commit(
      strategyId,
      ElementAddOp(
        opId: 'add-garbled',
        elementPublicId: 'garbled',
        pagePublicId: 'page-a',
        payload: agent('garbled').payload,
        sortIndex: 0,
      ),
    );
    expect(
      result,
      isA<Refused<Committed, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<UnplacedRowInTheWay>().having(
          (reason) => reason.ref,
          'ref',
          StoredRowRef(sampleArea, elementName('page-a', 'garbled')),
        ),
      ),
    );
    expectUntouched(disk.contents);
  });

  test('a page copy carries an unreadable element as a new row', () async {
    final area = {...seeded[sampleArea]!}
      ..remove(elementName('page-a', 'garbled'))
      ..remove(pinName);
    final store = await openOn({...seeded, sampleArea: area});
    savedValue(
      await store.commit(
        strategyId,
        const PageAddOp(
          opId: 'copy-a',
          pagePublicId: 'page-copy',
          sortIndex: 3,
          expectedStrategyRevision: 1,
          settings: defaultSettings,
          copyContentFromPagePublicId: 'page-a',
        ),
      ),
    );
    final copy = pageOf(await store.readPage(strategyId, 'page-copy'));
    final carried = copy.elements.whereType<UnreadableElement>().single;
    final stored = (carried.stored! as JsonObject).toJson();
    expect(stored['newRowField'], 'kept');
    expect(stored['publicId'], carried.publicId);
  });

  final brokenGraphs =
      <String, Map<String, Object?> Function(Map<String, Object?> data)>{
        'links that are not items': (data) => {
          ...data,
          'links': ['not an item'],
        },
        'a link with no origin': (data) => {
          ...data,
          'links': [
            for (final link
                in (data['links']! as List<Object?>)
                    .cast<Map<String, Object?>>())
              {...link}..remove('originId'),
          ],
        },
        'a link whose notes this build cannot read': (data) => {
          ...data,
          'links': [
            for (final link
                in (data['links']! as List<Object?>)
                    .cast<Map<String, Object?>>())
              {...link, 'notes': true},
          ],
        },
        'a link to an origin the group does not hold': (data) => {
          ...data,
          'links': [
            for (final link
                in (data['links']! as List<Object?>)
                    .cast<Map<String, Object?>>())
              {...link, 'originId': 'elsewhere'},
          ],
        },
      };

  for (final MapEntry(key: what, value: breakIt) in brokenGraphs.entries) {
    test(
      'a lineup group with $what reads as unreadable, its page is not copied, '
      'and the summary counts it',
      () async {
        final groupName = lineupName('page-a', 'g1');
        final group = jsonDecode(seeded[sampleArea]![groupName]!) as Map;
        final payload = group['payload'] as Map;
        final broken = jsonEncode({
          ...group,
          'payload': {
            ...payload,
            'data': breakIt((payload['data']! as Map).cast<String, Object?>()),
          },
        });
        final area = {...seeded[sampleArea]!, groupName: broken}
          ..remove(elementName('page-a', 'garbled'))
          ..remove(pinName);
        final disk = MemoryStorage({...seeded, sampleArea: area});
        final store = await openStore(MemoryEngine(disk));
        final page = pageOf(await store.readPage(strategyId, 'page-a'));
        expect(
          page.lineupGroups.single,
          isA<UnreadableLineupGroup>()
              .having((row) => row.publicId, 'id', 'g1')
              .having((row) => jsonEncode(row.stored), 'stored', broken),
        );
        expect(
          await store.commit(
            strategyId,
            const PageAddOp(
              opId: 'copy-a',
              pagePublicId: 'page-copy',
              sortIndex: 3,
              expectedStrategyRevision: 1,
              settings: defaultSettings,
              copyContentFromPagePublicId: 'page-a',
            ),
          ),
          isA<Refused<Committed, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<OpRefusal>(),
          ),
        );
        expect(disk.contents[sampleArea], area);
        expect(
          listOf(store).strategies.single.readability,
          isA<SomeUnreadable>()
              .having((some) => some.damaged, 'damaged', 1)
              .having((some) => some.newer, 'newer', 1),
        );
      },
    );
  }
}
