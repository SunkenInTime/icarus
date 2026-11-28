import 'dart:async';
import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/store/layout.dart'
    show formatKey, libraryArea;
import 'package:icarus_library/src/store/store.dart' show storeFormatProblem;
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

Map<String, Object?> stored(Contents contents, String area, String key) =>
    jsonDecode(contents[area]![key]!) as Map<String, Object?>;

Contents agedSeeded(Contents seeded) => agedSummary(seeded, strategyId);

Contents agedSummary(Contents seeded, String strategyId) {
  final written =
      jsonDecode(seeded['library']![summaryName(strategyId)]!)
          as Map<String, Object?>;
  final older = {
    for (final MapEntry(:key, :value) in written.entries)
      if (key != 'agentsInOrder' && key != 'firstPageIsAttack')
        key: switch (key) {
          'summaryVersion' => 5,
          'tallies' => {
            for (final MapEntry(:key, :value)
                in (value! as Map<String, Object?>).entries)
              key: {
                for (final MapEntry(:key, value: field)
                    in (value! as Map<String, Object?>).entries)
                  if (key != 'order') key: field,
              },
          },
          _ => value,
        },
  };
  return {
    ...seeded,
    'library': {
      ...seeded['library']!,
      summaryName(strategyId): jsonEncode(older),
    },
  };
}

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = await seededContents();
  });

  group('The library format', () {
    test('opening makes no commit, for a new library and for one with '
        'strategies whose marker is missing; the first save carries the '
        'marker in the same commit', () async {
      final (fresh, freshCounts) = counting(MemoryEngine(MemoryStorage()));
      final created = await LibraryStore.open(
        fresh,
        canRead: readsKnownKinds,
        clock: fixedClock,
      );
      expect(
        created,
        isA<StoreOpened>().having(
          (opened) => opened.origin,
          'origin',
          isA<StorageCreated>(),
        ),
      );
      expect(freshCounts.commits, 0);
      final store = (created as StoreOpened).store;
      savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
      expect(freshCounts.commits, 1);
      expect(freshCounts.written, contains((libraryArea, formatKey)));
      await store.close();

      final markerless = {
        for (final MapEntry(:key, :value) in seeded.entries)
          key: {...value}..remove(formatKey),
      };
      final (existing, counts) = counting(
        MemoryEngine(MemoryStorage(markerless)),
      );
      final opened = await LibraryStore.open(
        existing,
        canRead: readsKnownKinds,
        clock: fixedClock,
      );
      expect(
        opened,
        isA<StoreOpened>().having(
          (opened) => opened.origin,
          'origin',
          isA<StorageExisted>(),
        ),
      );
      expect(counts.commits, 0);
      final reopened = (opened as StoreOpened).store;
      savedValue(
        await reopened.editLibrary([
          AddStrategy(sampleStrategy(id: 'second', prefix: 'second-')),
        ]),
      );
      expect(counts.commits, 1);
      expect(counts.written, contains((libraryArea, formatKey)));
      await reopened.close();
    });

    test('a library with strategies whose marker cannot be written opens all '
        'the same, as existing, with its strategies listed', () async {
      final markerless = {
        for (final MapEntry(:key, :value) in seeded.entries)
          key: {...value}..remove(formatKey),
      };
      final opening = await LibraryStore.open(
        WrappingEngine(
          MemoryEngine(MemoryStorage(markerless)),
          _RefusingEveryCommit.new,
        ),
        canRead: readsKnownKinds,
        clock: fixedClock,
      );
      expect(
        opening,
        isA<StoreOpened>().having(
          (opened) => opened.origin,
          'origin',
          isA<StorageExisted>(),
        ),
      );
      final store = (opening as StoreOpened).store;
      expect(listOf(store).strategies, isNotEmpty);
      await store.close();
    });

    Future<StoreOpening> opening(MemoryStorage disk) => LibraryStore.open(
      MemoryEngine(disk),
      canRead: readsKnownKinds,
      clock: fixedClock,
    );

    test('a new library left unsaved is created again next time; after a '
        'save it holds the marker and is existing', () async {
      Future<StorageOrigin> originOn(MemoryStorage disk) async {
        final opened = await opening(disk) as StoreOpened;
        await opened.store.close();
        return opened.origin;
      }

      final disk = MemoryStorage();
      expect(await originOn(disk), isA<StorageCreated>());
      expect(disk.contents, isEmpty);
      expect(await originOn(disk), isA<StorageCreated>());
      final opened = await opening(disk) as StoreOpened;
      savedValue(
        await opened.store.editLibrary([AddStrategy(sampleStrategy())]),
      );
      await opened.store.close();
      expect(disk.contents[libraryArea]?[formatKey], '$storeFormat');
      expect(await originOn(disk), isA<StorageExisted>());
    });

    test('a format 1 library opens unchanged and is marked format 2 by the '
        'first commit this build makes to it', () async {
      final contents = {
        ...seeded,
        libraryArea: {...?seeded[libraryArea], formatKey: '1'},
      };
      final disk = MemoryStorage(contents);
      final opened = await opening(disk) as StoreOpened;
      expect(listOf(opened.store).strategies, isNotEmpty);
      expect(disk.contents, contents);
      savedValue(
        await opened.store.editLibrary([
          AddStrategy(sampleStrategy(id: 'more')),
        ]),
      );
      await opened.store.close();
      expect(disk.contents[libraryArea]?[formatKey], '2');
    });

    test('a library this build wrote is refused by a reader that knows only '
        'format 1', () async {
      final disk = MemoryStorage();
      final opened = await opening(disk) as StoreOpened;
      savedValue(
        await opened.store.editLibrary([AddStrategy(sampleStrategy())]),
      );
      await opened.store.close();
      expect(
        storeFormatProblem(disk.contents[libraryArea]![formatKey]!, known: 1),
        isA<NewerFormat>()
            .having((newer) => newer.found, 'found', 2)
            .having((newer) => newer.known, 'known', 1),
      );
    });

    test('a library with a newer store format is refused, and the store '
        'writes nothing, not even the summary it would repair', () async {
      final contents = {
        ...seeded,
        libraryArea: {
          ...?seeded[libraryArea],
          formatKey: '${storeFormat + 1}',
          summaryName(strategyId): 'not a summary',
        },
      };
      final disk = MemoryStorage(contents);
      expect(
        await opening(disk),
        isA<StoreNotOpened>().having(
          (refused) => refused.problem,
          'problem',
          isA<OpenStorageFailed>().having(
            (failed) => failed.failure,
            'failure',
            isA<NewerFormat>()
                .having((newer) => newer.layer, 'layer', FormatLayer.store)
                .having((newer) => newer.found, 'found', storeFormat + 1)
                .having((newer) => newer.known, 'known', storeFormat),
          ),
        ),
      );
      expect(disk.contents, contents);
    });

    test(
      'a store format that is not a plain decimal is a damaged library, never a newer one',
      () async {
        for (final format in [
          'x',
          '01',
          '02',
          '0x2',
          '+2',
          ' 1',
          '2 ',
          '0',
          '-1',
          '1.0',
          '1e1',
          '',
        ]) {
          final disk = MemoryStorage({
            libraryArea: {formatKey: format},
          });
          expect(
            await opening(disk),
            isA<StoreNotOpened>().having(
              (refused) => refused.problem,
              'problem',
              isA<OpenStorageFailed>().having(
                (failed) => failed.failure,
                'failure',
                isA<DamagedLibrary>(),
              ),
            ),
            reason: format,
          );
        }
      },
    );
  });

  group('Reading', () {
    test('the library list shows each strategy from its summary', () async {
      final store = await openOn(seeded);
      final [summary] = listOf(store).strategies;
      expect(summary.publicId, strategyId);
      expect(summary.name, 'Retake B');
      expect(summary.mapData, 'ascent');
      expect(summary.folderPublicId, isNull);
      expect(summary.createdAt, strategyCreatedAt);
      expect(summary.updatedAt, strategyCreatedAt);
      expect(summary.pageCount, 3);
      expect(summary.sides, Sides.mixed);
      expect(summary.agents, ['jett', 'kayo', 'omen', 'sova']);
      expect(summary.itemCount, 6);
    });

    test('a strategy reads as its row and its pages in order', () async {
      final store = await openOn(seeded);
      final content = strategyOf(await store.readStrategy(strategyId));
      expect(headerOf(content).name, 'Retake B');
      expect(content.pages.map((page) => page.publicId), [
        'page-a',
        'page-b',
        'page-c',
      ]);
      expect(
        content.settings.keys,
        unorderedEquals(['page-a', 'page-b', 'page-c']),
      );
    });

    test('a page reads every row it holds, readable or not', () async {
      final store = await openOn(seeded);
      final content = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(
        content.elements.map((row) => row.publicId),
        unorderedEquals(['jett', 'sova', 'line', 'smoke']),
      );
      final garbled = content.unplaced.single;
      expect(
        garbled.ref,
        StoredRowRef(sampleArea, elementName('page-a', 'garbled')),
      );
      expect(garbled.stored, garbledJson);
      expect(elementOn(content, 'smoke'), isA<UnreadableElement>());
      expect(content.lineupGroups.single.publicId, 'g1');
      expect(content.unknownKinds.single.key, pinName);
      expect(content.unknownKinds.single.text, unknownRowJson);
    });

    test('a strategy or page that is not there reads as not found', () async {
      final store = await openOn(seeded);
      expect(
        await store.readStrategy('nope'),
        isA<NotFound<StrategyContent>>(),
      );
      expect(
        await store.readPage(strategyId, 'nope'),
        isA<NotFound<PageContent>>(),
      );
    });

    test('an unloaded strategy is read from storage again', () async {
      final (engine, counts) = counting(MemoryEngine(MemoryStorage(seeded)));
      final store = await openStore(engine);
      pageOf(await store.readPage(strategyId, 'page-b'));
      counts.reset();
      pageOf(await store.readPage(strategyId, 'page-b'));
      expect(counts.reads, isEmpty);
      expect(await store.unload(strategyId), isA<Unloaded>());
      pageOf(await store.readPage(strategyId, 'page-b'));
      expect(counts.reads, isNotEmpty);
    });
  });

  group('Saving an edit', () {
    test(
      'says what changed, names its op, and keeps it across a reopen',
      () async {
        final disk = MemoryStorage(seeded);
        final store = await openStore(MemoryEngine(disk));
        final changes = <StoreChange>[];
        final listening = store.changes.listen(changes.add);
        final committed = savedValue(await store.commit(strategyId, moveJett));
        final edited = committed.change;
        expect(edited.opId, moveJett.opId);
        expect(edited.removed, isEmpty);
        final element =
            edited.writes.firstWhere(
                  (write) => write.after.key == const ElementKey('jett'),
                )
                as RowChanged;
        expect(element.dataFields, {'position'});
        final header =
            edited.writes.firstWhere((write) => write.after is ReadableStrategy)
                as RowChanged;
        expect(header.fields, {RowField.updatedAt});
        expect(
          (header.after as ReadableStrategy).updatedAt,
          asStored(editedAt),
        );
        expect(committed.undo, isA<RestoreElementFields>());
        expect(edited.summary.updatedAt, asStored(editedAt));
        expect(edited.summary.createdAt, strategyCreatedAt);
        await pumpEventQueue();
        expect(changes.single, same(edited));
        await listening.cancel();
        await store.close();

        final reopened = await openOn(disk.contents);
        final page = pageOf(await reopened.readPage(strategyId, 'page-a'));
        expect(elementOn(page, 'jett'), element.after);
        expect(listOf(reopened).strategies.single, edited.summary);
        final row = headerOf(
          strategyOf(await reopened.readStrategy(strategyId)),
        );
        expect(row.updatedAt, asStored(editedAt));
      },
    );

    test('an op that changes nothing saves nothing', () async {
      final (engine, counts) = counting(MemoryEngine(MemoryStorage(seeded)));
      final store = await openStore(engine);
      savedValue(await store.commit(strategyId, moveJett));
      counts.reset();
      expect(
        await store.commit(strategyId, moveJett),
        isA<NothingToSave<Committed, CommitRefusal>>(),
      );
      expect(counts.commits, 0);
    });

    test('an op the rows refuse is refused with the reason', () async {
      final store = await openOn(seeded);
      final result = await store.commit(
        strategyId,
        const ElementReorderOp(
          opId: 'stale',
          elementPublicId: 'line',
          pagePublicId: 'page-a',
          sortIndex: 3,
          expectedElementRevision: 9,
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
            const Rejected(RejectionReason.revisionMismatch),
          ),
        ),
      );
    });

    test('an edit to a strategy the store does not hold is refused', () async {
      final store = await openOn(seeded);
      expect(
        await store.commit('nope', moveJett),
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<NoSuchStrategy>(),
        ),
      );
    });

    test('edits sent together are saved one after another', () async {
      final store = await openOn(seeded);
      final results = await Future.wait([
        store.commit(strategyId, moveJett),
        store.commit(
          strategyId,
          const ElementPatchOp(
            opId: 'second',
            elementPublicId: 'jett',
            expectedElementRevision: 2,
            sortIndex: 7,
          ),
        ),
      ]);
      expect(results.map(describeSaving), ['saved', 'saved']);
    });

    test(
      'an element moved to another page is read from that page only',
      () async {
        final disk = MemoryStorage(seeded);
        final store = await openStore(MemoryEngine(disk));
        savedValue(
          await store.commit(
            strategyId,
            everyOpType()['element.patch to another page']!,
          ),
        );
        await store.close();
        final reopened = await openOn(disk.contents);
        final a = pageOf(await reopened.readPage(strategyId, 'page-a'));
        final b = pageOf(await reopened.readPage(strategyId, 'page-b'));
        expect(a.elements.map((row) => row.publicId), isNot(contains('jett')));
        expect(b.elements.map((row) => row.publicId), contains('jett'));
      },
    );
  });

  group('When the device cannot save', () {
    test('a refused write of the saved edit leaves it unsaved', () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(
        flaky(MemoryEngine(disk), {0: Failing.refused}),
      );
      expect(
        await store.commit(strategyId, moveJett),
        isA<NotSaved<Committed, CommitRefusal>>(),
      );
      expect(sameContents(disk.contents, seeded), isTrue);
      expect(describeSaving(await store.commit(strategyId, moveJett)), 'saved');
    });

    test('after a save in doubt the store saves nothing more', () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(
        flaky(MemoryEngine(disk), {0: Failing.landed}),
      );
      expect(
        await store.commit(strategyId, moveJett),
        isA<SaveInDoubt<Committed, CommitRefusal>>(),
      );
      final landed = disk.contents;
      expect(
        await store.commit(strategyId, everyOpType()['element.reorder']!),
        isA<NotSaved<Committed, CommitRefusal>>().having(
          (result) => result.failure,
          'failure',
          isA<StoreStopped>(),
        ),
      );
      expect(sameContents(disk.contents, landed), isTrue);
    });
  });

  group('One writer', () {
    test(
      'a store whose engine closed hands out nothing that looks current',
      () async {
        final disk = MemoryStorage(seeded);
        final engine = MemoryEngine(disk);
        final store = await openStore(engine);
        pageOf(await store.readPage(strategyId, 'page-a'));
        await engine.close();
        expect(
          store.library,
          isA<LibraryShut>().having(
            (shut) => shut.failure,
            'failure',
            isA<StoreStopped>().having(
              (stopped) => stopped.cause,
              'cause',
              isA<LeaseEnded>(),
            ),
          ),
        );
        expect(
          await store.readPage(strategyId, 'page-a'),
          isA<NotRead<PageContent>>(),
        );
        expect(
          await store.readStrategy(strategyId),
          isA<NotRead<StrategyContent>>(),
        );
      },
    );

    test('a closed store hands out nothing that looks current', () async {
      final store = await openOn(seeded);
      pageOf(await store.readPage(strategyId, 'page-a'));
      expect(await store.close(), isA<Released>());
      expect(
        store.library,
        isA<LibraryShut>().having(
          (shut) => shut.failure,
          'failure',
          isA<StoreClosed>(),
        ),
      );
      expect(
        await store.readPage(strategyId, 'page-a'),
        isA<NotRead<PageContent>>(),
      );
    });

    test('a second store on the same storage does not open', () async {
      final disk = MemoryStorage(seeded);
      final first = await openStore(MemoryEngine(disk));
      expect(
        await LibraryStore.open(MemoryEngine(disk), canRead: readsKnownKinds),
        isA<StoreNotOpened>().having(
          (opening) => opening.problem,
          'problem',
          isA<StoreAlreadyOpen>(),
        ),
      );
      await first.close();
      await (await openStore(MemoryEngine(disk))).close();
    });

    test(
      'a store whose engine closed refuses, and never takes the storage back',
      () async {
        final disk = MemoryStorage(seeded);
        final engineA = MemoryEngine(disk);
        final storeA = await openStore(engineA);
        strategyOf(await storeA.readStrategy(strategyId));
        await engineA.close();
        final storeB = await openStore(MemoryEngine(disk));
        savedValue(
          await storeB.commit(
            strategyId,
            const StrategyPatchOp(
              opId: 'rename',
              expectedStrategyRevision: 1,
              name: 'Renamed by B',
            ),
          ),
        );
        await storeB.close();
        final stale = await storeA.commit(
          strategyId,
          const StrategyPatchOp(
            opId: 'map',
            expectedStrategyRevision: 1,
            mapData: 'lotus',
          ),
        );
        expect(
          stale,
          isA<NotSaved<Committed, CommitRefusal>>().having(
            (result) => result.failure,
            'failure',
            isA<StoreStopped>().having(
              (failure) => failure.cause,
              'cause',
              isA<LeaseEnded>(),
            ),
          ),
        );
        expect(
          await storeA.commit(strategyId, moveJett),
          isA<NotSaved<Committed, CommitRefusal>>().having(
            (result) => result.failure,
            'failure',
            isA<StoreStopped>(),
          ),
        );
        final fresh = strategyOf(
          await (await openOn(disk.contents)).readStrategy(strategyId),
        );
        expect(headerOf(fresh).name, 'Renamed by B');
        expect(headerOf(fresh).mapData, 'ascent');
      },
    );

    test('closing releases the storage while a listener is paused', () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(MemoryEngine(disk));
      final subscription = store.changes.listen((_) {})..pause();
      savedValue(await store.commit(strategyId, moveJett));
      await store.close().timeout(const Duration(seconds: 2));
      await (await openStore(MemoryEngine(disk))).close();
      await subscription.cancel();
    });

    test('a store says it is closing from the moment close is called, before '
        'its turn runs', () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(MemoryEngine(disk));
      final queued = store.commit(strategyId, moveJett);
      expect(store.isClosing, isFalse);
      final closing = store.close();
      expect(store.isClosing, isTrue);
      expect(store.library, isA<LibraryOpen>());
      expect(describeSaving(await queued), 'saved');
      await closing;
      expect(store.isClosing, isTrue);
    });

    test('a closed store saves and reads nothing', () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(MemoryEngine(disk));
      final queued = store.commit(strategyId, moveJett);
      await store.close();
      expect(describeSaving(await queued), 'saved');
      expect(
        await store.commit(strategyId, everyOpType()['strategy.patch']!),
        isA<NotSaved<Committed, CommitRefusal>>().having(
          (result) => result.failure,
          'failure',
          isA<StoreClosed>(),
        ),
      );
      expect(
        await store.readPage(strategyId, 'page-a'),
        isA<NotRead<PageContent>>(),
      );
      final current = await openStore(MemoryEngine(disk));
      await store.close();
      expect(
        await LibraryStore.open(MemoryEngine(disk), canRead: readsKnownKinds),
        isA<StoreNotOpened>(),
      );
      await current.close();
    });
  });

  group('Decoding what is stored', () {
    const tooEarly = -8640000000000001;

    test(
      'a summary with a time out of range is rebuilt from the rows',
      () async {
        final library = {...seeded['library']!};
        final summary = stored(seeded, 'library', summaryName(strategyId));
        library[summaryName(strategyId)] = jsonEncode({
          ...summary,
          'createdAt': tooEarly,
        });
        final store = await openOn({...seeded, 'library': library});
        expect(listOf(store).strategies.single.createdAt, strategyCreatedAt);
      },
    );

    test(
      'a strategy row with a time out of range lists as unreadable',
      () async {
        final header = stored(seeded, sampleArea, 'strategy');
        final library = {...seeded['library']!}
          ..remove(summaryName(strategyId));
        final store = await openOn({
          ...seeded,
          'library': {...library, summaryName(strategyId): '{}'},
          sampleArea: {
            ...seeded[sampleArea]!,
            'strategy': jsonEncode({...header, 'updatedAt': tooEarly}),
          },
        });
        expect(listOf(store).strategies, isEmpty);
        expect(
          listOf(store).unreadableStrategies.single.header,
          isA<HeaderPlaced>().having(
            (placed) => placed.row,
            'row',
            isA<UnreadableStrategy>().having(
              (row) => row.publicId,
              'id',
              strategyId,
            ),
          ),
        );
        final content = strategyOf(await store.readStrategy(strategyId));
        expect(content.strategy, isA<UnreadableStrategy>());
        expect(content.pages, hasLength(3));
      },
    );

    test('a page trashed at a time out of range reads as unreadable', () async {
      final page = stored(seeded, sampleArea, pageName('page-c'));
      final store = await openOn({
        ...seeded,
        sampleArea: {
          ...seeded[sampleArea]!,
          pageName('page-c'): jsonEncode({
            ...page,
            'deleted': true,
            'deletedAt': tooEarly,
            'deletedBy': 'you',
          }),
        },
      });
      final pages = strategyOf(await store.readStrategy(strategyId)).pages;
      expect(
        pages.firstWhere((row) => row.publicId == 'page-c'),
        isA<UnreadablePage>().having((row) => row.trashed, 'trashed', true),
      );
    });
  });

  group('Rows this build cannot read keep their place and id', () {
    Contents withHeldPage() => {
      ...seeded,
      sampleArea: {
        ...seeded[sampleArea]!,
        pageName('page-b'): jsonEncode({
          'publicId': 'page-b',
          'strategyPublicId': strategyId,
          'sortIndex': 1,
          'deleted': false,
          'layout': 'from a newer build',
        }),
      },
    };

    test('pages cannot be moved across an unreadable page', () async {
      final store = await openOn(withHeldPage());
      expect(
        await store.commit(
          strategyId,
          const PageReorderOp(
            opId: 'onto-held',
            pagePublicId: 'page-c',
            sortIndex: 0,
            expectedStrategyRevision: 1,
          ),
        ),
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<OpRefusal>().having(
            (reason) => reason.refusal,
            'refusal',
            const UnreadableTarget(PageKey('page-b')),
          ),
        ),
      );
      savedValue(
        await store.commit(
          strategyId,
          const PageAddOp(
            opId: 'after-held',
            pagePublicId: 'page-d',
            sortIndex: 3,
            expectedStrategyRevision: 1,
            settings: defaultSettings,
          ),
        ),
      );
    });

    test('an element cannot take the id an unreadable element holds', () async {
      final store = await openOn(seeded);
      expect(
        await store.commit(
          strategyId,
          ElementAddOp(
            opId: 'take-smoke',
            elementPublicId: 'smoke',
            pagePublicId: 'page-b',
            payload: agent('smoke').payload,
            sortIndex: 0,
          ),
        ),
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

    for (final (heldOn, addedOn) in [
      ('page-a', 'page-b'),
      ('page-b', 'page-a'),
    ]) {
      test(
        'an element added on $addedOn beside a row with no id on $heldOn stays findable after a reopen',
        () async {
          final disk = MemoryStorage({
            ...seeded,
            sampleArea: {
              ...seeded[sampleArea]!,
              elementName(heldOn, 'twin'): garbledJson,
            },
          });
          final store = await openStore(MemoryEngine(disk));
          savedValue(
            await store.commit(
              strategyId,
              ElementAddOp(
                opId: 'beside',
                elementPublicId: 'twin',
                pagePublicId: addedOn,
                payload: agent('twin').payload,
                sortIndex: 0,
              ),
            ),
          );
          await store.close();
          expect(
            disk.contents[sampleArea]![elementName(heldOn, 'twin')],
            garbledJson,
          );
          final reopened = await openStore(MemoryEngine(disk));
          savedValue(
            await reopened.commit(
              strategyId,
              ElementReorderOp(
                opId: 'move-twin',
                elementPublicId: 'twin',
                pagePublicId: addedOn,
                sortIndex: 4,
                expectedElementRevision: 1,
              ),
            ),
          );
        },
      );
    }

    test('a page holding a row that is not JSON is not copied', () async {
      final store = await openOn(seeded);
      expect(
        await store.commit(
          strategyId,
          const PageAddOp(
            opId: 'copy-a',
            pagePublicId: 'copy-a',
            sortIndex: 3,
            expectedStrategyRevision: 1,
            copyContentFromPagePublicId: 'page-a',
          ),
        ),
        isA<Refused<Committed, CommitRefusal>>(),
      );
    });
  });

  group('Summaries', () {
    test(
      'kept in step on every commit equal a rebuild from the rows',
      () async {
        for (final MapEntry(key: name, value: op) in everyOpType().entries) {
          final disk = MemoryStorage(seeded);
          final store = await openStore(MemoryEngine(disk));
          final kept = savedValue(
            await store.commit(strategyId, op),
          ).change.summary;
          await store.close();
          final fresh = await openOn(disk.contents);
          expect(
            await fresh.rebuildSummary(strategyId),
            isA<NothingToSave<StrategySummary, CommitRefusal>>(),
            reason: name,
          );
          expect(listOf(fresh).strategies.single, kept, reason: name);
        }
      },
    );

    test('a trashed page leaves the counts', () async {
      final store = await openOn(seeded);
      final summary = savedValue(
        await store.commit(strategyId, everyOpType()['page.delete']!),
      ).change.summary;
      expect(summary.pageCount, 2);
      expect(summary.itemCount, 2);
      expect(summary.agents, ['kayo', 'omen']);
      expect(summary.sides, Sides.mixed);
    });

    test(
      'agents in order are each page\'s placed agents by place, then its lineup origins, pages by sort index, each agent once',
      () async {
        LiveLineupGroup group(String id, String page, int place, String type) =>
            LiveLineupGroup(
              strategyPublicId: 'ordered',
              publicId: id,
              pagePublicId: page,
              payload: LineupGroupPayload(
                payloadVersion: 1,
                data: {
                  'id': id,
                  'origins': [
                    {
                      'id': '$id-o',
                      'agent': {'type': type, 'lineUpID': id},
                    },
                  ],
                  'landings': [landing('$id-l')],
                  'links': [
                    {'id': '$id-k', 'originId': '$id-o', 'landingId': '$id-l'},
                  ],
                },
              ),
              sortIndex: place,
              revision: 1,
            );
        LivePage page(String id, int place, {required bool attack}) => LivePage(
          publicId: id,
          strategyPublicId: 'ordered',
          name: id,
          sortIndex: place,
          isAttack: attack,
          revision: 1,
        );
        final rows = StrategyRowSet(
          strategy: strategyRow(publicId: 'ordered'),
          pages: [
            page('later', 1, attack: true),
            page('first', 0, attack: false),
          ],
          settings: [settings('later'), settings('first')],
          elements: [
            agent('omen', type: 'omen', pageId: 'first', sortIndex: 3),
            agent('jett', pageId: 'first', sortIndex: 1),
            agent('sova', type: 'sova', pageId: 'first', sortIndex: 2),
            DeletedElement(
              publicId: 'breach',
              pagePublicId: 'first',
              payload: agent('breach', type: 'breach').payload,
              sortIndex: 0,
              revision: 1,
            ),
            agent('jett-again', pageId: 'later', sortIndex: 0),
            agent('kayo', type: 'kayo', pageId: 'later', sortIndex: 1),
          ],
          lineupGroups: [
            group('late', 'first', 1, 'killjoy'),
            group('early', 'first', 0, 'viper'),
            group('next', 'later', 0, 'fade'),
          ],
        );
        final store = await openOn(await seededClean());
        savedValue(await store.editLibrary([AddStrategy(rows)]));
        final summary = listOf(
          store,
        ).strategies.singleWhere((s) => s.publicId == 'ordered');
        expect(summary.agentsInOrder, [
          'jett',
          'sova',
          'omen',
          'viper',
          'killjoy',
          'kayo',
          'fade',
        ]);
        expect(summary.firstPageIsAttack, isFalse);
      },
    );

    test(
      'agents at the same place are in the order the page is read in, by row id',
      () async {
        final rows = StrategyRowSet(
          strategy: strategyRow(publicId: 'tied'),
          pages: [
            LivePage(
              publicId: 'only',
              strategyPublicId: 'tied',
              name: 'only',
              sortIndex: 0,
              isAttack: true,
              revision: 1,
            ),
          ],
          settings: [settings('only')],
          elements: [
            agent('b-jett', pageId: 'only'),
            agent('a-raze', type: 'raze', pageId: 'only'),
            agent('c-sova', type: 'sova', pageId: 'only', sortIndex: 1),
          ],
          lineupGroups: const [],
        );
        final store = await openOn(await seededClean());
        savedValue(await store.editLibrary([AddStrategy(rows)]));
        expect(
          listOf(
            store,
          ).strategies.singleWhere((s) => s.publicId == 'tied').agentsInOrder,
          ['raze', 'jett', 'sova'],
        );
      },
    );

    test(
      'a page tally keeps each agent type once, however many agents are placed',
      () async {
        final rows = StrategyRowSet(
          strategy: strategyRow(publicId: 'crowded'),
          pages: [
            LivePage(
              publicId: 'busy',
              strategyPublicId: 'crowded',
              name: 'busy',
              sortIndex: 0,
              isAttack: true,
              revision: 1,
            ),
          ],
          settings: [settings('busy')],
          elements: [
            for (var n = 0; n < 30; n++)
              agent(
                'agent-$n',
                type: const ['jett', 'sova', 'omen'][n % 3],
                pageId: 'busy',
                sortIndex: n,
              ),
          ],
          lineupGroups: const [],
        );
        final store = await openOn(await seededClean());
        savedValue(await store.editLibrary([AddStrategy(rows)]));
        final summary = listOf(
          store,
        ).strategies.singleWhere((s) => s.publicId == 'crowded');
        final tally = summary.tallies['busy']!.toJson();
        expect(summary.agentsInOrder, ['jett', 'sova', 'omen']);
        expect(
          tally.keys,
          unorderedEquals(['items', 'agents', 'damaged', 'newer', 'order']),
        );
        expect(tally['order'], ['jett', 'sova', 'omen']);
      },
    );

    test(
      'a summary written by the build before this one is rebuilt on open with the tile\'s fields',
      () async {
        final opened = await openOn(seeded);
        final current = listOf(opened).strategies.single;
        expect(opened.summariesRebuiltAtOpen, 0);
        final store = await openOn(agedSeeded(seeded));
        expect(listOf(store).strategies.single, current);
        expect(store.summariesRebuiltAtOpen, 1);
        expect(current.agentsInOrder, ['jett', 'sova', 'omen', 'kayo']);
        expect(current.firstPageIsAttack, isTrue);
      },
    );

    group('a summary rebuilt at open is written back once', () {
      test('the next open rebuilds none and lists the same summary', () async {
        final disk = MemoryStorage(agedSeeded(seeded));
        final store = await openStore(MemoryEngine(disk));
        final listed = listOf(store).strategies.single;
        expect(store.summariesRebuiltAtOpen, 1);

        expect(
          await store.writeBackRebuiltSummaries(),
          isA<Saved<int, Never>>().having((saved) => saved.value, 'value', 1),
        );
        expect(
          await store.writeBackRebuiltSummaries(),
          isA<NothingToSave<int, Never>>(),
        );
        await store.close();

        final next = await openStore(MemoryEngine(disk));
        expect(next.summariesRebuiltAtOpen, 0);
        expect(listOf(next).strategies.single, listed);
        await next.close();
      });

      test(
          'a write-back the device refuses leaves the store open, and the '
          'next open rebuilds again', () async {
        final disk = MemoryStorage(agedSeeded(seeded));
        final store = await openStore(
          flaky(MemoryEngine(disk), {0: Failing.refused}),
        );

        expect(
          await store.writeBackRebuiltSummaries(),
          isA<NotSaved<int, Never>>(),
        );
        expect(store.library, isA<LibraryOpen>());
        await store.close();
        final next = await openStore(MemoryEngine(disk));
        expect(next.summariesRebuiltAtOpen, 1);
        await next.close();
      });

      for (final (failing, rebuiltNext) in [
        (Failing.landed, 0),
        (Failing.lost, 1),
      ]) {
        test(
            'a write-back whose answer is lost (${failing.name}) shuts the '
            'store as any commit in doubt does, and the next open rebuilds '
            'what did not land', () async {
          final disk = MemoryStorage(agedSeeded(seeded));
          final store = await openStore(
            flaky(MemoryEngine(disk), {0: failing}),
          );

          expect(
            await store.writeBackRebuiltSummaries(),
            isA<SaveInDoubt<int, Never>>(),
          );
          expect(store.library, isA<LibraryShut>());
          final next = await openStore(MemoryEngine(disk));
          expect(next.summariesRebuiltAtOpen, rebuiltNext);
          expect(listOf(next).strategies.single.agentsInOrder,
              ['jett', 'sova', 'omen', 'kayo']);
          await next.close();
        });
      }

      test(
          'a save made before the write-back keeps its own summary, and the '
          'write-back has nothing left to write', () async {
        final disk = MemoryStorage(agedSeeded(seeded));
        final store = await openStore(MemoryEngine(disk));
        savedValue(await store.commit(
          strategyId,
          everyOpType()['strategy.patch']!,
        ));
        final saved = listOf(store).strategies.single;

        expect(
          await store.writeBackRebuiltSummaries(),
          isA<NothingToSave<int, Never>>(),
        );
        await store.close();
        final next = await openStore(MemoryEngine(disk));
        expect(next.summariesRebuiltAtOpen, 0);
        expect(listOf(next).strategies.single, saved);
        await next.close();
      });

      test(
          'a save asked for after the write-back waits its turn and its '
          'summary is the one kept', () async {
        final disk = MemoryStorage(agedSeeded(seeded));
        final store = await openStore(MemoryEngine(disk));

        final writingBack = store.writeBackRebuiltSummaries();
        final saving = store.commit(
          strategyId,
          everyOpType()['strategy.patch']!,
        );
        expect(await writingBack, isA<Saved<int, Never>>());
        savedValue(await saving);
        final saved = listOf(store).strategies.single;
        await store.close();

        final next = await openStore(MemoryEngine(disk));
        expect(next.summariesRebuiltAtOpen, 0);
        expect(listOf(next).strategies.single, saved);
        await next.close();
      });

      test(
          'a save already waiting when the write-back is asked for keeps its '
          'own summary: the write-back never puts the older one over it',
          () async {
        final disk = MemoryStorage(agedSeeded(seeded));
        final store = await openStore(MemoryEngine(disk));
        final rebuilt = listOf(store).strategies.single;

        final saving = store.commit(
          strategyId,
          everyOpType()['strategy.patch']!,
        );
        final writingBack = store.writeBackRebuiltSummaries();
        savedValue(await saving);
        expect(await writingBack, isA<NothingToSave<int, Never>>());
        final saved = listOf(store).strategies.single;
        expect(saved, isNot(rebuilt));
        await store.close();

        final next = await openStore(MemoryEngine(disk));
        expect(next.summariesRebuiltAtOpen, 0);
        expect(listOf(next).strategies.single, saved);
        await next.close();
      });

      test(
          'a cloud strategy\'s rebuilt summary is never written back: its '
          'standing depends on the build, so each open rebuilds it', () async {
        final storage = MemoryStorage();
        final cloud = await openCloudStore(MemoryEngine(storage));
        await addCloud(cloud, initialRows());
        await cloud.close();
        final aged = MemoryStorage(agedSummary(storage.contents, strategyId));

        final store = await openCloudStore(MemoryEngine(aged));
        expect(store.summariesRebuiltAtOpen, 1);
        expect(
          await store.writeBackRebuiltSummaries(),
          isA<NothingToSave<int, Never>>(),
        );
        await store.close();

        final next = await openCloudStore(MemoryEngine(aged));
        expect(next.summariesRebuiltAtOpen, 1);
        await next.close();
      });

      test(
          'a store closed before the write-back writes nothing, and the next '
          'open rebuilds again', () async {
        final disk = MemoryStorage(agedSeeded(seeded));
        final store = await openStore(MemoryEngine(disk));
        await store.close();

        expect(
          await store.writeBackRebuiltSummaries(),
          isA<NotSaved<int, Never>>(),
        );
        final next = await openStore(MemoryEngine(disk));
        expect(next.summariesRebuiltAtOpen, 1);
        await next.close();
      });
    });

    test('a summary this build cannot read is rebuilt from the rows', () async {
      final store = await openOn({
        ...seeded,
        'library': {
          ...seeded['library']!,
          summaryName(strategyId): '{"summaryVersion":9}',
        },
      });
      final summary = listOf(store).strategies.single;
      expect(summary.itemCount, 6);
      expect(summary.createdAt, strategyCreatedAt);
      expect(listOf(store).unreadableStrategies, isEmpty);
    });
  });

  group('Library edits', () {
    ReadableFolder folder(String id, {String? parent}) =>
        ReadableFolder(publicId: id, name: id, parentFolderPublicId: parent);

    test(
      'a move into a folder and back in one edit is nothing to save, however often it is asked',
      () async {
        final disk = MemoryStorage(seeded);
        final store = await openStore(MemoryEngine(disk));
        savedValue(await store.editLibrary([PutFolder(folder('f'))]));
        final before = {
          for (final MapEntry(:key, :value) in disk.contents.entries)
            key: {...value},
        };
        for (var round = 0; round < 2; round++) {
          expect(
            await store.editLibrary([
              const MoveStrategy(strategyId, 'f'),
              const MoveStrategy(strategyId, null),
            ]),
            isA<NothingToSave<LibraryEdited, LibraryRefusal>>(),
            reason: 'round $round',
          );
        }
        expect(sameContents(disk.contents, before), isTrue);
        expect(listOf(store).strategies.single.folderPublicId, isNull);
      },
    );

    test('several moves of one strategy in one edit advance it once', () async {
      final store = await openOn(seeded);
      savedValue(
        await store.editLibrary([
          PutFolder(folder('f')),
          PutFolder(folder('g')),
        ]),
      );
      final edited = savedValue(
        await store.editLibrary([
          const MoveStrategy(strategyId, 'f'),
          const MoveStrategy(strategyId, 'g'),
        ]),
      );
      expect(edited.summaries.single.folderPublicId, 'g');
      expect(
        headerOf(strategyOf(await store.readStrategy(strategyId))).revision,
        2,
      );
    });

    test(
      'a strategy added and moved twice in one edit is stored once, at its own revision',
      () async {
        final disk = MemoryStorage(seeded);
        final store = await openStore(MemoryEngine(disk));
        final added = sampleStrategy(id: 'strategy-new', prefix: 'new-');
        savedValue(
          await store.editLibrary([
            PutFolder(folder('f')),
            PutFolder(folder('g')),
            AddStrategy(added),
            const MoveStrategy('strategy-new', 'f'),
            const MoveStrategy('strategy-new', 'g'),
          ]),
        );
        final header = headerOf(
          strategyOf(await store.readStrategy('strategy-new')),
        );
        expect(header.folderPublicId, 'g');
        expect(header.revision, added.strategy.revision);
      },
    );

    test('folders and moves are rows in the same store', () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(MemoryEngine(disk));
      final edited = savedValue(
        await store.editLibrary([
          PutFolder(folder('defaults')),
          PutFolder(folder('ascent', parent: 'defaults')),
          const MoveStrategy(strategyId, 'ascent'),
        ]),
      );
      expect(edited.folders.map((f) => f.publicId), ['defaults', 'ascent']);
      expect(edited.summaries.single.folderPublicId, 'ascent');
      expect(edited.summaries.single.updatedAt, asStored(editedAt));
      await store.close();
      final reopened = await openOn(disk.contents);
      expect(listOf(reopened).folders, hasLength(2));
      expect(listOf(reopened).strategies.single.folderPublicId, 'ascent');
      final header = headerOf(
        strategyOf(await reopened.readStrategy(strategyId)),
      );
      expect(header.folderPublicId, 'ascent');
      expect(header.revision, 2);
    });

    test('a folder that still holds something cannot be removed', () async {
      final store = await openOn(seeded);
      savedValue(
        await store.editLibrary([
          PutFolder(folder('defaults')),
          const MoveStrategy(strategyId, 'defaults'),
        ]),
      );
      expect(
        await store.editLibrary([const RemoveFolder('defaults')]),
        isA<Refused<LibraryEdited, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<FolderNotEmpty>(),
        ),
      );
      savedValue(
        await store.editLibrary([
          const MoveStrategy(strategyId, null),
          const RemoveFolder('defaults'),
        ]),
      );
      expect(listOf(store).folders, isEmpty);
    });

    test('a folder cannot be put inside itself', () async {
      final store = await openOn(seeded);
      savedValue(
        await store.editLibrary([
          PutFolder(folder('a')),
          PutFolder(folder('b', parent: 'a')),
        ]),
      );
      expect(
        await store.editLibrary([PutFolder(folder('a', parent: 'b'))]),
        isA<Refused<LibraryEdited, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<FolderInsideItself>(),
        ),
      );
    });

    test(
      'a removed strategy leaves nothing behind, unreadable rows included',
      () async {
        final disk = MemoryStorage(seeded);
        final store = await openStore(MemoryEngine(disk));
        savedValue(await store.editLibrary([const RemoveStrategy(strategyId)]));
        expect(disk.contents, {
          libraryArea: {formatKey: '$storeFormat'},
        });
        expect(listOf(store).strategies, isEmpty);
        expect(
          await store.readStrategy(strategyId),
          isA<NotFound<StrategyContent>>(),
        );
      },
    );

    test(
      'a strategy cannot be added again, or over rows stored for it',
      () async {
        final store = await openOn(seeded);
        expect(
          await store.editLibrary([AddStrategy(sampleStrategy())]),
          isA<Refused<LibraryEdited, LibraryRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<StrategyAlreadyInStore>(),
          ),
        );
        final leftover = await openOn({
          sampleArea: {'strategy': '{"publicId":"newer'},
        });
        expect(
          await leftover.editLibrary([AddStrategy(sampleStrategy())]),
          isA<Refused<LibraryEdited, LibraryRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<StrategyAlreadyInStore>(),
          ),
        );
      },
    );

    test('a strategy whose rows name another strategy is refused', () async {
      final sample = sampleStrategy(id: 'strategy-2', prefix: 'x-');
      final store = await openOn(seeded);
      for (final (name, rows) in [
        (
          'a page of another strategy',
          StrategyRowSet(
            strategy: sample.strategy,
            pages: [...sample.pages, page('stray', sortIndex: 4)],
          ),
        ),
        (
          'an element on a page it does not have',
          StrategyRowSet(
            strategy: sample.strategy,
            pages: sample.pages,
            elements: [agent('lost', pageId: 'page-a')],
          ),
        ),
      ]) {
        expect(
          await store.editLibrary([AddStrategy(rows)]),
          isA<Refused<LibraryEdited, LibraryRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<RowOutsideStrategy>(),
          ),
          reason: name,
        );
      }
    });
  });

  group('Rows with no id', () {
    final garbledArea = strategyArea('strategy-garbled');

    Contents withGarbledStrategy(Contents base) => {
      ...base,
      'library': {
        ...base['library']!,
        summaryName('strategy-garbled'): '{"broken"',
      },
      garbledArea: {'strategy': '{"broken"'},
    };

    test(
      'an unreadable strategy is listed by its reference, and removing it takes that reference',
      () async {
        final storage = MemoryStorage(seeded);
        final setup = await openStore(MemoryEngine(storage));
        savedValue(
          await setup.editLibrary([
            AddStrategy(sampleStrategy(id: garbledArea, prefix: 'named-')),
          ]),
        );
        await setup.close();
        final disk = MemoryStorage(withGarbledStrategy(storage.contents));
        final store = await openStore(MemoryEngine(disk));
        final listing = listOf(store).unreadableStrategies.single;
        expect(listing.ref, StrategyRef(garbledArea));
        expect(listing.header, isA<HeaderUnplaced>());
        expect(
          listOf(store).strategies.map((summary) => summary.publicId),
          unorderedEquals([strategyId, garbledArea]),
        );
        expect(
          await store.editLibrary([
            RemoveUnreadableStrategy(StrategyRef(strategyArea('elsewhere'))),
          ]),
          isA<Refused<LibraryEdited, LibraryRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<NoSuchUnreadableStrategy>(),
          ),
        );
        savedValue(
          await store.editLibrary([RemoveUnreadableStrategy(listing.ref)]),
        );
        expect(disk.contents[garbledArea], isNull);
        expect(
          disk.contents['library']![summaryName('strategy-garbled')],
          isNull,
        );
        expect(
          disk.contents[strategyArea(garbledArea)],
          storage.contents[strategyArea(garbledArea)],
        );
        expect(listOf(store).unreadableStrategies, isEmpty);
        expect(
          listOf(store).strategies.map((summary) => summary.publicId),
          unorderedEquals([strategyId, garbledArea]),
        );
      },
    );

    test(
      'settings with no id stay apart from the settings of a page whose id is that name',
      () async {
        final storage = MemoryStorage();
        final setup = await openStore(MemoryEngine(storage));
        final odd = settingsName('page-a');
        savedValue(
          await setup.editLibrary([
            AddStrategy(
              StrategyRowSet(
                strategy: strategyRow(),
                pages: [
                  LivePage(
                    publicId: 'page-a',
                    strategyPublicId: strategyId,
                    name: 'Page 1',
                    sortIndex: 0,
                    isAttack: true,
                    revision: 1,
                  ),
                  LivePage(
                    publicId: odd,
                    strategyPublicId: strategyId,
                    name: 'Page 2',
                    sortIndex: 1,
                    isAttack: true,
                    revision: 1,
                  ),
                ],
                settings: [settings('page-a'), settings(odd)],
              ),
            ),
          ]),
        );
        await setup.close();
        final store = await openOn({
          ...storage.contents,
          sampleArea: {...storage.contents[sampleArea]!, odd: '{"pagePub'},
        });
        final content = strategyOf(await store.readStrategy(strategyId));
        expect(content.settings.keys, [odd]);
        expect(content.settings[odd], isA<ReadablePageSettings>());
        expect(content.unplaced.single.ref, StoredRowRef(sampleArea, odd));
      },
    );

    test('an edit uses the changes it was given when it was called', () async {
      final store = await openOn(seeded);
      final changes = <LibraryChange>[
        PutFolder(ReadableFolder(publicId: 'f1', name: 'Ascent')),
      ];
      final reading = store.readStrategy(strategyId);
      final editing = store.editLibrary(changes);
      changes
        ..clear()
        ..add(const RemoveStrategy(strategyId));
      await reading;
      savedValue(await editing);
      expect(listOf(store).folders.map((folder) => folder.publicId), ['f1']);
      expect(listOf(store).strategies, hasLength(1));
    });

    test('a commit names each name once, keeping the last', () async {
      final (engine, counts) = counting(MemoryEngine(MemoryStorage(seeded)));
      final store = await openStore(engine);
      counts.reset();
      savedValue(
        await store.editLibrary([
          PutFolder(ReadableFolder(publicId: 'f1', name: 'Ascent')),
          PutFolder(ReadableFolder(publicId: 'f1', name: 'Bind')),
        ]),
      );
      expect(counts.written, [('library', folderName('f1'))]);
      expect((listOf(store).folders.single as ReadableFolder).name, 'Bind');
    });

    test(
      'a page read that finds rows the summary does not count rebuilds it',
      () async {
        final stale = {
          ...seeded,
          'library': {
            ...seeded['library']!,
            summaryName(strategyId):
                (await seededClean())['library']![summaryName(strategyId)]!,
          },
        };
        final store = await openOn(stale);
        expect(listOf(store).strategies.single.readability, isA<AllReadable>());
        pageOf(await store.readPage(strategyId, 'page-a'));
        expect(
          listOf(store).strategies.single.readability,
          isA<SomeUnreadable>()
              .having((some) => some.damaged, 'damaged', 1)
              .having((some) => some.newer, 'newer', 2),
        );
      },
    );

    test(
      'a rebuild counts rows of a kind this build does not know apart from damaged ones',
      () async {
        final store = await openOn(seeded);
        expect(
          listOf(store).strategies.single.readability,
          isA<SomeUnreadable>()
              .having((some) => some.damaged, 'damaged', 1)
              .having((some) => some.newer, 'newer', 2),
        );
      },
    );
  });

  group('Rows that are missing', () {
    Contents without(Contents base, String area, Iterable<String> names) => {
      ...base,
      area: {...base[area]!}..removeWhere((key, _) => names.contains(key)),
    };

    SomeUnreadable readabilityOf(LibraryStore store) =>
        listOf(store).strategies.single.readability as SomeUnreadable;

    test(
      'with only a page row gone, its settings and content are kept, reported, counted and in the way',
      () async {
        final clean = await seededClean();
        final before = without(clean, sampleArea, [pageName('page-a')]);
        final disk = MemoryStorage(before);
        final store = await openStore(MemoryEngine(disk));
        final content = strategyOf(await store.readStrategy(strategyId));
        expect(content.pages.map((page) => page.publicId), [
          'page-b',
          'page-c',
        ]);
        expect(content.settings.keys, unorderedEquals(['page-b', 'page-c']));
        expect(
          content.unplaced.map((row) => row.ref.name),
          unorderedEquals([
            settingsName('page-a'),
            elementName('page-a', 'jett'),
            elementName('page-a', 'sova'),
            elementName('page-a', 'line'),
            lineupName('page-a', 'g1'),
          ]),
        );
        expect(
          await store.readPage(strategyId, 'page-a'),
          isA<NotFound<PageContent>>(),
        );
        expect(readabilityOf(store).damaged, 5);
        expect(
          await store.commit(
            strategyId,
            const PageAddOp(
              opId: 'over-orphans',
              pagePublicId: 'page-a',
              sortIndex: 0,
              expectedStrategyRevision: 1,
              settings: defaultSettings,
            ),
          ),
          isA<Refused<Committed, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<UnplacedRowInTheWay>(),
          ),
        );
        expect(
          await store.commit(
            strategyId,
            const PageAddOp(
              opId: 'copy-orphans',
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
            isA<CopyLeavesRowsBehind>(),
          ),
        );
        expect(sameContents(disk.contents, before), isTrue);
      },
    );

    test(
      'a copy from a page id with no row and no content is left to applyOp',
      () async {
        final store = await openOn(await seededClean());
        expect(
          await store.commit(
            strategyId,
            const PageAddOp(
              opId: 'copy-nothing',
              pagePublicId: 'page-copy',
              sortIndex: 3,
              expectedStrategyRevision: 1,
              settings: defaultSettings,
              copyContentFromPagePublicId: 'page-nowhere',
            ),
          ),
          isNot(
            isA<Refused<Committed, CommitRefusal>>().having(
              (refused) => refused.reason,
              'reason',
              isA<CopyLeavesRowsBehind>(),
            ),
          ),
        );
      },
    );

    test(
      'with only the header gone, the strategy reads as unreadable, refuses every write, and is removed by reference',
      () async {
        final before = without(await seededClean(), sampleArea, ['strategy']);
        final disk = MemoryStorage(before);
        final store = await openStore(MemoryEngine(disk));
        final reading = await store.readStrategy(strategyId);
        expect(reading, isA<InUnreadableStrategy<StrategyContent>>());
        final listing =
            (reading as InUnreadableStrategy<StrategyContent>).listing;
        expect(listing.ref, StrategyRef(sampleArea));
        expect(
          await store.readPage(strategyId, 'page-a'),
          isA<InUnreadableStrategy<PageContent>>(),
        );
        final notReadable = isA<StrategyNotReadable>().having(
          (reason) => reason.ref,
          'ref',
          StrategyRef(sampleArea),
        );
        expect(
          await store.commit(strategyId, moveJett),
          isA<Refused<Committed, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            notReadable,
          ),
        );
        expect(
          await store.editLibrary([const RemoveStrategy(strategyId)]),
          isA<Refused<LibraryEdited, LibraryRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            notReadable,
          ),
        );
        expect(sameContents(disk.contents, before), isTrue);
        expect(listOf(store).unreadableStrategies.single.ref, listing.ref);
        savedValue(
          await store.editLibrary([RemoveUnreadableStrategy(listing.ref)]),
        );
        expect(disk.contents[sampleArea], isNull);
        expect(disk.contents['library']?[summaryName(strategyId)], isNull);
      },
    );

    test(
      'with only the summary gone, findStrategies brings the strategy back and the next rebuild writes it',
      () async {
        final clean = await seededClean();
        final disk = MemoryStorage(
          without(clean, 'library', [summaryName(strategyId)]),
        );
        final (engine, counts) = counting(MemoryEngine(disk));
        final store = await openStore(engine);
        expect(listOf(store).strategies, isEmpty);
        counts.reset();
        final found = await store.findStrategies();
        expect(counts.areaListings, ['s/']);
        expect(counts.commits, 0);
        expect(
          found,
          isA<StrategiesFound>()
              .having(
                (found) => found.rebuilt.map((summary) => summary.publicId),
                'rebuilt',
                [strategyId],
              )
              .having((found) => found.unreadable, 'unreadable', isEmpty),
        );
        expect(
          listOf(store).strategies.single.toJson(),
          listOf(await openOn(clean)).strategies.single.toJson(),
        );
        savedValue(await store.rebuildSummary(strategyId));
        expect(sameContents(disk.contents, clean), isTrue);
      },
    );

    test(
      'findStrategies reports an area with rows and neither header nor summary as unreadable',
      () async {
        final clean = await seededClean();
        final disk = MemoryStorage({
          ...without(clean, 'library', [summaryName(strategyId)]),
          sampleArea: {...clean[sampleArea]!}..remove('strategy'),
        });
        final store = await openStore(MemoryEngine(disk));
        final found = await store.findStrategies() as StrategiesFound;
        expect(found.rebuilt, isEmpty);
        expect(found.unreadable.single.ref, StrategyRef(sampleArea));
        expect(
          listOf(store).unreadableStrategies.single.ref,
          StrategyRef(sampleArea),
        );
        expect(await store.findStrategies(), isA<StrategiesFound>());
      },
    );

    test(
      'an edit that loads a page before any read brings the summary up to date',
      () async {
        final stale = {
          ...seeded,
          'library': {
            ...seeded['library']!,
            summaryName(strategyId):
                (await seededClean())['library']![summaryName(strategyId)]!,
          },
        };
        final disk = MemoryStorage(stale);
        final store = await openStore(MemoryEngine(disk));
        savedValue(await store.commit(strategyId, moveJett));
        expect(readabilityOf(store).damaged, 1);
        expect(readabilityOf(store).newer, 2);
        await store.close();
        final again = await openStore(MemoryEngine(disk));
        expect(readabilityOf(again).newer, 2);
      },
    );

    Contents copied(Contents contents) => {
      for (final MapEntry(:key, :value) in contents.entries) key: {...value},
    };

    Future<Map<String, Object?>> listedAfterRebuild(Contents contents) async {
      final store = await openOn(copied(contents));
      await store.rebuildSummary(strategyId);
      return listOf(store).strategies.single.toJson();
    }

    Contents withPageAGone(Contents clean) => without(clean, sampleArea, [
      pageName('page-a'),
      settingsName('page-a'),
      elementName('page-a', 'jett'),
      elementName('page-a', 'sova'),
      elementName('page-a', 'line'),
      lineupName('page-a', 'g1'),
    ]);

    test(
      'moving a strategy into a folder before its rows are read keeps the '
      'summary it is listed with, and reads none of its pages',
      () async {
        final disk = MemoryStorage(
          without(await seededClean(), sampleArea, [pageName('page-a')]),
        );
        final (engine, counts) = counting(MemoryEngine(disk));
        final store = await openStore(engine);
        final before = listOf(store).strategies.single;
        counts.reset();
        savedValue(
          await store.editLibrary([
            PutFolder(ReadableFolder(publicId: 'folder', name: 'Folder')),
            const MoveStrategy(strategyId, 'folder'),
          ]),
        );
        expect(counts.entryListings, isEmpty);
        await store.close();
        final listed = listOf(
          await openStore(MemoryEngine(disk)),
        ).strategies.single;
        expect(listed.folderPublicId, 'folder');
        expect(listed.pageCount, before.pageCount);
        expect(listed.readability, before.readability);
      },
    );

    test(
      'a save on a strategy whose page row is gone counts its orphans once',
      () async {
        final disk = MemoryStorage(
          without(await seededClean(), sampleArea, [pageName('page-a')]),
        );
        final store = await openStore(MemoryEngine(disk));
        savedValue(
          await store.commit(
            strategyId,
            const PageAddOp(
              opId: 'add-d',
              pagePublicId: 'page-d',
              sortIndex: 3,
              expectedStrategyRevision: 1,
              settings: defaultSettings,
            ),
          ),
        );
        expect(readabilityOf(store).damaged, 5);
        expect(
          listOf(store).strategies.single.toJson(),
          await listedAfterRebuild(disk.contents),
        );
      },
    );

    test(
      'a page added under the id of a page that is wholly gone counts only what it holds',
      () async {
        final disk = MemoryStorage(withPageAGone(await seededClean()));
        final store = await openStore(MemoryEngine(disk));
        savedValue(
          await store.commit(
            strategyId,
            const PageAddOp(
              opId: 'add-a-again',
              pagePublicId: 'page-a',
              sortIndex: 0,
              expectedStrategyRevision: 1,
              settings: defaultSettings,
            ),
          ),
        );
        expect(listOf(store).strategies.single.itemCount, 2);
        expect(
          listOf(store).strategies.single.toJson(),
          await listedAfterRebuild(disk.contents),
        );
      },
    );

    test(
      'a page added over orphaned content of a kind this build does not know is refused',
      () async {
        final gone = withPageAGone(await seededClean());
        final before = {
          ...gone,
          sampleArea: {...gone[sampleArea]!, pinName: unknownRowJson},
        };
        final disk = MemoryStorage(before);
        final store = await openStore(MemoryEngine(disk));
        expect(
          await store.commit(
            strategyId,
            const PageAddOp(
              opId: 'over-pin',
              pagePublicId: 'page-a',
              sortIndex: 0,
              expectedStrategyRevision: 1,
              settings: defaultSettings,
            ),
          ),
          isA<Refused<Committed, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<UnplacedRowInTheWay>(),
          ),
        );
        expect(sameContents(disk.contents, before), isTrue);
      },
    );

    test(
      'findStrategies lists a strategy whose rows are all gone as unreadable, which can then be removed',
      () async {
        final clean = await seededClean();
        final disk = MemoryStorage({...clean}..remove(sampleArea));
        final store = await openStore(MemoryEngine(disk));
        expect(listOf(store).strategies.single.publicId, strategyId);
        final found = await store.findStrategies() as StrategiesFound;
        expect(found.rebuilt, isEmpty);
        expect(found.unreadable.single.ref, StrategyRef(sampleArea));
        expect(listOf(store).strategies, isEmpty);
        expect(
          listOf(store).unreadableStrategies.single.ref,
          StrategyRef(sampleArea),
        );
        expect(
          await store.commit(strategyId, moveJett),
          isA<Refused<Committed, CommitRefusal>>(),
        );
        savedValue(
          await store.editLibrary([
            RemoveUnreadableStrategy(StrategyRef(sampleArea)),
          ]),
        );
        expect(disk.contents['library']?[summaryName(strategyId)], isNull);
        expect(listOf(store).unreadableStrategies, isEmpty);
      },
    );

    test(
      'a damaged summary whose strategy has no rows is listed as unreadable at open, and can be removed',
      () async {
        final clean = await seededClean();
        final disk = MemoryStorage(
          {
            ...clean,
            'library': {...clean['library']!, summaryName(strategyId): '{}'},
          }..remove(sampleArea),
        );
        final store = await openStore(MemoryEngine(disk));
        final listing = listOf(store).unreadableStrategies.single;
        expect(listing.ref, StrategyRef(sampleArea));
        expect(listing.header, isA<HeaderAbsent>());
        expect(listOf(store).strategies, isEmpty);
        expect(
          (await store.findStrategies() as StrategiesFound).unreadable,
          isEmpty,
        );
        expect(listOf(store).unreadableStrategies.single.ref, listing.ref);
        savedValue(
          await store.editLibrary([RemoveUnreadableStrategy(listing.ref)]),
        );
        expect(disk.contents['library']?[summaryName(strategyId)], isNull);
      },
    );

    test(
      'findStrategies that cannot read one area changes nothing, and a retry finds every strategy',
      () async {
        final storage = MemoryStorage();
        final seeding = await openStore(MemoryEngine(storage));
        savedValue(
          await seeding.editLibrary([
            AddStrategy(sampleStrategy()),
            AddStrategy(sampleStrategy(id: 'strategy-2', prefix: 'two-')),
          ]),
        );
        await seeding.close();
        final disk = MemoryStorage(
          without(storage.contents, 'library', [
            summaryName(strategyId),
            summaryName('strategy-2'),
          ]),
        );
        final failing = <String>{};
        final store = await openStore(
          WrappingEngine(
            MemoryEngine(disk),
            (lease) => _AreaFailingLease(lease, failing),
          ),
        );
        for (final area in [sampleArea, strategyArea('strategy-2')]) {
          failing
            ..clear()
            ..add(area);
          expect(
            await store.findStrategies(),
            isA<StrategiesNotSearched>(),
            reason: area,
          );
          expect(listOf(store).strategies, isEmpty, reason: area);
          expect(listOf(store).unreadableStrategies, isEmpty, reason: area);
        }
        failing.clear();
        final found = await store.findStrategies() as StrategiesFound;
        expect(
          found.rebuilt.map((summary) => summary.publicId),
          unorderedEquals([strategyId, 'strategy-2']),
        );
        expect(listOf(store).strategies, hasLength(2));
      },
    );

    test(
      'an edit on a strategy that has rows but no summary is saved, and lists the strategy',
      () async {
        final clean = await seededClean();
        final disk = MemoryStorage(
          without(clean, 'library', [summaryName(strategyId)]),
        );
        final store = await openStore(MemoryEngine(disk));
        expect(listOf(store).strategies, isEmpty);
        savedValue(await store.commit(strategyId, moveJett));
        expect(listOf(store).strategies.single.publicId, strategyId);
        expect(disk.contents['library']?[summaryName(strategyId)], isNotNull);
        expect(
          listOf(store).strategies.single.toJson(),
          await listedAfterRebuild(disk.contents),
        );
      },
    );

    test('a page read says whether a settings row is stored', () async {
      final store = await openOn(
        without(await seededClean(), sampleArea, [settingsName('page-b')]),
      );
      expect(
        pageOf(await store.readPage(strategyId, 'page-a')).settings,
        isA<SettingsStored>().having(
          (stored) => stored.row,
          'row',
          isA<ReadablePageSettings>(),
        ),
      );
      expect(
        pageOf(await store.readPage(strategyId, 'page-b')).settings,
        isA<NoSettingsStored>(),
      );
    });

    test('a settings row that cannot be read is counted as damaged', () async {
      final clean = await seededClean();
      final store = await openOn({
        ...clean,
        sampleArea: {
          ...clean[sampleArea]!,
          settingsName('page-b'): jsonEncode({
            'pagePublicId': 'page-b',
            'revision': 'one',
          }),
        },
      });
      strategyOf(await store.readStrategy(strategyId));
      expect(readabilityOf(store).damaged, 1);
    });

    test(
      'a row of a newer kind on a page with no row is counted as newer',
      () async {
        final clean = await seededClean();
        final store = await openOn({
          ...without(clean, sampleArea, [pageName('page-a')]),
          sampleArea: {
            ...without(clean, sampleArea, [pageName('page-a')])[sampleArea]!,
            pinName: unknownRowJson,
          },
        });
        strategyOf(await store.readStrategy(strategyId));
        expect(readabilityOf(store).newer, 1);
        expect(readabilityOf(store).damaged, 5);
      },
    );
  });
}

final class _AreaFailingLease extends ForwardingLease {
  _AreaFailingLease(super.inner, this.failing);

  final Set<String> failing;

  @override
  Future<KeyRead> read(String area, String key) async => failing.contains(area)
      ? const KeyNotRead(DeviceFailure('cannot read'))
      : await super.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      failing.contains(area)
      ? const StorageFailed(DeviceFailure('cannot read'))
      : await super.keys(area, prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async =>
      failing.contains(area)
      ? const StorageFailed(DeviceFailure('cannot read'))
      : await super.entries(area, prefix);
}

final class _RefusingEveryCommit extends ForwardingLease {
  _RefusingEveryCommit(super.inner);

  @override
  Future<Committing> commit(List<Change> changes) async =>
      const CommitRefused(NoRoomForCommit(needed: 1 << 20, left: 0));
}
