import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

typedef Edit = Future<Saving<Object?, Object?>> Function(LibraryStore store);

void expectHonest(
  Saving<Object?, Object?> result,
  Contents reopened,
  Contents before,
  Contents after,
  String where,
) {
  final isBefore = sameContents(
    withoutJournal(reopened),
    withoutJournal(before),
  );
  final isAfter = sameContents(withoutJournal(reopened), withoutJournal(after));
  expect(
    isBefore || isAfter,
    isTrue,
    reason: '$where: neither before nor after',
  );
  switch (result) {
    case Saved():
      expect(isAfter, isTrue, reason: '$where: saved, then lost');
    case NotSaved():
      expect(isBefore, isTrue, reason: '$where: not saved, yet kept');
    case SaveInDoubt():
      break;
    case NothingToSave() || Refused():
      fail('$where: unexpected ${describeSaving(result)}');
  }
}

Future<void> checkEveryCut(Contents before, Edit edit) async {
  final cleanStorage = MemoryStorage(before);
  final (cleanEngine, counts) = counting(MemoryEngine(cleanStorage));
  final cleanStore = await openStore(cleanEngine);
  counts.reset();
  savedValue(await edit(cleanStore));
  await cleanStore.close();
  final after = cleanStorage.contents;
  final calls = counts.calls;
  expect(calls, greaterThanOrEqualTo(3));
  expect(sameContents(withoutJournal(after), withoutJournal(before)), isFalse);

  for (var allowed = 0; allowed < calls; allowed++) {
    final disk = MemoryStorage(before);
    final cut = Cut(allowed);
    final store = await openStore(crashing(MemoryEngine(disk), cut));
    final result = await edit(store);
    expect(cut.cut, isTrue, reason: 'the store never reached call $allowed');
    expect(cut.landed, allowed, reason: 'calls landed before the cut');
    final cutShort = disk.contents;
    expectHonest(
      result,
      await settled(cutShort),
      before,
      after,
      'crash after $allowed calls',
    );
    if (cutShort['journal']?['edit'] == null) continue;
    final (replayEngine, replayCounts) = counting(
      MemoryEngine(MemoryStorage(cutShort)),
    );
    await (await openStore(replayEngine)).close();
    expect(replayCounts.calls, greaterThanOrEqualTo(2));
    for (var again = 0; again < replayCounts.calls; again++) {
      final second = MemoryStorage(cutShort);
      final secondCut = Cut(again);
      await LibraryStore.open(
        crashing(MemoryEngine(second), secondCut),
        canRead: readsKnownKinds,
        clock: fixedClock,
      );
      expect(secondCut.cut, isTrue, reason: 'replay never reached $again');
      expect(
        sameContents(
          withoutJournal(await settled(second.contents)),
          withoutJournal(after),
        ),
        isTrue,
        reason: 'a second crash at replay call $again lost the edit',
      );
    }
  }

  for (final how in Failing.values) {
    for (var at = 0; at < calls; at++) {
      final disk = MemoryStorage(before);
      final store = await openStore(flaky(MemoryEngine(disk), {at: how}));
      final result = await edit(store);
      await store.close();
      expectHonest(
        result,
        await settled(disk.contents),
        before,
        after,
        'call $at ${how.name}',
      );
    }
  }
}

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = await seededContents();
  });

  for (final MapEntry(key: name, value: op) in everyOpType().entries) {
    test('every cut while saving $name leaves the rows before or after', () {
      return checkEveryCut(seeded, (store) => store.commit(strategyId, op));
    });
  }

  const otherId = 'strategy-2';
  final libraryEdits = <String, List<LibraryChange>>{
    'adding a strategy': [
      AddStrategy(sampleStrategy(id: otherId, prefix: 'x-')),
    ],
    'removing a strategy': [const RemoveStrategy(strategyId)],
    'a folder, an add into it and a move into it': [
      PutFolder(ReadableFolder(publicId: 'f', name: 'Ascent')),
      AddStrategy(sampleStrategy(id: otherId, prefix: 'x-')),
      const MoveStrategy(otherId, 'f'),
      const MoveStrategy(strategyId, 'f'),
    ],
    'removing one strategy and adding another': [
      const RemoveStrategy(strategyId),
      AddStrategy(sampleStrategy(id: otherId, prefix: 'x-')),
    ],
  };
  for (final MapEntry(key: name, value: changes) in libraryEdits.entries) {
    test('every cut while saving $name leaves the library before or after', () {
      return checkEveryCut(seeded, (store) => store.editLibrary(changes));
    });
  }

  test('every cut while a summary is rebuilt leaves it before or after', () {
    final stale = {
      ...seeded,
      strategyArea: {
        ...seeded[strategyArea]!,
        'content/page-b/element/neon': canonicalRow(
          agent('neon', type: 'neon', pageId: 'page-b'),
        ),
      },
    };
    return checkEveryCut(stale, (store) => store.rebuildSummary(strategyId));
  });
}
