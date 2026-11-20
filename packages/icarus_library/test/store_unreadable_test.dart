import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

const _unreadable = {
  'content/page-a/element/smoke': unreadableElementJson,
  'content/page-a/pin/pin-1': unknownRowJson,
  'content/page-a/element/garbled': garbledJson,
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
        isA<OpRefusal>().having(
          (reason) => reason.refusal,
          'refusal',
          const UnreadableTarget(ElementKey('garbled')),
        ),
      ),
    );
    expectUntouched(disk.contents);
  });

  test('a page copy carries an unreadable element as a new row', () async {
    final area = {...seeded[sampleArea]!}
      ..remove('content/page-a/element/garbled')
      ..remove('content/page-a/pin/pin-1');
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
    final stored = carried.stored! as Map<String, Object?>;
    expect(stored['newRowField'], 'kept');
    expect(stored['publicId'], carried.publicId);
  });
}
