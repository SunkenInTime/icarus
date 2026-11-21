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
  FailingListLease(super.inner);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async =>
      area == 'library'
      ? const StorageFailed(DeviceFailure('the disk went away'))
      : super.entries(area, prefix);
}

final class SlowRelease extends ForwardingLease {
  SlowRelease(super.inner);

  @override
  Future<Releasing> release() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return super.release();
  }
}

final class FailingPageListing extends ForwardingLease {
  FailingPageListing(super.inner, this.area);

  final String area;

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async =>
      area == this.area && prefix == 'page/'
      ? const StorageFailed(DeviceFailure('the page listing failed'))
      : super.entries(area, prefix);
}

final class EndsAfterLastPageRead extends ForwardingLease {
  EndsAfterLastPageRead(super.inner);

  var _pagesRead = 0;

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async {
    final listed = await super.entries(area, prefix);
    if (prefix.startsWith('content/') && ++_pagesRead == 3) {
      await inner.release();
    }
    return listed;
  }
}

Future<LibraryStore> reopen(MemoryStorage disk) =>
    openStore(MemoryEngine(disk));

final unreadableArea = strategyArea('strategy-garbled');

const savedAgainWithNoChange = {'putting one folder twice in one edit'};

void main() {
  late Contents seeded;
  late Contents filed;
  late Contents withUnreadable;

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
    withUnreadable = {
      ...seeded,
      'library': {
        ...seeded['library']!,
        summaryName('strategy-garbled'): '{"not":"a summary"',
      },
      unreadableArea: {'strategy': '{"garbled"'},
    };
  });

  const otherId = 'strategy-2';
  final edits = <String, (Contents Function(), Edit)>{
    for (final MapEntry(key: name, value: op) in everyOpType().entries)
      name: (() => seeded, (store) => store.commit(strategyId, op)),
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
    'removing a strategy that cannot be read': (
      () => withUnreadable,
      (store) => store.editLibrary([
        RemoveUnreadableStrategy(StrategyRef(unreadableArea)),
      ]),
    ),
    'moving a strategy between folders': (
      () => filed,
      (store) => store.editLibrary([const MoveStrategy(strategyId, 'f2')]),
    ),
    'putting a folder': (
      () => filed,
      (store) => store.editLibrary([
        PutFolder(ReadableFolder(publicId: 'f3', name: 'Split')),
      ]),
    ),
    'putting one folder twice in one edit': (
      () => filed,
      (store) => store.editLibrary([
        PutFolder(ReadableFolder(publicId: 'f3', name: 'Split')),
        PutFolder(ReadableFolder(publicId: 'f3', name: 'Haven')),
      ]),
    ),
    'removing a folder': (
      () => filed,
      (store) => store.editLibrary([const RemoveFolder('f2')]),
    ),
  };

  for (final MapEntry(key: name, value: (before, edit)) in edits.entries) {
    test('$name is one commit, and issuing it again after a save in doubt '
        'leaves it applied once', () async {
      final cleanDisk = MemoryStorage(before());
      final (engine, counts) = counting(MemoryEngine(cleanDisk));
      final clean = await openStore(engine);
      counts.reset();
      savedValue(await edit(clean));
      expect(counts.commits, 1, reason: 'a save is one commit');
      await clean.close();
      final once = cleanDisk.contents;
      expect(sameContents(once, before()), isFalse);

      for (final how in [Failing.landed, Failing.lost]) {
        final disk = MemoryStorage(before());
        final store = await openStore(flaky(MemoryEngine(disk), {0: how}));
        expect(await edit(store), isA<SaveInDoubt<Object?, Object?>>());
        expect(
          store.library,
          isA<LibraryShut>().having(
            (shut) => shut.failure,
            'failure',
            isA<StoreStopped>(),
          ),
        );
        final again = await reopen(disk);
        final second = await edit(again);
        await again.close();
        expect(
          sameContents(disk.contents, once),
          isTrue,
          reason: '$name ${how.name}: the stored rows after issuing it again',
        );
        switch (how) {
          case Failing.landed when savedAgainWithNoChange.contains(name):
            expect(second, isA<Saved<Object?, Object?>>());
          case Failing.landed:
            expect(
              second,
              isNot(isA<Saved<Object?, Object?>>()),
              reason: '$name landed, then: ${describeSaving(second)}',
            );
          case Failing.lost:
            expect(
              second,
              isA<Saved<Object?, Object?>>(),
              reason: '$name lost, then: ${describeSaving(second)}',
            );
          case Failing.refused:
            fail('not a save in doubt');
        }
      }
    });
  }

  test(
    'a save in doubt returns once the storage can be opened again',
    () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(
        WrappingEngine(
          MemoryEngine(disk),
          (lease) => FlakyLease(SlowRelease(lease), {0: Failing.lost}),
        ),
      );
      expect(
        await store.commit(strategyId, moveJett),
        isA<SaveInDoubt<Committed, CommitRefusal>>(),
      );
      expect(
        await LibraryStore.open(MemoryEngine(disk), canRead: readsKnownKinds),
        isA<StoreOpened>(),
      );
    },
  );

  test('a refused commit changes nothing and leaves the store open', () async {
    final disk = MemoryStorage(seeded);
    final store = await openStore(
      flaky(MemoryEngine(disk), {0: Failing.refused}),
    );
    expect(
      await store.commit(strategyId, moveJett),
      isA<NotSaved<Committed, CommitRefusal>>(),
    );
    expect(sameContents(disk.contents, seeded), isTrue);
    savedValue(await store.commit(strategyId, moveJett));
  });

  test(
    'a store with a save in doubt lets go of the storage, closes its changes and refuses every call',
    () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(
        flaky(MemoryEngine(disk), {0: Failing.lost}),
      );
      final ended = expectLater(store.changes, emitsDone);
      expect(
        await store.commit(strategyId, moveJett),
        isA<SaveInDoubt<Committed, CommitRefusal>>(),
      );
      await ended;
      final stopped = isA<StoreStopped>();
      expect(
        await store.commit(strategyId, moveJett),
        isA<NotSaved<Committed, CommitRefusal>>().having(
          (result) => result.failure,
          'failure',
          stopped,
        ),
      );
      expect(
        await store.readStrategy(strategyId),
        isA<NotRead<StrategyContent>>().having(
          (read) => read.failure,
          'failure',
          stopped,
        ),
      );
      expect(
        await store.editLibrary([const RemoveStrategy(strategyId)]),
        isA<NotSaved<LibraryEdited, LibraryRefusal>>().having(
          (result) => result.failure,
          'failure',
          stopped,
        ),
      );
      expect(
        await LibraryStore.open(MemoryEngine(disk), canRead: readsKnownKinds),
        isA<StoreOpened>(),
      );
      expect(await store.close(), isA<Released>());
    },
  );

  group('An open that fails part way', () {
    test('at the library listing opens nothing and writes nothing', () async {
      final disk = MemoryStorage(withUnreadable);
      expect(
        await LibraryStore.open(
          WrappingEngine(MemoryEngine(disk), FailingListLease.new),
          canRead: readsKnownKinds,
        ),
        isA<StoreNotOpened>().having(
          (opening) => opening.problem,
          'problem',
          isA<OpenStorageFailed>(),
        ),
      );
      expect(sameContents(disk.contents, withUnreadable), isTrue);
      expect(await reopen(disk), isA<LibraryStore>());
    });

    Contents damagedSummary() => {
      ...seeded,
      'library': {...seeded['library']!, summaryName(strategyId): '{}'},
    };

    for (final how in [Failing.refused, Failing.lost]) {
      test(
        'with a damaged summary, on an engine whose commits are ${how.name}, '
        'opens, commits nothing and lists the rebuilt summary',
        () async {
          final disk = MemoryStorage(damagedSummary());
          final failing = {for (var i = 0; i < 10; i++) i: how};
          final (engine, counts) = counting(flaky(MemoryEngine(disk), failing));
          final store = await openStore(engine);
          expect(counts.commits, 0);
          expect(listOf(store).strategies.single.publicId, strategyId);
          pageOf(await store.readPage(strategyId, 'page-a'));
          expect(counts.commits, 0);
          expect(store.library, isA<LibraryOpen>());
          expect(sameContents(disk.contents, damagedSummary()), isTrue);
        },
      );
    }

    test(
      'a summary rebuilt in memory is written by the next rebuild, though it compares equal',
      () async {
        final disk = MemoryStorage(damagedSummary());
        final store = await openStore(MemoryEngine(disk));
        expect(
          await store.rebuildSummary(strategyId),
          isA<Saved<StrategySummary, CommitRefusal>>(),
        );
        expect(sameContents(disk.contents, seeded), isTrue);
        expect(
          await store.rebuildSummary(strategyId),
          isA<NothingToSave<StrategySummary, CommitRefusal>>(),
        );
      },
    );

    test(
      'when one strategy cannot be read for its repair, lists it as unreadable and opens',
      () async {
        final before = {
          ...seeded,
          'library': {
            ...seeded['library']!,
            summaryName(strategyId): '{"garbled',
          },
          sampleArea: {...seeded[sampleArea]!}..remove('strategy'),
        };
        final disk = MemoryStorage(before);
        final opening = await LibraryStore.open(
          WrappingEngine(
            MemoryEngine(disk),
            (lease) => FailingPageListing(lease, sampleArea),
          ),
          canRead: readsKnownKinds,
        );
        final store = switch (opening) {
          StoreOpened(:final store) => store,
          StoreNotOpened(:final problem) => fail('$problem'),
        };
        expect(
          listOf(store).unreadableStrategies.single.ref,
          StrategyRef(sampleArea),
        );
        expect(listOf(store).strategies, isEmpty);
        expect(sameContents(disk.contents, before), isTrue);
      },
    );

    test(
      'when the lease ends after the repair has read every page does not open',
      () async {
        final disk = MemoryStorage(damagedSummary());
        expect(
          await LibraryStore.open(
            WrappingEngine(MemoryEngine(disk), EndsAfterLastPageRead.new),
            canRead: readsKnownKinds,
          ),
          isA<StoreNotOpened>().having(
            (opening) => opening.problem,
            'problem',
            isA<OpenStorageFailed>(),
          ),
        );
        expect(sameContents(disk.contents, damagedSummary()), isTrue);
        expect(await reopen(disk), isA<LibraryStore>());
      },
    );
  });

  test('a row nested deeper than the store reads is not saved', () async {
    final disk = MemoryStorage(seeded);
    final store = await openStore(MemoryEngine(disk));
    savedValue(
      await store.commit(strategyId, deepElement('deep', maxJsonDepth - 3)),
    );
    final before = disk.contents;
    expect(
      await store.commit(strategyId, deepElement('too-deep', maxJsonDepth - 2)),
      isA<NotSaved<Committed, CommitRefusal>>().having(
        (result) => result.failure,
        'failure',
        isA<WouldNotReadBack>(),
      ),
    );
    expect(sameContents(disk.contents, before), isTrue);
  });

  test(
    'a settings edit holding a number that is not finite is refused before anything is written',
    () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(MemoryEngine(disk));
      expect(
        await store.commit(
          strategyId,
          const PageSettingsPatchOp(
            opId: 'nan',
            pagePublicId: 'page-a',
            settings: PageSettings(
              agentSize: double.nan,
              abilitySize: 1,
              useNeutralTeamColors: false,
            ),
            expectedPageSettingsRevision: 1,
          ),
        ),
        isA<Refused<Committed, CommitRefusal>>().having(
          (result) => result.reason,
          'reason',
          isA<OpRefusal>().having(
            (reason) => reason.refusal,
            'refusal',
            const Failed(FailureCode.invalidPayload),
          ),
        ),
      );
      expect(sameContents(disk.contents, seeded), isTrue);
    },
  );

  test(
    'an added strategy holding a number that is not finite is not saved',
    () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(MemoryEngine(disk));
      final rows = sampleStrategy(id: 'strategy-nan', prefix: 'n-');
      expect(
        await store.editLibrary([
          AddStrategy(
            StrategyRowSet(
              strategy: rows.strategy,
              pages: rows.pages,
              settings: [
                for (final row in rows.settings)
                  ReadablePageSettings(
                    pagePublicId: row.pagePublicId,
                    revision: 1,
                    settings: const PageSettings(
                      agentSize: double.infinity,
                      abilitySize: 1,
                      useNeutralTeamColors: false,
                    ),
                  ),
              ],
              elements: rows.elements,
              lineupGroups: rows.lineupGroups,
            ),
          ),
        ]),
        isA<NotSaved<LibraryEdited, LibraryRefusal>>().having(
          (result) => result.failure,
          'failure',
          isA<WouldNotReadBack>(),
        ),
      );
      expect(sameContents(disk.contents, seeded), isTrue);
    },
  );

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
        await (await reopen(disk)).readPage(strategyId, 'page-a'),
      );
      expect((elementOn(page, 'jett') as LiveElement).revision, largest);
    },
  );

  test(
    'a strategy with a very long id is added and removed on a small engine',
    () async {
      final disk = MemoryStorage({}, 255);
      final id = 'x' * 300;
      final store = await openStore(MemoryEngine(disk));
      savedValue(
        await store.editLibrary([AddStrategy(sampleStrategy(id: id))]),
      );
      savedValue(await store.editLibrary([RemoveStrategy(id)]));
      await store.close();
      final reopened = await reopen(disk);
      expect(listOf(reopened).strategies, isEmpty);
    },
  );

  test(
    'an engine whose names are too short for the store does not open',
    () async {
      expect(
        await LibraryStore.open(
          MemoryEngine(MemoryStorage({}, longestName - 1)),
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
