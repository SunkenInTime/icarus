import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_set_aside_test.dart' show laterLife, replaced, setAsideIds;
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

const thirdLife = laterLife + 86400000;

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
        ),
      );
      expect(late, isA<NotApplicable>());
      expect(client.queue, same(before));
      client.arrive(headerReadOf(replaced(initialRows())));
      expect(client.queue.strategy.setAside.count, 1);
      expect([for (final entry in client.queue.entries) entry.id], ['new']);
    });

    test('after STRATEGY_REPLACED the debt is paid only by a list of a later '
        'life: a refused read keeps the restriction, and a list of the '
        'refused life or an earlier one does not pay it', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(BatchRefused(attempt, BatchRefusal.strategyReplaced));
      client.must(const ResultRefused(page: null, problem: 'lifeless'));
      for (final life in [
        strategyCreatedAt.millisecondsSinceEpoch,
        strategyCreatedAt.millisecondsSinceEpoch - 1000,
      ]) {
        client.step(
          BaseArrived(
            headerReadOf(replaced(initialRows(), life: life)),
            session: client.queue.session.number,
          ),
        );
        expect(isDebt(client.queue.shown.list), isTrue);
        expect(client.view('move').sendable, isFalse);
      }
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

  group('a page result is applied only in the life the list shows for its '
      'page', () {
    Future<LibraryStore> withQueuedAdd() async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      savedValue(
        await store.commitAs(testAccount, strategyId, elementAdd('add')),
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
        BaseArrived(pageReadOf(newer, 'page-n'), session: session),
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
          BaseArrived(headerReadOf(trashed), session: session),
          BaseArrived(pageReadOf(trashed, 'page-b'), session: session),
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
        BaseArrived(headerReadOf(withoutB), session: session),
        BaseArrived(pageReadOf(initialRows(), 'page-b'), session: session),
      ]);
      expect(
        await store.readPage(strategyId, 'page-b'),
        isA<NotFound<Object>>(),
      );
      await recordAll(store, [
        BaseArrived(headerReadOf(withoutB), session: session),
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
        BaseArrived(pageReadOf(newer, 'page-a'), session: session),
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
        BaseArrived(headerReadOf(newer), session: session),
      ]);
      await store.record(testAccount, strategyId, [
        BaseArrived(pageReadOf(initialRows(), 'page-a'), session: session),
      ]);
      final queue = (await syncOf(store)).queue;
      expect(queue.shown.pagesToRead, contains('page-a'));
      final page = await store.readPage(strategyId, 'page-a');
      expect((page as Found<PageContent>).value.elements, isEmpty);
      await recordAll(store, [
        BaseArrived(headerReadOf(newer), session: session),
      ]);
      expect((await syncOf(store)).queue.shown.pagesToRead, contains('page-a'));
    });
  });
}
