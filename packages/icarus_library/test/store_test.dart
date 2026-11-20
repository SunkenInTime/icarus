import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = (await seededEngine()).contents;
  });

  final moveJett = everyOpType()['element.patch']!;

  group('Reading', () {
    test('the library list shows each strategy from its summary', () async {
      final store = await openStore(MemoryEngine(seeded));
      final [summary] = store.library.strategies;
      expect(summary.publicId, strategyId);
      expect(summary.name, 'Retake B');
      expect(summary.mapData, 'ascent');
      expect(summary.folderPublicId, isNull);
      expect(summary.createdAt, createdAt);
      expect(summary.updatedAt, createdAt);
      expect(summary.pageCount, 3);
      expect(summary.sides, Sides.mixed);
      expect(summary.agents, ['jett', 'kayo', 'omen', 'sova']);
      expect(summary.itemCount, 6);
    });

    test('a strategy reads as its row and its pages in order', () async {
      final store = await openStore(MemoryEngine(seeded));
      final content = strategyOf(await store.readStrategy(strategyId));
      expect(content.strategy.name, 'Retake B');
      expect(content.pages.map((page) => page.publicId), [
        'page-a',
        'page-b',
        'page-c',
      ]);
      expect(
        content.settings.keys,
        containsAll(['page-a', 'page-b', 'page-c']),
      );
    });

    test('a page reads its own rows and the rows it cannot read', () async {
      final store = await openStore(MemoryEngine(seeded));
      final content = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(
        content.elements.map((row) => row.publicId),
        unorderedEquals(['jett', 'sova', 'line', 'smoke']),
      );
      expect(content.elements.whereType<UnreadableElement>(), hasLength(1));
      expect(content.lineupGroups.single.publicId, 'g1');
      expect(
        content.unreadable.map((row) => (row.key, row.text)),
        unorderedEquals([
          ('content/page-a/element/garbled', garbledJson),
          ('content/page-a/pin/pin-1', unknownRowJson),
        ]),
      );
    });

    test('a strategy or page that is not there reads as not found', () async {
      final store = await openStore(MemoryEngine(seeded));
      expect(
        await store.readStrategy('nope'),
        isA<NotFound<StrategyContent>>(),
      );
      expect(
        await store.readPage(strategyId, 'nope'),
        isA<NotFound<PageContent>>(),
      );
    });
  });

  group('Saving an edit', () {
    test(
      'says what changed, how to undo it, and keeps it across a reopen',
      () async {
        final disk = MemoryEngine(seeded);
        final store = await openStore(disk);
        final changes = <StoreChange>[];
        final listening = store.changes.listen(changes.add);
        final edited = savedValue(await store.commit(strategyId, moveJett));
        final write = edited.writes.single as RowChanged;
        expect(write.after.key, const ElementKey('jett'));
        expect(write.dataFields, {'position'});
        expect(edited.undo, isA<UndoWithOp>());
        expect(edited.summary.updatedAt, editedAt);
        await pumpEventQueue();
        expect(changes.single, same(edited));
        await listening.cancel();

        final reopened = await openStore(MemoryEngine(disk.contents));
        final jett = pageOf(
          await reopened.readPage(strategyId, 'page-a'),
        ).elements.firstWhere((row) => row.publicId == 'jett');
        expect(jett, write.after);
        expect(reopened.library.strategies.single, edited.summary);
      },
    );

    test('an op that changes nothing saves nothing', () async {
      final disk = CountingEngine(MemoryEngine(seeded));
      final store = await openStore(disk);
      savedValue(await store.commit(strategyId, moveJett));
      disk.reset();
      expect(
        await store.commit(strategyId, moveJett),
        isA<NothingToSave<StrategyEdited, CommitRefusal>>(),
      );
      expect(disk.keyWrites, 0);
    });

    test('an op the rows refuse is refused with the reason', () async {
      final store = await openStore(MemoryEngine(seeded));
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
        isA<Refused<StrategyEdited, CommitRefusal>>().having(
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
      final store = await openStore(MemoryEngine(seeded));
      expect(
        await store.commit('nope', moveJett),
        isA<Refused<StrategyEdited, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<NoSuchStrategy>(),
        ),
      );
    });

    test('edits sent together are saved one after another', () async {
      final store = await openStore(MemoryEngine(seeded));
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
        final disk = MemoryEngine(seeded);
        final store = await openStore(disk);
        savedValue(
          await store.commit(
            strategyId,
            everyOpType()['element.patch to another page']!,
          ),
        );
        final reopened = await openStore(MemoryEngine(disk.contents));
        final a = pageOf(await reopened.readPage(strategyId, 'page-a'));
        final b = pageOf(await reopened.readPage(strategyId, 'page-b'));
        expect(a.elements.map((row) => row.publicId), isNot(contains('jett')));
        expect(b.elements.map((row) => row.publicId), contains('jett'));
      },
    );
  });

  group('When the device cannot save', () {
    test('a failed write of the saved edit leaves the edit unsaved', () async {
      final disk = MemoryEngine(seeded);
      final flaky = FlakyEngine(disk);
      final store = await openStore(flaky);
      flaky.failing.add(flaky.calls);
      expect(
        await store.commit(strategyId, moveJett),
        isA<NotSaved<StrategyEdited, CommitRefusal>>(),
      );
      expect(sameContents(disk.contents, seeded), isTrue);
      expect(describeSaving(await store.commit(strategyId, moveJett)), 'saved');
    });

    test(
      'a saved edit whose rows fail to write is finished before the next',
      () async {
        final disk = MemoryEngine(seeded);
        final flaky = FlakyEngine(disk);
        final store = await openStore(flaky);
        flaky.failing.add(flaky.calls + 1);
        final first = savedValue(await store.commit(strategyId, moveJett));
        expect(disk.contents.containsKey('journal'), isTrue);
        final second = savedValue(
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
        expect(disk.contents.containsKey('journal'), isFalse);
        final reopened = await openStore(MemoryEngine(disk.contents));
        final jett =
            pageOf(
                  await reopened.readPage(strategyId, 'page-a'),
                ).elements.firstWhere((row) => row.publicId == 'jett')
                as LiveElement;
        expect(
          jett.payload,
          (first.writes.single.after as LiveElement).payload,
        );
        expect(jett, second.writes.single.after);
      },
    );

    test(
      'a next edit is not saved while an earlier one cannot be finished',
      () async {
        final disk = MemoryEngine(seeded);
        final flaky = FlakyEngine(disk);
        final store = await openStore(flaky);
        final start = flaky.calls;
        flaky.failing.addAll([start + 1, start + 4]);
        savedValue(await store.commit(strategyId, moveJett));
        expect(
          await store.commit(strategyId, everyOpType()['element.reorder']!),
          isA<NotSaved<StrategyEdited, CommitRefusal>>(),
        );
        final reopened = await openStore(MemoryEngine(disk.contents));
        final page = pageOf(await reopened.readPage(strategyId, 'page-a'));
        final line = page.elements.firstWhere((row) => row.publicId == 'line');
        expect((line as LiveElement).sortIndex, 0);
        final jett = page.elements.firstWhere((row) => row.publicId == 'jett');
        expect((jett as LiveElement).revision, 2);
      },
    );

    test(
      'when the device fails to save and then to clear, the store stops',
      () async {
        final flaky = FlakyEngine(MemoryEngine(seeded));
        final store = await openStore(flaky);
        flaky.failing.addAll([flaky.calls, flaky.calls + 1]);
        expect(
          await store.commit(strategyId, moveJett),
          isA<SaveInDoubt<StrategyEdited, CommitRefusal>>(),
        );
        expect(
          await store.commit(strategyId, moveJett),
          isA<NotSaved<StrategyEdited, CommitRefusal>>().having(
            (result) => result.failure,
            'failure',
            isA<StoreStopped>(),
          ),
        );
      },
    );

    test(
      'a read waits for a saved edit to be finished before reading',
      () async {
        final flaky = FlakyEngine(MemoryEngine());
        final store = await openStore(flaky);
        flaky.failing.add(flaky.calls + 1);
        savedValue(
          await store.editLibrary([
            AddStrategy(
              sampleStrategy(),
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          ]),
        );
        final content = strategyOf(await store.readStrategy(strategyId));
        expect(content.pages, hasLength(3));
        final page = pageOf(await store.readPage(strategyId, 'page-a'));
        expect(page.elements, hasLength(3));
        expect(page.lineupGroups, hasLength(1));
      },
    );

    test(
      'a saved edit this build cannot read stops the store opening',
      () async {
        final opening = await LibraryStore.open(
          MemoryEngine({
            ...seeded,
            'journal': {'edit': '{"journalVersion":2}'},
          }),
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
  });

  group('Summaries', () {
    test(
      'kept in step on every commit equal a rebuild from the rows',
      () async {
        for (final MapEntry(key: name, value: op) in everyOpType().entries) {
          final disk = MemoryEngine(seeded);
          final store = await openStore(disk);
          final kept = savedValue(await store.commit(strategyId, op)).summary;
          final fresh = await openStore(MemoryEngine(disk.contents));
          expect(
            await fresh.rebuildSummary(strategyId),
            isA<NothingToSave<StrategySummary, CommitRefusal>>(),
            reason: name,
          );
          expect(fresh.library.strategies.single, kept, reason: name);
        }
      },
    );

    test('a trashed page leaves the counts, and its sides', () async {
      final store = await openStore(MemoryEngine(seeded));
      final summary = savedValue(
        await store.commit(strategyId, everyOpType()['page.delete']!),
      ).summary;
      expect(summary.pageCount, 2);
      expect(summary.itemCount, 2);
      expect(summary.agents, ['kayo', 'omen']);
      expect(summary.sides, Sides.mixed);
    });

    test(
      'a summary this build cannot read is rebuilt when the store opens',
      () async {
        final disk = MemoryEngine({
          ...seeded,
          'library': {
            ...seeded['library']!,
            'summary/$strategyId':
                '{"summaryVersion":2,"createdAt":1767322800000,"updatedAt":1767322800000}',
          },
        });
        final store = await openStore(disk);
        final summary = store.library.strategies.single;
        expect(summary.itemCount, 6);
        expect(summary.createdAt, createdAt);
        expect(store.library.unreadable, isEmpty);
      },
    );
  });

  group('Library edits', () {
    FolderRow folder(String id, {String? parent}) =>
        FolderRow(publicId: id, name: id, parentFolderPublicId: parent);

    test('folders and moves are rows in the same store', () async {
      final disk = MemoryEngine(seeded);
      final store = await openStore(disk);
      final edited = savedValue(
        await store.editLibrary([
          PutFolder(folder('defaults')),
          PutFolder(folder('ascent', parent: 'defaults')),
          const MoveStrategy(strategyId, 'ascent'),
        ]),
      );
      expect(edited.folders.map((f) => f.publicId), ['defaults', 'ascent']);
      expect(edited.summaries.single.folderPublicId, 'ascent');
      final reopened = await openStore(MemoryEngine(disk.contents));
      expect(reopened.library.folders, hasLength(2));
      expect(reopened.library.strategies.single.folderPublicId, 'ascent');
      final header = strategyOf(
        await reopened.readStrategy(strategyId),
      ).strategy;
      expect(header.folderPublicId, 'ascent');
      expect(header.revision, 2);
    });

    test('a folder that still holds something cannot be removed', () async {
      final store = await openStore(MemoryEngine(seeded));
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
      expect(store.library.folders, isEmpty);
    });

    test('a folder cannot be put inside itself', () async {
      final store = await openStore(MemoryEngine(seeded));
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

    test('a removed strategy leaves nothing behind', () async {
      final disk = MemoryEngine(seeded);
      final store = await openStore(disk);
      savedValue(await store.editLibrary([const RemoveStrategy(strategyId)]));
      expect(disk.contents, isEmpty);
      expect(store.library.strategies, isEmpty);
      expect(
        await store.readStrategy(strategyId),
        isA<NotFound<StrategyContent>>(),
      );
    });

    test('a strategy already in the store cannot be added again', () async {
      final store = await openStore(MemoryEngine(seeded));
      expect(
        await store.editLibrary([
          AddStrategy(
            sampleStrategy(),
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        ]),
        isA<Refused<LibraryEdited, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<StrategyAlreadyInStore>(),
        ),
      );
    });

    test(
      'a crash at any write of a library edit leaves before or after',
      () async {
        final edit = [
          const PutFolder(FolderRow(publicId: 'f', name: 'f')),
          const MoveStrategy(strategyId, 'f'),
        ];
        final cleanDisk = MemoryEngine(seeded);
        final clean = CountingEngine(cleanDisk);
        final cleanStore = await openStore(clean);
        clean.reset();
        savedValue(await cleanStore.editLibrary(edit));
        final after = withoutJournal(cleanDisk.contents);
        for (var allowed = 0; allowed < clean.keyWrites; allowed++) {
          final disk = MemoryEngine(seeded);
          final store = await openStore(
            CrashingEngine(disk, afterWrites: allowed),
          );
          final result = await store.editLibrary(edit);
          final reopened = MemoryEngine(disk.contents);
          await openStore(reopened);
          final rows = withoutJournal(reopened.contents);
          final isBefore = sameContents(rows, withoutJournal(seeded));
          final isAfter = sameContents(rows, after);
          expect(isBefore || isAfter, isTrue, reason: 'crash after $allowed');
          switch (result) {
            case Saved():
              expect(isAfter, isTrue, reason: 'saved, then lost at $allowed');
            case NotSaved():
              expect(isBefore, isTrue, reason: 'kept at $allowed');
            case SaveInDoubt():
              break;
            case NothingToSave() || Refused():
              fail('unexpected ${describeSaving(result)}');
          }
        }
      },
    );
  });

  group('Guards', () {
    test('a second store on the same engine does not open', () async {
      final disk = MemoryEngine(seeded);
      final first = await openStore(disk);
      expect(
        await LibraryStore.open(disk, canRead: readsKnownKinds),
        isA<StoreNotOpened>().having(
          (opening) => opening.problem,
          'problem',
          isA<StoreAlreadyOpen>(),
        ),
      );
      await first.close();
      await (await openStore(disk)).close();
    });

    test('an edit whose keys the engine cannot hold is not saved', () async {
      final disk = MemoryEngine(seeded);
      final store = await openStore(LimitedEngine(disk, maxKeyLength: 60));
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
        isA<NotSaved<StrategyEdited, CommitRefusal>>().having(
          (notSaved) => notSaved.failure,
          'failure',
          isA<KeyTooLong>(),
        ),
      );
      expect(sameContents(disk.contents, seeded), isTrue);
      expect(describeSaving(await store.commit(strategyId, moveJett)), 'saved');
    });

    test(
      'a strategy cannot be added over rows already stored for it',
      () async {
        final disk = MemoryEngine({
          'strategy/$strategyId': {'strategy': '{"publicId":"newer'},
        });
        final store = await openStore(disk);
        expect(
          await store.editLibrary([
            AddStrategy(
              sampleStrategy(),
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          ]),
          isA<Refused<LibraryEdited, LibraryRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<StrategyAlreadyInStore>(),
          ),
        );
        expect(disk.contents['strategy/$strategyId'], {
          'strategy': '{"publicId":"newer',
        });
      },
    );

    test(
      'a rebuild whose write lands but fails is not shown after reopening',
      () async {
        final stale = {
          ...seeded,
          'strategy/$strategyId': {
            ...seeded['strategy/$strategyId']!,
            'content/page-b/element/neon': canonicalRow(
              agent('neon', type: 'neon', pageId: 'page-b'),
            ),
          },
        };
        final disk = MemoryEngine(stale);
        final flaky = FlakyEngine(disk);
        final store = await openStore(flaky);
        flaky.failing.add(flaky.calls);
        flaky.landing.add(flaky.calls);
        expect(
          await store.rebuildSummary(strategyId),
          isA<NotSaved<StrategySummary, CommitRefusal>>(),
        );
        final reopened = withoutJournal(await settledContentsOf(disk.contents));
        expect(
          reopened['library']!['summary/$strategyId'],
          stale['library']!['summary/$strategyId'],
        );
      },
    );

    test(
      'a crash while a summary is rebuilt leaves it before or after',
      () async {
        final stale = {
          ...seeded,
          'strategy/$strategyId': {
            ...seeded['strategy/$strategyId']!,
            'content/page-b/element/neon': canonicalRow(
              agent('neon', type: 'neon', pageId: 'page-b'),
            ),
          },
        };
        final before = stale['library']!['summary/$strategyId'];
        for (var allowed = 0; allowed < 3; allowed++) {
          final cut = MemoryEngine(stale);
          final store = await openStore(
            CrashingEngine(cut, afterWrites: allowed),
          );
          final result = await store.rebuildSummary(strategyId);
          final stored = withoutJournal(
            (await settledContentsOf(cut.contents)),
          )['library']!['summary/$strategyId'];
          switch (result) {
            case Saved(:final value):
              expect(value.agents, contains('neon'));
              expect(
                stored,
                isNot(before),
                reason: 'saved, then lost at $allowed',
              );
            case NotSaved():
              expect(stored, before, reason: 'not saved, yet kept at $allowed');
            case SaveInDoubt():
              break;
            case NothingToSave() || Refused():
              fail('unexpected ${describeSaving(result)}');
          }
        }
      },
    );
  });
}
