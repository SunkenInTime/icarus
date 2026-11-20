import 'dart:async';
import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

Map<String, Object?> stored(Contents contents, String area, String key) =>
    jsonDecode(contents[area]![key]!) as Map<String, Object?>;

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = await seededContents();
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
        unorderedEquals(['jett', 'sova', 'line', 'smoke', 'garbled']),
      );
      final garbled = elementOn(content, 'garbled') as UnreadableElement;
      expect(garbled.stored, garbledJson);
      expect(elementOn(content, 'smoke'), isA<UnreadableElement>());
      expect(content.lineupGroups.single.publicId, 'g1');
      expect(content.unknownKinds.single.key, 'content/page-a/pin/pin-1');
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
        expect((header.after as ReadableStrategy).updatedAt, editedAt);
        expect(committed.undo, isA<UndoWithOp>());
        expect(edited.summary.updatedAt, editedAt);
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
        expect(row.updatedAt, editedAt);
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
      expect(counts.calls, 0);
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

    test('a saved edit whose rows fail is finished before the next', () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(
        flaky(MemoryEngine(disk), {1: Failing.refused}),
      );
      savedValue(await store.commit(strategyId, moveJett));
      expect(disk.contents['journal']?['edit'], isNotNull);
      savedValue(
        await store.commit(
          strategyId,
          const ElementReorderOp(
            opId: 'next',
            elementPublicId: 'jett',
            pagePublicId: 'page-a',
            sortIndex: 5,
            expectedElementRevision: 2,
          ),
        ),
      );
      expect(disk.contents['journal']?['edit'], isNull);
      final jett =
          elementOn(
                pageOf(
                  await (await openOn(
                    disk.contents,
                  )).readPage(strategyId, 'page-a'),
                ),
                'jett',
              )
              as LiveElement;
      expect(jett.revision, 3);
      expect(jett.payload.data['position'], {'dx': 300, 'dy': 400});
    });

    test('a read waits for a saved edit to be finished', () async {
      final storage = MemoryStorage();
      final store = await openStore(
        flaky(MemoryEngine(storage), {1: Failing.refused}),
      );
      savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
      final content = strategyOf(await store.readStrategy(strategyId));
      expect(content.pages, hasLength(3));
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(page.elements, hasLength(3));
    });

    test(
      'a saved edit this build cannot read stops the store opening',
      () async {
        final opening = await LibraryStore.open(
          MemoryEngine(
            MemoryStorage({
              ...seeded,
              'journal': {'edit': '{"journalVersion":2}'},
            }),
          ),
          canRead: readsKnownKinds,
        );
        expect(
          opening,
          isA<StoreNotOpened>().having(
            (opening) => opening.problem,
            'problem',
            isA<SavedEditUnreadable>(),
          ),
        );
      },
    );

    test('an edit whose keys the engine cannot hold is not saved', () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(
        WrappingEngine(MemoryEngine(disk), (lease) => LimitedLease(lease, 60)),
      );
      final result = await store.commit(
        strategyId,
        const PageAddOp(
          opId: 'long',
          pagePublicId:
              'a-page-id-long-enough-to-pass-the-limit-of-this-engine',
          sortIndex: 0,
          expectedStrategyRevision: 1,
          settings: defaultSettings,
        ),
      );
      expect(
        result,
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<IdNotStorable>().having(
            (reason) => reason.problem,
            'problem',
            isA<KeyLongerThan>(),
          ),
        ),
      );
      expect(sameContents(disk.contents, seeded), isTrue);
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
            isA<LeaseEnded>(),
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
    const tooEarly = -9223372036854775808;

    test(
      'a summary with a time out of range is rebuilt from the rows',
      () async {
        final library = {...seeded['library']!};
        final summary = stored(seeded, 'library', 'summary/$strategyId');
        library['summary/$strategyId'] = jsonEncode({
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
        final library = {...seeded['library']!}..remove('summary/$strategyId');
        final store = await openOn({
          ...seeded,
          'library': {...library, 'summary/$strategyId': '{}'},
          sampleArea: {
            ...seeded[sampleArea]!,
            'strategy': jsonEncode({...header, 'updatedAt': tooEarly}),
          },
        });
        expect(listOf(store).strategies, isEmpty);
        expect(listOf(store).unreadableStrategies.single.publicId, strategyId);
        final content = strategyOf(await store.readStrategy(strategyId));
        expect(content.strategy, isA<UnreadableStrategy>());
        expect(content.pages, hasLength(3));
      },
    );

    test('a page trashed at a time out of range reads as unreadable', () async {
      final page = stored(seeded, sampleArea, 'page/page-c');
      final store = await openOn({
        ...seeded,
        sampleArea: {
          ...seeded[sampleArea]!,
          'page/page-c': jsonEncode({
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
        'page/page-b': jsonEncode({
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
      for (final id in ['smoke', 'garbled']) {
        expect(
          await store.commit(
            strategyId,
            ElementAddOp(
              opId: 'take-$id',
              elementPublicId: id,
              pagePublicId: 'page-b',
              payload: agent(id).payload,
              sortIndex: 0,
            ),
          ),
          isA<Refused<Committed, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<OpRefusal>().having(
              (reason) => reason.refusal,
              'refusal',
              UnreadableTarget(ElementKey(id)),
            ),
          ),
          reason: id,
        );
      }
    });

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

    test('a summary this build cannot read is rebuilt from the rows', () async {
      final store = await openOn({
        ...seeded,
        'library': {
          ...seeded['library']!,
          'summary/$strategyId': '{"summaryVersion":9}',
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
      expect(edited.summaries.single.updatedAt, editedAt);
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
        expect(withoutJournal(disk.contents), isEmpty);
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
}
