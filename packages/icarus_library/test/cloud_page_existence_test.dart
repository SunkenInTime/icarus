import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_ordering_rules_test.dart'
    show arrivalAt, connectedOn, listWithout, pageA, pointAt;
import 'cloud_set_aside_test.dart' show replaced;
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'support.dart';

HeaderRead listWith(PageRow pageA) => HeaderRead(
  strategy: initialRows().strategy,
  pages: [
    pageA,
    for (final row in initialRows().pages)
      if (row.publicId != 'page-a') row,
  ],
  settings: initialRows().settings.toList(),
);

PageRead pageAAs(PageRow row) => PageRead(
  page: row,
  elements: initialRows().elementsOn('page-a').toList(),
  lineupGroups: const [],
);

Set<Target> itemsOnA(Client client) => {
  for (final MapEntry(:key, :value) in client.queue.shown.rows.entries)
    if (value.page == 'page-a') key,
};

void main() {
  group('which pages exist is decided by the newest claim about that page, '
      'whatever kind of result made it', () {
    test('an older list leaving a page out after a newer read of it keeps '
        'the page, its settings, its items and its mark', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(5)));
      client.must(arrivalAt(client, pageA(), pointAt(12)));
      final items = itemsOnA(client);
      final step = client.step(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(10)),
      );
      expect(step, isA<Stepped>());
      expect(
        (step as Stepped).decisions,
        isNot(contains(const PageLeft('page-a'))),
      );
      final shown = client.queue.shown;
      expect(shown.pages, contains('page-a'));
      expect(shown.settings, contains('page-a'));
      expect(shown.content, contains('page-a'));
      expect(itemsOnA(client), items);
      expect(shown.pagesTaken['page-a']?.snapshot, pointAt(12).snapshot);
      expect(shown.listTaken?.snapshot, pointAt(10).snapshot);
    });

    test('the store keeps that page, its settings and its items', () async {
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
      await expectAgree(store);
    });

    test('an older page-gone after a newer list that shows the page is '
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
      expect(client.queue.shown.pagesTaken, isNot(contains('page-a')));
    });

    test('an older page read of a page a newer list leaves out is dropped '
        'and owes nothing', () {
      final client = connectedOn();
      client.must(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(12)),
      );
      expect(
        notApplicable(client.step(arrivalAt(client, pageA(), pointAt(10)))),
        isA<OlderResult>(),
      );
      expect(client.queue.shown.pages, isNot(contains('page-a')));
      expect(client.queue.shown.list, isNot(isA<ReadOwed>()));
      expect(client.effects, isNot(contains(isA<PageResultDeferred>())));
    });

    test('an older page result that shows a page trashed at the same life '
        'and revision leaves the newer list\'s live page live, and still '
        'takes its items', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(30)));
      final trashed = page('page-a', sortIndex: 0, deleted: true);
      expect(trashed, isA<TrashedPage>());
      expect(
        versionOfRow(trashed),
        versionOfRow(initialRows().page('page-a')!),
      );
      client.must(arrivalAt(client, pageAAs(trashed), pointAt(20)));
      final shown = client.queue.shown;
      expect(shown.pages, contains('page-a'));
      expect(shown.trashed, isNot(contains('page-a')));
      expect(shown.pagesTaken['page-a']?.snapshot, pointAt(20).snapshot);
      expect(itemsOnA(client), isNotEmpty);
    });

    test('a list that shows a page live does not bring it back when the '
        'page\'s own newer claim is gone', () {
      final client = connectedOn();
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(5)));
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(4)));
      expect(client.queue.shown.pages, isNot(contains('page-a')));
      expect(client.queue.shown.settings, isNot(contains('page-a')));
    });

    test('lists either side of a page-gone, then a page read and a newer '
        'list', () {
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
          pageAAs(page('page-a', sortIndex: 0, revision: 3)),
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
      final items = itemsOnA(trashed);
      trashed.must(
        arrivalAt(
          trashed,
          listWith(page('page-a', sortIndex: 0, deleted: true, revision: 2)),
          pointAt(8),
        ),
      );
      expect(trashed.queue.shown.trashed, contains('page-a'));
      expect(trashed.queue.shown.pages, isNot(contains('page-a')));
      expect(itemsOnA(trashed), items);
    });

    test('an older page result of a page a newer list shows trashed takes '
        'its items and not its page row', () {
      final client = connectedOn();
      client.must(
        arrivalAt(
          client,
          listWith(page('page-a', sortIndex: 0, deleted: true, revision: 2)),
          pointAt(9),
        ),
      );
      client.must(arrivalAt(client, pageA(), pointAt(8)));
      final shown = client.queue.shown;
      expect(shown.trashed['page-a']?.revision, 2);
      expect(shown.pages, isNot(contains('page-a')));
      expect(shown.list, isNot(isA<ReadOwed>()));
      expect(shown.pagesTaken['page-a']?.snapshot, pointAt(8).snapshot);
      expect(itemsOnA(client), isNotEmpty);
    });
  });

  group('a list and a page result at the same order that disagree about '
      'whether the page exists are reported, and the page stays as held', () {
    test('a list without the page after a page read at its order', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(5)));
      client.must(arrivalAt(client, pageA(), pointAt(10)));
      final items = itemsOnA(client);
      client.effects.clear();
      client.must(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(10)),
      );
      expect(client.queue.shown.pages, contains('page-a'));
      expect(client.queue.shown.settings, contains('page-a'));
      expect(itemsOnA(client), items);
      expect(client.effects, contains(const ReportSameOrderDiffers('page-a')));
      expect(client.queue.shown.listTaken?.snapshot, pointAt(10).snapshot);
    });

    test('a list showing the page after a page-gone at its order', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(5)));
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(10)));
      client.effects.clear();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(10)));
      expect(client.queue.shown.pages, isNot(contains('page-a')));
      expect(client.queue.shown.settings, isNot(contains('page-a')));
      expect(client.queue.shown.pages, contains('page-b'));
      expect(client.effects, contains(const ReportSameOrderDiffers('page-a')));
    });

    test('a page read after a list at its order that leaves the page out', () {
      final client = connectedOn();
      client.must(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(10)),
      );
      client.effects.clear();
      client.must(arrivalAt(client, pageA(), pointAt(10)));
      expect(client.queue.shown.pages, isNot(contains('page-a')));
      expect(client.queue.shown.list, isNot(isA<ReadOwed>()));
      expect(client.queue.shown.pagesTaken, isNot(contains('page-a')));
      expect(client.effects, contains(const ReportSameOrderDiffers('page-a')));
    });

    test('a page-gone after a list at its order that shows the page', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(10)));
      client.effects.clear();
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(10)));
      expect(client.queue.shown.pages, contains('page-a'));
      expect(client.effects, contains(const ReportSameOrderDiffers('page-a')));
    });

    test('a page read showing the page trashed after a list at its order '
        'that shows it live', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(10)));
      client.effects.clear();
      client.must(
        arrivalAt(
          client,
          pageAAs(page('page-a', sortIndex: 0, deleted: true, revision: 2)),
          pointAt(10),
        ),
      );
      expect(client.queue.shown.pages, contains('page-a'));
      expect(client.queue.shown.trashed, isNot(contains('page-a')));
      expect(client.effects, contains(const ReportSameOrderDiffers('page-a')));
    });
  });

  test('a list writes the settings of every page it lists, even after a page '
      'read at its order', () {
    final client = connectedOn();
    client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(5)));
    expect(client.queue.shown.settings['page-a']?.revision, 1);
    const edit = PageSettingsPatchOp(
      opId: 'settings',
      pagePublicId: 'page-a',
      settings: PageSettings(
        agentSize: 2,
        abilitySize: 1,
        useNeutralTeamColors: true,
      ),
      expectedPageSettingsRevision: 1,
    );
    client.edit(edit);
    final attempt = client.claim(['settings']);
    client.must(
      OpAnswered(
        attempt,
        const AppliedAnswer('settings', revision: 2, life: fixtureLife),
        point: pointAt(12),
      ),
    );
    final server = withOp(initialRows(), edit);
    expect(revisionOfRowForTest(server.settingsOf('page-a')!), 2);
    client.must(arrivalAt(client, pageA(server), pointAt(20)));
    final step = client.step(
      arrivalAt(client, headerReadOf(server), pointAt(20)),
    );
    expect(step, isA<Stepped>());
    expect(
      (step as Stepped).decisions,
      contains(RowTaken(server.settingsOf('page-a')!)),
    );
    expect(client.queue.shown.settings['page-a']?.revision, 2);
    expect(client.queue.landed, isEmpty);
  });

  test('a list older than a page result keeps the page in the list a page '
      'delete is decided on', () {
    final client = connectedOn();
    client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(5)));
    client.must(arrivalAt(client, pageA(), pointAt(8)));
    client.edit(pageDelete('del', 'page-a'));
    client.must(arrivalAt(client, pageA(), pointAt(12)));
    client.must(
      arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(10)),
    );
    final shown = client.queue.shown;
    expect(shown.fresh.listed, contains('page-a'));
    expect(shown.pages, contains('page-a'));
    final entry = client.queue.entry('del') as PendingOp;
    expect(
      pageDeleteVerdict(shown, entry.work as CheckedDelete),
      isA<PageAsTheUserSawIt>(),
    );
    expect(client.view('del').sendable, isTrue);
  });

  test('adopting a later life keeps no mark of the old one, so a page-gone '
      'of the new life at a later order removes the page it shows', () {
    final client = connectedOn();
    client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(5)));
    client.must(arrivalAt(client, const PageGone('page-a'), pointAt(30)));
    expect(client.queue.shown.pages, isNot(contains('page-a')));
    final later = replaced(initialRows());
    client.must(arrivalAt(client, headerReadOf(later), pointAt(20)));
    final adopted = client.queue.shown;
    expect(adopted.strategy?.life, createdAtOf(later.strategy));
    expect(adopted.pages, contains('page-a'));
    expect(adopted.pagesTaken, isEmpty);
    expect(adopted.listTaken?.snapshot, pointAt(20).snapshot);
    expect(adopted.listRefusedAt, isNull);
    expect(adopted.pagesRefusedAt, isEmpty);
    client.must(arrivalAt(client, const PageGone('page-a'), pointAt(30)));
    expect(client.queue.shown.pages, isNot(contains('page-a')));
  });
}
