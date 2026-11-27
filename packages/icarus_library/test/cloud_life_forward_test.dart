import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_result_order_test.dart' show onNextConnection;
import 'cloud_set_aside_test.dart' show laterLife, replaced, setAsideIds;
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

const thirdLife = laterLife + 86400000;
final strategyLife = strategyCreatedAt.millisecondsSinceEpoch;
final yearAhead = strategyLife + 365 * 86400000;

StrategyRowSet withPageLife(StrategyRowSet rows, String page, int life) =>
    rows.withRows([
      bornIn(
        LivePage(
          publicId: page,
          strategyPublicId: strategyId,
          name: 'Page 1',
          sortIndex: 0,
          isAttack: true,
          revision: 1,
        ),
        life,
      ),
    ]);

StrategyRowSet replacedWithNewPage(StrategyRowSet rows, int life) =>
    withPageLife(replaced(rows, life: life), 'page-a', life + 1).withRows([
      LiveElement(
        publicId: 'n1',
        pagePublicId: 'page-a',
        payload: agentPayload('n1', const {}),
        sortIndex: 0,
        revision: 1,
        unknownFields: jsonObject({'createdAt': life + 2}),
      ),
    ]);

void main() {
  group('a strategy\'s life only moves forward', () {
    test('a delayed list of an earlier life is dropped: the record keeps its '
        'life and the edit made on the replacement is never set aside', () {
      final client = Client();
      client.edit(movePatch('old'));
      client.read(replaced(initialRows()));
      expect(setAsideIds(client.queue), ['old']);
      client.edit(movePatch('new', elementId: 'e2'));
      final before = client.queue;
      final late = client.step(
        BaseArrived(
          headerReadOf(initialRows()),
          session: client.queue.session.number,
          point: tick(),
        ),
      );
      expect(late, isA<NotApplicable>());
      expect(client.queue, same(before));
      client.arrive(headerReadOf(replaced(initialRows())));
      expect(client.queue.strategy.setAside.count, 1);
      expect([for (final entry in client.queue.entries) entry.id], ['new']);
    });

    test('after STRATEGY_REPLACED a refused read keeps the restriction, and '
        'an earlier list read started before the refusal is dropped', () {
      final client = Client();
      client.edit(movePatch('move'));
      final beforeRefusal = tick();
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(attempt, BatchRefusal.strategyReplaced, point: tick()),
      );
      client.must(client.readRefused(null, 'lifeless'));
      final late = client.step(
        BaseArrived(
          headerReadOf(replaced(initialRows(), life: strategyLife - 1000)),
          session: client.queue.session.number,
          point: beforeRefusal,
        ),
      );
      expect(notApplicable(late), isA<OlderResult>());
      expect(client.queue.shown.strategy?.life, strategyLife);
      expect(isDebt(client.queue.shown.list), isTrue);
      expect(client.view('move').sendable, isFalse);
      client.arrive(headerReadOf(replaced(initialRows())));
      expect(setAsideIds(client.queue), ['move']);
    });

    test('a strategy seen as gone and then replaced is present again, and an '
        'edit of the replacement can be sent', () {
      final client = Client();
      client.edit(movePatch('old'));
      client.arrive(const StrategyGone());
      expect(standingOf(client.queue), Standing.deletedOnServer);
      client.read(replaced(initialRows()));
      expect(standingOf(client.queue), Standing.good);
      client.edit(movePatch('new', elementId: 'e2'));
      expect(client.view('new').sendable, isTrue);
    });
  });

  group('a STRATEGY_REPLACED that names the current life', () {
    test(
      'a list of the named life is adopted, and a list of any life between '
      'the record\'s and the named one is dropped with the list still owed',
      () {
        final client = Client();
        client.edit(movePatch('move'));
        final attempt = client.claim(['move']);
        client.must(
          BatchRefused(
            attempt,
            BatchRefusal.strategyReplaced,
            currentLife: thirdLife,
            point: tick(),
          ),
        );
        expect(
          client.queue.shown.list,
          owed(unlessLife: strategyLife, namedLife: thirdLife),
        );
        final between = client.step(
          BaseArrived(
            headerReadOf(replaced(initialRows(), life: laterLife)),
            session: client.queue.session.number,
            point: tick(),
          ),
        );
        expect(notApplicable(between), isA<OlderResult>());
        expect(client.queue.shown.strategy?.life, strategyLife);
        expect(isDebt(client.queue.shown.list), isTrue);
        client.arrive(headerReadOf(replaced(initialRows(), life: thirdLife)));
        expect(client.queue.shown.strategy?.life, thirdLife);
        expect(isDebt(client.queue.shown.list), isFalse);
        expect(setAsideIds(client.queue), ['move']);
      },
    );

    test('a record a year ahead adopts the named earlier life, and drops a '
        'list of any other earlier life', () {
      final client = Client();
      client.read(replaced(initialRows(), life: yearAhead));
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(
          attempt,
          BatchRefusal.strategyReplaced,
          currentLife: strategyLife,
          point: tick(),
        ),
      );
      final other = client.step(
        BaseArrived(
          headerReadOf(replaced(initialRows(), life: strategyLife - 1000)),
          session: client.queue.session.number,
          point: tick(),
        ),
      );
      expect(notApplicable(other), isA<OlderResult>());
      expect(client.queue.shown.strategy?.life, yearAhead);
      client.arrive(headerReadOf(initialRows()));
      expect(client.queue.shown.strategy?.life, strategyLife);
      expect(setAsideIds(client.queue), ['move']);
    });

    test('a later refusal of the list keeps the named life', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(
          attempt,
          BatchRefusal.strategyReplaced,
          currentLife: laterLife,
          point: tick(),
        ),
      );
      client.must(client.readRefused(null, 'lifeless'));
      expect(
        client.queue.shown.list,
        isA<ReadRefused>().having(
          (state) => state.namedLife,
          'namedLife',
          laterLife,
        ),
      );
    });
  });

  group('a record holding a later life than the server\'s', () {
    test('after a STRATEGY_REPLACED for the record\'s own life that names no '
        'life, a list of an earlier life on the same connection pays nothing; '
        'one from a later connection is adopted though its life is earlier, '
        'and the edits written in the record\'s life are set aside', () {
      final client = Client();
      client.read(replaced(initialRows(), life: yearAhead));
      expect(client.queue.shown.strategy?.life, yearAhead);
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(attempt, BatchRefusal.strategyReplaced, point: tick()),
      );
      client.step(client.arrival(headerReadOf(initialRows())));
      expect(client.queue.shown.strategy?.life, yearAhead);
      expect(isDebt(client.queue.shown.list), isTrue);
      expect([for (final entry in client.queue.entries) entry.id], ['move']);
      client.arrive(headerReadOf(initialRows()), at: onNextConnection());
      expect(client.queue.shown.strategy?.life, strategyLife);
      expect(client.queue.entries, isEmpty);
      final generation =
          (client.queue.strategy.setAside as SetAside).generations.single;
      expect(generation.writtenIn, yearAhead);
      expect(generation.replacedBy, strategyLife);
      expect(generation.entries.map((entry) => entry.id), ['move']);
    });

    test('a STRATEGY_REPLACED for a life the record has already left does not '
        'open the way out', () {
      final client = Client();
      client.read(replaced(initialRows(), life: yearAhead));
      final left = client.queue.shown.strategy!.life! - 86400000;
      client.queue = CloudQueue(
        entries: client.queue.entries,
        attempts: client.queue.attempts,
        landed: client.queue.landed,
        nextAttempt: client.queue.nextAttempt,
        nextSession: client.queue.nextSession,
        shown: client.queue.shown.owingListPast(
          left,
          ResultAtOrAfter(client.queue.session.orderOf(tick())),
        ),
        strategy: client.queue.strategy,
        session: client.queue.session,
      );
      final step = client.step(
        BaseArrived(
          headerReadOf(initialRows()),
          session: client.queue.session.number,
          point: tick(),
        ),
      );
      expect(notApplicable(step), isA<OlderResult>());
      expect(client.queue.shown.strategy?.life, yearAhead);
    });

    test('without a refusal for its own life, an earlier list is dropped and '
        'the record keeps its life', () {
      final client = Client();
      client.read(replaced(initialRows(), life: yearAhead));
      client.edit(movePatch('move'));
      expect(
        notApplicable(
          client.step(
            BaseArrived(
              headerReadOf(initialRows()),
              session: client.queue.session.number,
              point: tick(),
            ),
          ),
        ),
        isA<OlderResult>(),
      );
      expect(client.queue.shown.strategy?.life, yearAhead);
      expect([for (final entry in client.queue.entries) entry.id], ['move']);
    });
  });

  group('the way out never adopts the life the server just refused', () {
    test('a list showing the very life the server just refused is dropped', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(attempt, BatchRefusal.strategyReplaced, point: tick()),
      );
      final step = client.step(
        BaseArrived(
          headerReadOf(replaced(initialRows(), life: strategyLife)),
          session: client.queue.session.number,
          point: tick(),
        ),
      );
      expect(notApplicable(step), isA<OlderResult>());
      expect(isDebt(client.queue.shown.list), isTrue);
    });
  });

  group('a result is taken only in the life it was read in', () {
    test('a page read started before the record adopted a later life is '
        'dropped unread', () {
      final client = Client();
      client.edit(movePatch('move'));
      final started = tick();
      client.arrive(
        headerReadOf(replacedWithNewPage(initialRows(), laterLife)),
      );
      final step = client.step(
        BaseArrived(
          pageReadOf(replacedWithNewPage(initialRows(), laterLife), 'page-a'),
          session: client.queue.session.number,
          point: started,
        ),
      );
      expect(notApplicable(step), isA<StartedInAnotherLife>());
      expect(client.queue.shown.content.containsKey('page-a'), isFalse);
    });

    test('a page owed after row_replaced is not paid by a read stamped before '
        'the answer, and is paid by one after it', () {
      final client = Client();
      client.edit(movePatch('move'));
      final started = tick();
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
          point: tick(),
        ),
      );
      expect(isDebt(client.queue.shown.pageRead('page-a')), isTrue);
      expect(
        notApplicable(
          client.step(
            BaseArrived(
              pageReadOf(initialRows(), 'page-a'),
              session: client.queue.session.number,
              point: started,
            ),
          ),
        ),
        isA<OlderResult>(),
      );
      expect(isDebt(client.queue.shown.pageRead('page-a')), isTrue);
      client.arrive(pageReadOf(initialRows(), 'page-a'));
      expect(isDebt(client.queue.shown.pageRead('page-a')), isFalse);
    });
  });

  group('a gone answer obeys the rules every result obeys', () {
    Client withPageOwed() {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
          point: tick(),
        ),
      );
      expect(isDebt(client.queue.shown.pageRead('page-a')), isTrue);
      return client;
    }

    test('a page-gone answer read before the page was owed is dropped: the '
        'page stays and is still owed', () {
      final client = Client();
      final before = tick();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
          point: tick(),
        ),
      );
      final step = client.step(
        BaseArrived(
          const PageGone('page-a'),
          session: client.queue.session.number,
          point: before,
        ),
      );
      expect(notApplicable(step), isA<OlderResult>());
      expect(client.queue.shown.pages, contains('page-a'));
      expect(isDebt(client.queue.shown.pageRead('page-a')), isTrue);
    });

    test('a strategy-gone answer read before the list was owed is dropped: '
        'the strategy is not marked gone and the list is still owed', () {
      final client = Client();
      final before = tick();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(attempt, BatchRefusal.strategyReplaced, point: tick()),
      );
      final step = client.step(
        BaseArrived(
          const StrategyGone(),
          session: client.queue.session.number,
          point: before,
        ),
      );
      expect(notApplicable(step), isA<OlderResult>());
      expect(standingOf(client.queue), Standing.good);
      expect(isDebt(client.queue.shown.list), isTrue);
    });

    test(
      'a page-gone answer read in a life the record has left is dropped',
      () {
        final client = withPageOwed();
        final before = tick();
        client.arrive(headerReadOf(replaced(initialRows())));
        final step = client.step(
          BaseArrived(
            const PageGone('page-a'),
            session: client.queue.session.number,
            point: before,
          ),
        );
        expect(notApplicable(step), isNot(isNull));
        expect(client.queue.shown.pages, contains('page-a'));
      },
    );
  });

  group('freshness moves only on a result that was taken', () {
    test('a page read started before the page was owed changes neither the '
        'page nor its freshness', () {
      final client = Client();
      final before = tick();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
          point: tick(),
        ),
      );
      final shown = client.queue.shown;
      final step = client.step(
        BaseArrived(
          pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
          session: client.queue.session.number,
          point: before,
        ),
      );
      expect(notApplicable(step), isA<OlderResult>());
      expect(client.queue.shown.pagesSeen, shown.pagesSeen);
      expect(client.queue.shown.marks, shown.marks);
      expect(client.queue.shown.content, shown.content);
    });
  });

  group('a page result is applied only in the life the list shows for its '
      'page', () {
    Future<LibraryStore> withQueuedAdd() async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      savedValue(
        await store.commitAs(
          testAccount,
          strategyId,
          elementAdd('add'),
          seen: await seenIn(store),
        ),
      );
      return store;
    }

    test('a page the list does not show is not applied, before the '
        'replacement\'s list', () async {
      final store = await withQueuedAdd();
      final session = await sessionOf(store);
      final newer = replacedWithNewPage(initialRows(), laterLife).withRows([
        bornIn(
          LivePage(
            publicId: 'page-n',
            strategyPublicId: strategyId,
            name: 'New',
            sortIndex: 2,
            isAttack: true,
            revision: 1,
          ),
          laterLife + 3,
        ),
        LiveElement(
          publicId: 'n2',
          pagePublicId: 'page-n',
          payload: agentPayload('n2', const {}),
          sortIndex: 0,
          revision: 1,
          unknownFields: jsonObject({'createdAt': laterLife + 4}),
        ),
      ]);
      await recordAll(store, [
        BaseArrived(
          pageReadOf(newer, 'page-n'),
          session: session,
          point: tick(),
        ),
      ]);
      expect(isDebt((await syncOf(store)).queue.shown.list), isTrue);
      expect(
        await store.readPage(strategyId, 'page-n'),
        isA<NotFound<Object>>(),
      );
    });

    test(
      'a page in the trash, which no list shows, is applied: it does not owe '
      'the list',
      () async {
        final store = await withQueuedAdd();
        final session = await sessionOf(store);
        final rows = initialRows();
        final trashed = rows.withRows([
          (rows.page('page-b')! as LivePage).trashed(),
        ]);
        await recordAll(store, [
          BaseArrived(headerReadOf(trashed), session: session, point: tick()),
          BaseArrived(
            pageReadOf(trashed, 'page-b'),
            session: session,
            point: tick(),
          ),
        ]);
        expect(isDebt((await syncOf(store)).queue.shown.list), isFalse);
      },
    );

    test('a page the replacement\'s list removed does not come back from a '
        'late snapshot', () async {
      final store = await withQueuedAdd();
      final session = await sessionOf(store);
      final newer = replaced(initialRows(), life: laterLife);
      final withoutB = StrategyRowSet(
        strategy: newer.strategy,
        pages: newer.pages.where((page) => page.publicId != 'page-b'),
        settings: newer.settings.where((row) => row.pagePublicId != 'page-b'),
        elements: const [],
        lineupGroups: const [],
      );
      await recordAll(store, [
        BaseArrived(headerReadOf(withoutB), session: session, point: tick()),
        BaseArrived(
          pageReadOf(initialRows(), 'page-b'),
          session: session,
          point: tick(),
        ),
      ]);
      expect(
        await store.readPage(strategyId, 'page-b'),
        isA<NotFound<Object>>(),
      );
      await recordAll(store, [
        BaseArrived(headerReadOf(withoutB), session: session, point: tick()),
      ]);
      expect(
        await store.readPage(strategyId, 'page-b'),
        isA<NotFound<Object>>(),
      );
    });

    test('a page of a later life, before its list, is not applied: the list '
        'is owed and nothing old is drawn on the new page', () async {
      final store = await withQueuedAdd();
      final session = await sessionOf(store);
      final newer = replacedWithNewPage(initialRows(), laterLife);
      await recordAll(store, [
        BaseArrived(
          pageReadOf(newer, 'page-a'),
          session: session,
          point: tick(),
        ),
      ]);
      final queue = (await syncOf(store)).queue;
      expect(isDebt(queue.shown.list), isTrue);
      final page = await store.readPage(strategyId, 'page-a');
      expect(
        (page as Found<PageContent>).value.elements.map((row) => row.publicId),
        isNot(contains('n1')),
      );
    });

    test('a page of an earlier life, after the new list, is dropped: nothing '
        'old comes back, and the page is still due to be read', () async {
      final store = await withQueuedAdd();
      final session = await sessionOf(store);
      final newer = replacedWithNewPage(initialRows(), laterLife);
      await recordAll(store, [
        BaseArrived(headerReadOf(newer), session: session, point: tick()),
      ]);
      await store.record(testAccount, strategyId, [
        BaseArrived(
          pageReadOf(initialRows(), 'page-a'),
          session: session,
          point: tick(),
        ),
      ]);
      final queue = (await syncOf(store)).queue;
      expect(queue.shown.pagesToRead, contains('page-a'));
      final page = await store.readPage(strategyId, 'page-a');
      expect((page as Found<PageContent>).value.elements, isEmpty);
      await recordAll(store, [
        BaseArrived(headerReadOf(newer), session: session, point: tick()),
      ]);
      expect((await syncOf(store)).queue.shown.pagesToRead, contains('page-a'));
    });
  });
}
