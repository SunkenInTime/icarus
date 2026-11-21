import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

typedef Edit = Future<Saving<Object?, Object?>> Function(LibraryStore store);

Object? nested(int depth) => depth == 0 ? 1 : [nested(depth - 1)];

ElementAddOp deepElement(String id, int depth) => ElementAddOp(
  opId: 'deep-$id',
  elementPublicId: id,
  pagePublicId: 'page-a',
  payload: agentPayload(id, {'type': 'jett', 'deep': nested(depth)}),
  sortIndex: 0,
);

final class FailingListLease extends ForwardingLease {
  FailingListLease(super.inner, this.failures);

  final List<bool> failures;

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async {
    if (area == 'library' && failures.isNotEmpty && failures.removeAt(0)) {
      return const StorageFailed(DeviceFailure('the disk went away'));
    }
    return super.entries(area, prefix);
  }
}

Future<String> inDoubt(MemoryStorage disk, Failing how, Edit edit) async {
  final store = await openStore(flaky(MemoryEngine(disk), {0: how}));
  final result = await edit(store);
  await store.close();
  return switch (result) {
    SaveInDoubt(:final attempt) => attempt,
    final other => fail('expected doubt, got ${describeSaving(other)}'),
  };
}

Future<LastSave> lastSaveOn(MemoryStorage disk) async {
  switch (await LibraryStore.open(
    MemoryEngine(disk),
    canRead: readsKnownKinds,
  )) {
    case StoreOpened(:final store, :final lastSave):
      await store.close();
      return lastSave;
    case StoreNotOpened(:final problem):
      fail('$problem');
  }
}

