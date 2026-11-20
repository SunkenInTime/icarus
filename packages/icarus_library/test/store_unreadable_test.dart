import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

const _area = 'strategy/$strategyId';

const _unreadable = {
  'content/page-a/element/smoke': unreadableElementJson,
  'content/page-a/pin/pin-1': unknownRowJson,
  'content/page-a/element/garbled': garbledJson,
};

void expectUntouched(Contents contents) {
  for (final MapEntry(:key, :value) in _unreadable.entries) {
    expect(contents[_area]?[key], value, reason: key);
  }
}

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = (await seededEngine()).contents;
  });

  test(
    'every op on the page leaves the rows this build cannot read as stored',
    () async {
      final disk = MemoryEngine(seeded);
      final store = await openStore(disk);
      for (final MapEntry(key: name, value: op) in everyOpType().entries) {
        final result = await store.commit(strategyId, op);
        expect(
          result,
          isNot(isA<NotSaved<StrategyEdited, CommitRefusal>>()),
          reason: name,
        );
        expectUntouched(disk.contents);
      }
      expect(
        await store.rebuildSummary(strategyId),
        isA<NothingToSave<StrategySummary, CommitRefusal>>(),
      );
      expectUntouched(disk.contents);
      final reopened = await openStore(MemoryEngine(disk.contents));
      expect(
        await reopened.rebuildSummary(strategyId),
        isA<NothingToSave<StrategySummary, CommitRefusal>>(),
      );
      expectUntouched(disk.contents);
    },
  );

  test('each op type on its own leaves them as stored', () async {
    for (final MapEntry(key: name, value: op) in everyOpType().entries) {
      final disk = MemoryEngine(seeded);
      final store = await openStore(disk);
      savedValue(await store.commit(strategyId, op));
      expectUntouched(disk.contents);
      expect(
        reason: name,
        disk.contents[_area]!.length,
        greaterThanOrEqualTo(seeded[_area]!.length),
      );
    }
  });

  test('an op aimed at an element this build cannot read is refused', () async {
    final store = await openStore(MemoryEngine(seeded));
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
      isA<Refused<StrategyEdited, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<OpRefusal>().having(
          (reason) => reason.refusal,
          'refusal',
          const UnreadableTarget('smoke'),
        ),
      ),
    );
  });

  test('an add over a stored row this build cannot read is refused', () async {
    final disk = MemoryEngine(seeded);
    final store = await openStore(disk);
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
      isA<Refused<StrategyEdited, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<UnreadableRowInTheWay>().having(
          (reason) => reason.row.text,
          'text',
          garbledJson,
        ),
      ),
    );
    expectUntouched(disk.contents);
  });

  test('a page copy carries an unreadable element as a new row', () async {
    final store = await openStore(MemoryEngine(seeded));
    savedValue(
      await store.commit(strategyId, everyOpType()['page.add copying a page']!),
    );
    final copy = pageOf(await store.readPage(strategyId, 'page-copy'));
    final carried = copy.elements.whereType<UnreadableElement>().single;
    expect(carried.json['newRowField'], 'kept');
    expect(carried.json['payload'], isA<Map<String, Object?>>());
  });
}
