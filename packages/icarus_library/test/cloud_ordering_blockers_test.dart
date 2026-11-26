import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_ordering_rules_test.dart'
    show arrivalAt, connectedOn, pageA, pointAt, stateIn;
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'support.dart';

HeaderRead listWithout(StrategyRowSet rows, String page) => HeaderRead(
  strategy: rows.strategy,
  pages: [
    for (final row in rows.pages)
      if (row.publicId != page) row,
  ],
  settings: [
    for (final row in rows.settings)
      if (row.pagePublicId != page) row,
  ],
);

void main() {
  group('whether a page exists is one fact, ordered across lists and page '
      'results', () {
    test('a list older than a page result taken for a page it leaves out '
        'does not remove the page', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(5)));
      client.must(arrivalAt(client, pageA(), pointAt(12)));
      final step = client.step(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(10)),
      );
      expect(step, isA<Stepped>());
      expect(
        (step as Stepped).decisions,
        isNot(contains(const PageLeft('page-a'))),
      );
      expect(client.queue.shown.pages, contains('page-a'));
      expect(client.queue.shown.content, contains('page-a'));
      expect(
        client.queue.shown.pagesTaken['page-a']?.order.snapshot,
        pointAt(12).snapshot,
      );
    });

    test('the store keeps the page, its settings and its items', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await recordAll(store, [reconnected()]);
      final session = await sessionOf(store);
      BaseArrived at(ArrivedBase base, ResultPoint point) =>
          BaseArrived(base, session: session, point: point);
      final from = tick().snapshot;
      ResultPoint next(int n) => ResultPoint(
        client: testClient,
        connection: currentGeneration.connection,
        snapshot: from + n,
        serverTime: 1795000000000000000 + n,
      );
      await recordAll(store, [
        at(headerReadOf(initialRows()), next(5)),
        at(pageA(), next(12)),
        at(listWithout(initialRows(), 'page-a'), next(10)),
      ]);
      final page = await store.readPage(strategyId, 'page-a');
      expect(page, isA<Found<PageContent>>());
      expect((page as Found<PageContent>).value.elements, isNotEmpty);
    });

    test('a page-gone result older than the list that shows the page is '
        'dropped', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(12)));
      expect(
        notApplicable(
          client.step(arrivalAt(client, const PageGone('page-a'), pointAt(10))),
        ),
        isA<OlderResult>(),
      );
      expect(client.queue.shown.pages, contains('page-a'));
    });
  });

  test('a rename behind our own reorder is not judged current on a list '
      'older than the reorder\'s answer, and is decided on one after it', () {
    final client = connectedOn();
    client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
    client.must(arrivalAt(client, pageA(), pointAt(3)));
    const reorder = PageReorderOp(
      opId: 'reorder',
      pagePublicId: 'page-b',
      sortIndex: 0,
      expectedStrategyRevision: 1,
    );
    client.edit(reorder);
    client.edit(
      const PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-a',
        expectedPageRevision: 1,
        name: 'Mine',
      ),
    );
    final attempt = client.claim(['reorder']);
    client.must(
      OpAnswered(
        attempt,
        AppliedAnswer(
          'reorder',
          revision: 2,
          life: createdAtOf(initialRows().strategy)!,
        ),
        point: pointAt(12),
      ),
    );
    client.must(
      arrivalAt(
        client,
        headerReadOf(withOp(initialRows(), reorder)),
        pointAt(10),
      ),
    );
    expect(client.queue.landed, isEmpty);
    expect(stateIn(client, 'rename'), isNot(isA<NeedsUser>()));
    expect(client.view('rename').holds, contains(isA<AwaitingResult>()));
    client.must(
      arrivalAt(
        client,
        headerReadOf(withOp(initialRows(), reorder)),
        pointAt(13),
      ),
    );
    expect(client.view('rename').holds, isEmpty);
  });

  test('a read requested in one session does not pay a refusal recorded in '
      'the next', () {
    final client = connectedOn();
    client.must(arrivalAt(client, pageA(), pointAt(3)));
    final asked = client.queue.session.number;
    client.edit(movePatch('move', x: 40));
    final attempt = client.claim(['move']);
    client.must(
      OpAnswered(
        attempt,
        const RejectedAnswer(
          'move',
          RejectionReason.rowReplaced,
          NoServerCopy(),
        ),
        point: pointAt(12, later: 1),
      ),
    );
    expect(client.queue.session.number, greaterThan(asked));
    expect(client.queue.shown.pageRead('page-a'), isA<ReadOwed>());
    final late = BaseArrived(
      pageA(),
      session: asked,
      point: pointAt(10, later: 1),
      requestedAt: 99,
    );
    expect(notApplicable(client.step(late)), isA<OlderResult>());
    expect(client.queue.shown.pageRead('page-a'), isA<ReadOwed>());
  });

  group('a result at the order already taken', () {
    test('an answer the taken result already shows leaves the page fresh', () {
      final client = connectedOn();
      client.must(arrivalAt(client, pageA(), pointAt(12)));
      expect(client.queue.shown.fresh.pageFreshFor('page-a'), isTrue);
      client.edit(movePatch('move', x: 40));
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('move', revision: 2, life: fixtureLife),
          point: pointAt(12),
        ),
      );
      expect(client.queue.shown.fresh.pageFreshFor('page-a'), isTrue);
    });

    test('a causal repeat at the taken order pays the refusal debt it would '
        'have paid', () {
      final client = connectedOn();
      client.must(arrivalAt(client, pageA(), pointAt(12)));
      client.edit(movePatch('move', x: 40));
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
          point: pointAt(12),
        ),
      );
      final owed =
          (client.queue.shown.pageRead('page-a') as ReadOwed).since
              as AfterRefusal;
      client.must(
        arrivalAt(client, pageA(), pointAt(12), requestedAt: owed.step),
      );
      expect(client.queue.shown.pageRead('page-a'), const ReadThisSession());
      expect(stateIn(client, 'move'), isA<NeedsUser>());
    });
  });

  group('one rule for whether a page exists', () {
    HeaderRead listWith(PageRow pageA) => HeaderRead(
      strategy: initialRows().strategy,
      pages: [
        pageA,
        for (final row in initialRows().pages)
          if (row.publicId != 'page-a') row,
      ],
      settings: initialRows().settings.toList(),
    );

    test('a list older than a page-gone result taken does not bring the '
        'page back (seed 35)', () {
      final client = connectedOn();
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(5)));
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(4)));
      expect(client.queue.shown.pages, isNot(contains('page-a')));
    });

    test('lists either side of a page-gone, then a page read and a newer '
        'list (seed 11)', () {
      final client = connectedOn();
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(6)));
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(4)));
      client.must(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(5)),
      );
      expect(client.queue.shown.pages, isNot(contains('page-a')));
      client.must(arrivalAt(client, pageA(), pointAt(7)));
      expect(client.queue.shown.pages, isNot(contains('page-a')));
      expect(client.queue.shown.list, isA<ReadOwed>());
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(8)));
      expect(client.queue.shown.pages, contains('page-a'));
    });

    test('a list shows the page, a newer page-gone removes it, an older list '
        'and then a list without it leave it out', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(5)));
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(8)));
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(6)));
      expect(client.queue.shown.pages, isNot(contains('page-a')));
      client.must(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(7)),
      );
      expect(client.queue.shown.pages, isNot(contains('page-a')));
    });

    test('a list and a page result at the same order that disagree are '
        'reported, and the page stays as held', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(5)));
      client.must(arrivalAt(client, pageA(), pointAt(10)));
      client.effects.clear();
      client.must(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(10)),
      );
      expect(client.queue.shown.pages, contains('page-a'));
      expect(client.effects, contains(const ReportResultsDisagree('page-a')));
    });

    test('a newer page result showing a trashed page live waits for the list '
        'to confirm it; a newer list showing it trashed keeps its rows', () {
      final live = connectedOn();
      live.must(
        arrivalAt(
          live,
          listWith(page('page-a', sortIndex: 0, deleted: true, revision: 2)),
          pointAt(5),
        ),
      );
      expect(live.queue.shown.trashed, contains('page-a'));
      live.must(
        arrivalAt(
          live,
          PageRead(
            page: page('page-a', sortIndex: 0, revision: 3),
            elements: initialRows().elementsOn('page-a').toList(),
            lineupGroups: const [],
          ),
          pointAt(8),
        ),
      );
      expect(live.queue.shown.trashed, contains('page-a'));
      expect(live.queue.shown.list, isA<ReadOwed>());
      live.must(
        arrivalAt(
          live,
          listWith(page('page-a', sortIndex: 0, revision: 3)),
          pointAt(9),
        ),
      );
      expect(live.queue.shown.pages, contains('page-a'));
      expect(live.queue.shown.trashed, isNot(contains('page-a')));

      final trashed = connectedOn();
      trashed.must(arrivalAt(trashed, headerReadOf(initialRows()), pointAt(4)));
      trashed.must(arrivalAt(trashed, pageA(), pointAt(5)));
      final items = {
        for (final MapEntry(:key, :value) in trashed.queue.shown.rows.entries)
          if (value.page == 'page-a') key,
      };
      trashed.must(
        arrivalAt(
          trashed,
          listWith(page('page-a', sortIndex: 0, deleted: true, revision: 2)),
          pointAt(8),
        ),
      );
      expect(trashed.queue.shown.trashed, contains('page-a'));
      expect(trashed.queue.shown.pages, isNot(contains('page-a')));
      expect({
        for (final MapEntry(:key, :value) in trashed.queue.shown.rows.entries)
          if (value.page == 'page-a') key,
      }, items);
    });
  });
}