void main() {
  late Contents seeded;
  late Contents filed;

  setUpAll(() async {
    seeded = await seededContents();
    final storage = MemoryStorage(seeded);
    final store = await openStore(MemoryEngine(storage));
    savedValue(
      await store.editLibrary([
        PutFolder(ReadableFolder(publicId: 'f1', name: 'Ascent')),
        PutFolder(ReadableFolder(publicId: 'f2', name: 'Bind')),
        const MoveStrategy(strategyId, 'f1'),
      ]),
    );
    await store.close();
    filed = storage.contents;
  });

  const otherId = 'strategy-2';
  final edits = <String, (Contents Function(), Edit)>{
    for (final MapEntry(key: name, value: op) in everyOpType().entries)
      name: (() => seeded, (store) => store.commit(strategyId, op)),
    'a row at the depth limit': (
      () => seeded,
      (store) =>
          store.commit(strategyId, deepElement('deep', maxJsonDepth - 3)),
    ),
    'adding a strategy': (
      () => seeded,
      (store) => store.editLibrary([
        AddStrategy(sampleStrategy(id: otherId, prefix: 'x-')),
      ]),
    ),
    'removing a strategy': (
      () => seeded,
      (store) => store.editLibrary([const RemoveStrategy(strategyId)]),
    ),
    'removing one strategy and adding another': (
      () => seeded,
      (store) => store.editLibrary([
        const RemoveStrategy(strategyId),
        AddStrategy(sampleStrategy(id: otherId, prefix: 'x-')),
      ]),
    ),
    'moving a strategy between folders': (
      () => filed,
      (store) => store.editLibrary([const MoveStrategy(strategyId, 'f2')]),
    ),
    'removing a folder': (
      () => filed,
      (store) => store.editLibrary([const RemoveFolder('f2')]),
    ),
  };

  for (final MapEntry(key: name, value: (before, edit)) in edits.entries) {
    test(
      'saving $name returns its outcome, and the next open agrees',
      () async {
        final cleanDisk = MemoryStorage(before());
        final (engine, counts) = counting(MemoryEngine(cleanDisk));
        final clean = await openStore(engine);
        counts.reset();
        savedValue(await edit(clean));
        expect(counts.calls, 1, reason: 'a save is one commit');
        await clean.close();
        final after = withoutSlot(cleanDisk.contents);
        expect(sameContents(after, withoutSlot(before())), isFalse);

        for (final how in Failing.values) {
          final disk = MemoryStorage(before());
          final store = await openStore(flaky(MemoryEngine(disk), {0: how}));
          final result = await edit(store);
          await store.close();
          final expected = switch (how) {
            Failing.refused || Failing.lost => withoutSlot(before()),
            Failing.landed => after,
          };
          expect(
            sameContents(withoutSlot(disk.contents), expected),
            isTrue,
            reason: '$name ${how.name}: the stored rows',
          );
          final lastSave = await lastSaveOn(disk);
          switch ((how, result)) {
            case (Failing.refused, NotSaved()):
              break;
            case (Failing.landed, SaveInDoubt(:final attempt)):
              expect(
                lastSave,
                isA<LastSaveWas>().having(
                  (was) => was.attempt,
                  'attempt',
                  attempt,
                ),
              );
            case (Failing.lost, SaveInDoubt(:final attempt)):
              expect(
                lastSave,
                isNot(
                  isA<LastSaveWas>().having(
                    (was) => was.attempt,
                    'attempt',
                    attempt,
                  ),
                ),
              );
            case _:
              fail('$name ${how.name}: ${describeSaving(result)}');
          }
        }
      },
    );
  }

  test(
    'two saves in doubt in a row are each answered by the open after them',
    () async {
      final disk = MemoryStorage(seeded);
      final landed = await inDoubt(
        disk,
        Failing.landed,
        (store) => store.commit(strategyId, moveJett),
      );
      expect(
        await lastSaveOn(disk),
        isA<LastSaveWas>().having((was) => was.attempt, 'attempt', landed),
      );
      final lost = await inDoubt(
        disk,
        Failing.lost,
        (store) => store.commit(strategyId, everyOpType()['element.reorder']!),
      );
      final answer = await lastSaveOn(disk);
      expect(
        answer,
        isA<LastSaveWas>().having((was) => was.attempt, 'attempt', landed),
      );
      expect(
        answer,
        isNot(isA<LastSaveWas>().having((was) => was.attempt, 'attempt', lost)),
      );
    },
  );

  test(
    'an open that fails part way still reports the last save, and so does the next',
    () async {
      final disk = MemoryStorage(seeded);
      final landed = await inDoubt(
        disk,
        Failing.landed,
        (store) => store.commit(strategyId, moveJett),
      );
      final failures = [true];
      final failing = await LibraryStore.open(
        WrappingEngine(
          MemoryEngine(disk),
          (lease) => FailingListLease(lease, failures),
        ),
        canRead: readsKnownKinds,
      );
      expect(
        failing,
        isA<StoreNotOpened>()
            .having(
              (opening) => opening.problem,
              'problem',
              isA<OpenStorageFailed>(),
            )
            .having(
              (opening) => opening.lastSave,
              'last save',
              isA<LastSaveWas>().having(
                (was) => was.attempt,
                'attempt',
                landed,
              ),
            ),
      );
      expect(
        await lastSaveOn(disk),
        isA<LastSaveWas>().having((was) => was.attempt, 'attempt', landed),
      );
    },
  );

  test('a row nested deeper than the store reads is not saved', () async {
    final disk = MemoryStorage(seeded);
    final store = await openStore(MemoryEngine(disk));
    expect(
      await store.commit(strategyId, deepElement('too-deep', maxJsonDepth - 2)),
      isA<NotSaved<Committed, CommitRefusal>>().having(
        (result) => result.failure,
        'failure',
        isA<WouldNotReadBack>(),
      ),
    );
    expect(sameContents(disk.contents, seeded), isTrue);
  });

  test(
    'a revision reaches the largest whole number JavaScript holds, and no further',
    () async {
      const largest = 9007199254740991;
      final jettName = elementName('page-a', 'jett');
      final jett = jsonDecode(seeded[sampleArea]![jettName]!) as Map;
      final disk = MemoryStorage({
        ...seeded,
        sampleArea: {
          ...seeded[sampleArea]!,
          jettName: jsonEncode({...jett, 'revision': largest - 1}),
        },
      });
      ElementPatchOp nudge(int revision) => ElementPatchOp(
        opId: 'nudge-$revision',
        elementPublicId: 'jett',
        expectedElementRevision: revision,
        payload: agentPayload('jett', {
          'type': 'jett',
          'position': {'dx': revision % 7, 'dy': 1},
        }),
        merge: FieldMerge(fields: ['position']),
      );
      final store = await openStore(MemoryEngine(disk));
      savedValue(await store.commit(strategyId, nudge(largest - 1)));
      final atLargest = disk.contents;
      expect(
        await store.commit(strategyId, nudge(largest)),
        isA<NotSaved<Committed, CommitRefusal>>().having(
          (result) => result.failure,
          'failure',
          isA<WouldNotReadBack>(),
        ),
      );
      expect(sameContents(disk.contents, atLargest), isTrue);
      await store.close();
      final page = pageOf(
        await (await openStore(
          MemoryEngine(disk),
        )).readPage(strategyId, 'page-a'),
      );
      expect((elementOn(page, 'jett') as LiveElement).revision, largest);
    },
  );

  test(
    'a strategy with a very long id is added and removed on a small engine',
    () async {
      final disk = MemoryStorage();
      final id = 'x' * 300;
      final store = await openStore(MemoryEngine(disk, maxKeyLength: 255));
      savedValue(
        await store.editLibrary([AddStrategy(sampleStrategy(id: id))]),
      );
      savedValue(await store.editLibrary([RemoveStrategy(id)]));
      await store.close();
      final reopened = await openStore(MemoryEngine(disk, maxKeyLength: 255));
      expect(listOf(reopened).strategies, isEmpty);
    },
  );

  test(
    'an engine whose names are too short for the store does not open',
    () async {
      expect(
        await LibraryStore.open(
          MemoryEngine(MemoryStorage(), maxKeyLength: longestName - 1),
          canRead: readsKnownKinds,
        ),
        isA<StoreNotOpened>().having(
          (opening) => opening.problem,
          'problem',
          isA<EngineTooSmall>(),
        ),
      );
    },
  );
}
