import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_life_forward_test.dart' show replacedWithNewPage, strategyLife;
import 'cloud_set_aside_test.dart' show laterLife, replaced, setAsideIds;
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

void main() {
  group('every read has its own start', () {
    test('two reads started one after the other have different starts, and '
        'the later one taken first makes the earlier page-gone answer '
        'dropped', () {
      final client = Client();
      final first = client.beginRead();
      final second = client.beginRead();
      expect(
        (first as ReadOfThisDevice).started.isBefore(
          (second as ReadOfThisDevice).started,
        ),
        isTrue,
      );
      client.must(
        BaseArrived(
          pageReadOf(initialRows(), 'page-a'),
          session: client.queue.session.number,
          from: second,
        ),
      );
      final late = client.step(
        BaseArrived(
          const PageGone('page-a'),
          session: client.queue.session.number,
          from: first,
        ),
      );
      expect(notApplicable(late), isA<OlderResult>());
      expect(client.queue.shown.pages, contains('page-a'));
    });

    test('a page read started before one already taken is dropped, and the '
        'newer page stays as it was read', () {
      final client = Client();
      final first = client.beginRead();
      final second = client.beginRead();
      final newer = withOp(initialRows(), movePatch('t', x: 9));
      client.must(
        BaseArrived(
          pageReadOf(newer, 'page-a'),
          session: client.queue.session.number,
          from: second,
        ),
      );
      final shown = client.queue.shown;
      final late = client.step(
        BaseArrived(
          pageReadOf(initialRows(), 'page-a'),
          session: client.queue.session.number,
          from: first,
        ),
      );
      expect(notApplicable(late), isA<OlderResult>());
      expect(client.queue.shown.content, shown.content);
      expect(client.queue.shown.fresh, shown.fresh);
    });

    test('nothing read before an adoption is taken after it: a page read in '
        'the first stay in a life is dropped once the record has left the '
        'life and come back', () {
      final client = Client();
      final inFirstStay = client.beginRead();
      client.arrive(headerReadOf(replaced(initialRows())));
      expect(client.queue.shown.strategy?.life, laterLife);
      client.edit(movePatch('move'));
      client.arrive(pageReadOf(replaced(initialRows()), 'page-a'));
      final attempt = client.claim(['move']);
      client.must(BatchRefused(attempt, BatchRefusal.strategyReplaced));
      client.arrive(headerReadOf(initialRows()));
      expect(client.queue.shown.strategy?.life, strategyLife);
      final late = client.step(
        BaseArrived(
          pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
          session: client.queue.session.number,
          from: inFirstStay,
        ),
      );
      expect(notApplicable(late), isNot(isNull));
      expect(client.queue.shown.content.containsKey('page-a'), isFalse);
    });
  });

  group('the review round on 8dac5684', () {
    test('a list read started before an adoption is not taken after it, though '
        'it shows the adopted life', () {
      final client = Client();
      final before = client.beginRead();
      client.arrive(headerReadOf(replaced(initialRows())));
      final late = client.step(
        BaseArrived(
          headerReadOf(replaced(initialRows())),
          session: client.queue.session.number,
          from: before,
        ),
      );
      expect(notApplicable(late), isA<StartedInAnotherLife>());
    });

    test('a result from a session that ended is not taken, and the store '
        'writes nothing for it', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      final ended = await sessionOf(store);
      final from = await readStartOf(store);
      await recordAll(store, [
        const ConnectionLost(),
        const ConnectionReturned(),
      ]);
      final before = Map.of(storage.contents);
      final recorded = await store.record(testAccount, strategyId, [
        BaseArrived(
          pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
          session: ended,
          from: from,
        ),
      ]);
      expect(
        (recorded as Saved<Recorded, CommitRefusal>).value.outcomes.single,
        isA<ReportNotApplicable>().having(
          (outcome) => outcome.why,
          'why',
          isA<FromAnEndedSession>(),
        ),
      );
      expect(storage.contents.keys, before.keys);
    });

    test(
      'a store cannot change where its results come from once chosen',
      () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        expect(
          () => store.takeCloudResultsFrom(CloudResults.liveQueries),
          throwsStateError,
        );
        store.takeCloudResultsFrom(CloudResults.thisDevicesReads);
      },
    );

    test('a store that has not chosen where its results come from refuses to '
        'add a cloud strategy and keeps nothing', () async {
      final store = switch (await LibraryStore.open(
        MemoryEngine(MemoryStorage()),
        canRead: readsKnownKinds,
        clock: fixedClock,
        build: build,
      )) {
        StoreOpened(:final store) => store,
        StoreNotOpened(:final problem) => fail('$problem'),
      };
      expect(
        await store.addCloudStrategy(
          testAccount,
          headerReadOf(initialRows()),
          pageReadsOf(initialRows()),
        ),
        isA<Refused<StrategySummary, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<CloudResultsNotChosen>(),
        ),
      );
      expect(await store.readStrategy(strategyId), isA<NotFound<Object>>());
      expect((store.library as LibraryOpen).list.strategies, isEmpty);
    });

    test('an edit whose read names no life is of another life than a record '
        'that has one: it is set aside, never applied', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      final page =
          ((await store.readPage(strategyId, 'page-a')) as Found<PageContent>)
              .value;
      final lifeless = PageContent(
        strategyLife: null,
        page: page.page,
        settings: page.settings,
        elements: page.elements,
        lineupGroups: page.lineupGroups,
        unknownKinds: page.unknownKinds,
        unplaced: page.unplaced,
        foreignNames: page.foreignNames,
      );
      expect(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('late', x: 77),
          seen: lifeless,
        ),
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<EditOfAReplacedStrategy>(),
        ),
      );
      expect(setAsideIds((await syncOf(store)).queue), ['late']);
    });

    test(
      'an op id already kept aside cannot be used again, on either path',
      () {
        final client = Client();
        client.must(
          UserEdited(
            (client.editEvent(movePatch('kept')) as UserEdited).edit,
            madeOn: laterLife,
          ),
        );
        expect(setAsideIds(client.queue), ['kept']);
        expect(
          notApplicable(
            client.step(
              UserEdited(
                (client.editEvent(movePatch('kept', elementId: 'e2'))
                        as UserEdited)
                    .edit,
                madeOn: laterLife,
              ),
            ),
          ),
          isA<OpIdTaken>(),
        );
        expect(
          notApplicable(
            client.step(client.editEvent(movePatch('kept', elementId: 'e2'))),
          ),
          isA<OpIdTaken>(),
        );
        client.edit(movePatch('queued', elementId: 'e2'));
        expect(
          notApplicable(
            client.step(
              UserEdited(
                (client.editEvent(movePatch('queued', elementId: 'e3'))
                        as UserEdited)
                    .edit,
                madeOn: laterLife,
              ),
            ),
          ),
          isA<OpIdTaken>(),
        );
      },
    );
  });

  group('a commit takes the life from the read it was built from', () {
    test(
      'an edit built from a read made before the replacement is set aside, '
      'though it is committed after the record adopted the replacement',
      () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, initialRows());
        await recordAll(store, [const AppRestarted(build: build)]);
        final seen =
            (await store.readPage(strategyId, 'page-a')) as Found<PageContent>;
        await recordAll(store, [
          BaseArrived(
            headerReadOf(replaced(initialRows())),
            session: await sessionOf(store),
            from: await readStartOf(store),
          ),
        ]);
        final committed = await store.commitAs(
          testAccount,
          strategyId,
          movePatch('late', x: 77),
          seen: seen.value,
        );
        expect(
          committed,
          isA<Refused<Committed, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<EditOfAReplacedStrategy>(),
          ),
        );
        expect(setAsideIds((await syncOf(store)).queue), ['late']);
      },
    );
  });

  group(
    'a record takes results from one source, fixed by the mode at start',
    () {
      test('live results are taken in the order they arrive: a live list of a '
          'later life adopts it', () {
        final client = Client();
        client.edit(movePatch('move'));
        final step = client.step(
          BaseArrived(
            headerReadOf(replaced(initialRows())),
            session: client.queue.session.number,
            from: const LiveResult(),
          ),
        );
        expect(step, isA<Stepped>());
        expect(client.queue.shown.strategy?.life, laterLife);
        expect(setAsideIds(client.queue), ['move']);
      });

      test('a live list of the same life pays the list\'s debt, as the source '
          'of shadow mode', () {
        final client = Client();
        client.must(const ResultRefused(page: null, problem: 'unreadable'));
        expect(isDebt(client.queue.shown.list), isTrue);
        client.must(
          BaseArrived(
            headerReadOf(initialRows()),
            session: client.queue.session.number,
            from: const LiveResult(),
          ),
        );
        expect(client.queue.shown.list, const ReadThisSession());
      });

      test('in send mode a live list of the same life is not taken and pays '
          'nothing', () async {
        final store = await openCloudStore(
          MemoryEngine(MemoryStorage()),
          results: CloudResults.thisDevicesReads,
        );
        await addCloud(store, initialRows());
        await recordAll(store, [
          const AppRestarted(build: build),
          const ResultRefused(page: null, problem: 'unreadable'),
        ]);
        final recorded = await store.record(testAccount, strategyId, [
          BaseArrived(
            headerReadOf(initialRows()),
            session: await sessionOf(store),
            from: const LiveResult(),
          ),
        ]);
        expect(
          (recorded as Saved<Recorded, CommitRefusal>).value.outcomes.single,
          isA<ReportNotApplicable>().having(
            (outcome) => outcome.why,
            'why',
            isA<NotThisModesResults>(),
          ),
        );
        expect(isDebt((await syncOf(store)).queue.shown.list), isTrue);
      });

      test('in send mode a live list of a later life is not taken', () async {
        final store = await openCloudStore(
          MemoryEngine(MemoryStorage()),
          results: CloudResults.thisDevicesReads,
        );
        await addCloud(store, initialRows());
        await recordAll(store, [const AppRestarted(build: build)]);
        final before = (await syncOf(store)).queue;
        final recorded = await store.record(testAccount, strategyId, [
          BaseArrived(
            headerReadOf(replaced(initialRows())),
            session: before.session.number,
            from: const LiveResult(),
          ),
        ]);
        expect(
          (recorded as Saved<Recorded, CommitRefusal>).value.outcomes.single,
          isA<ReportNotApplicable>().having(
            (outcome) => outcome.why,
            'why',
            isA<NotThisModesResults>(),
          ),
        );
        expect(
          (await syncOf(store)).queue.shown.strategy?.life,
          before.shown.strategy?.life,
        );
      });

      test('in shadow mode a replacement is followed: the live list adopts the '
          'later life, live page results fill its pages, and a read of this '
          'device is not taken', () async {
        final store = await openCloudStore(
          MemoryEngine(MemoryStorage()),
          results: CloudResults.liveQueries,
        );
        await addCloud(store, initialRows());
        await recordAll(store, [const AppRestarted(build: build)]);
        savedValue(
          await store.commitAs(
            testAccount,
            strategyId,
            movePatch('move'),
            seen:
                ((await store.readPage(strategyId, 'page-a'))
                        as Found<PageContent>)
                    .value,
          ),
        );
        final session = await sessionOf(store);
        final newer = replacedWithNewPage(initialRows(), laterLife);
        await recordAll(store, [
          BaseArrived(
            headerReadOf(newer),
            session: session,
            from: const LiveResult(),
          ),
          BaseArrived(
            pageReadOf(newer, 'page-a'),
            session: session,
            from: const LiveResult(),
          ),
        ]);
        final queue = (await syncOf(store)).queue;
        expect(queue.shown.strategy?.life, laterLife);
        expect(setAsideIds(queue), ['move']);
        final page = await store.readPage(strategyId, 'page-a');
        expect(
          (page as Found<PageContent>).value.elements.map(
            (row) => row.publicId,
          ),
          contains('n1'),
        );
        final recorded = await store.record(testAccount, strategyId, [
          BaseArrived(
            pageReadOf(newer, 'page-a'),
            session: session,
            from: readFrom(queue),
          ),
        ]);
        expect(
          (recorded as Saved<Recorded, CommitRefusal>).value.outcomes.single,
          isA<ReportNotApplicable>(),
        );
      });
    },
  );
}
