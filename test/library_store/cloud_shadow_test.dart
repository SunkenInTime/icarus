import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus_library/icarus_library.dart';

import 'hive_scratch.dart';
import 'shadow_copy_test.dart' show handBuilt;

const strategyId = 'hand-1';
const pageId = 'p1';
final at = DateTime.utc(2026, 11, 1);

StrategyRowSet serverRows({Offset agentAt = const Offset(10, 20)}) =>
    switch (strategyToRows(handBuilt(agentAt: agentAt))) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => throw StateError('$problems'),
    };

Map<String, Object?> json(Row row) => row.toJson()! as Map<String, Object?>;

RemotePage remotePage(PageRow row) {
  final fields = json(row);
  return RemotePage(
    publicId: row.publicId,
    strategyPublicId: fields['strategyPublicId']! as String,
    name: fields['name']! as String,
    isAutoNamed: fields['isAutoNamed'] as bool?,
    sortIndex: fields['sortIndex']! as int,
    isAttack: fields['isAttack']! as bool,
    revision: fields['revision']! as int,
    createdAt: at,
    updatedAt: at,
  );
}

RemotePageContent remoteContent(StrategyRowSet rows, String page) {
  final fields = json(rows.settingsOf(page)!);
  return RemotePageContent(
    settings: fields['settings'] as Map<String, dynamic>?,
    revision: fields['revision']! as int,
    createdAt: at,
    updatedAt: at,
  );
}

RemotePageList pageList(
  StrategyRowSet rows, {
  int revision = 1,
  RemotePageContent? content,
  List<RemoteFullPage> more = const [],
  bool withOpenPage = true,
}) {
  final strategy = json(rows.strategy);
  return RemotePageList(
    header: RemoteStrategyHeader(
      publicId: strategyId,
      name: strategy['name']! as String,
      mapData: strategy['mapData']! as String,
      revision: revision,
      createdAt: at,
      updatedAt: at,
      role: 'owner',
    ),
    pages: [
      if (withOpenPage)
        for (final page in rows.pages)
          RemoteFullPage(
            page: remotePage(page),
            content: content ?? remoteContent(rows, page.publicId),
          ),
      ...more,
    ],
  );
}

RemotePageSnapshot pageSnapshot(
  StrategyRowSet rows, {
  RemotePageContent? content,
}) =>
    RemotePageSnapshot(
      page: remotePage(rows.page(pageId)!),
      content: content ?? remoteContent(rows, pageId),
      elements: [
        for (final element in rows.elementsOn(pageId))
          RemoteElement(
            publicId: element.publicId,
            strategyPublicId: strategyId,
            pagePublicId: pageId,
            elementType: (json(element)['payload']! as Map)['kind']! as String,
            payload: Map<String, dynamic>.from(
              json(element)['payload']! as Map,
            ),
            sortIndex: json(element)['sortIndex']! as int,
            revision: json(element)['revision']! as int,
            deleted: json(element)['deleted']! as bool,
          ),
      ],
      lineups: const [],
      assetsById: const {},
    );

Future<LibraryStore> openStore(MemoryStorage storage) async =>
    switch (await LibraryStore.open(
      MemoryEngine(storage),
      canRead: appCanRead,
      build: 'test-build',
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };

int tag(int connection) => connection;

const int? offline = null;

Future<void> none() async {}

final servedAccount = Account('account-a');

CloudShadow shadowOn(
  LibraryStore store, {
  CanRead? canRead,
  Future<void> Function()? breathe,
}) =>
    CloudShadow(
      store,
      build: 'b',
      canRead: canRead ?? appCanRead,
      breathe: breathe ?? none,
    )..serve(servedAccount);

List<Verdict> verdicts(CloudShadow shadow) =>
    [for (final entry in shadow.ledger) entry.verdict];

List<String> sessionsOpened(CloudShadow shadow) => [
      for (final report in shadow.reports)
        if (report is ShadowSessionOpened) report.because,
    ];

RemotePageContent settingsAt(int revision, {double agentSize = 40}) =>
    RemotePageContent(
      settings: {
        'agentSize': agentSize,
        'abilitySize': 30.0,
        'useNeutralTeamColors': false,
      },
      revision: revision,
      createdAt: at,
      updatedAt: at,
    );

RemoteFullPage secondPage() => RemoteFullPage(
      page: RemotePage(
        publicId: 'p2',
        strategyPublicId: strategyId,
        name: 'Page 2',
        sortIndex: 1,
        isAttack: false,
        revision: 1,
        createdAt: at,
        updatedAt: at,
      ),
      content: settingsAt(1),
    );

RemotePageSnapshot emptySecondPage() => RemotePageSnapshot(
      page: secondPage().page,
      content: settingsAt(1),
      elements: const [],
      lineups: const [],
      assetsById: const {},
    );

Matcher get allEqual => everyElement(isA<ComparedEqual>());

void main() {
  test(
      'the first page list adds the strategy, and the open page then '
      'matches the server row for row', () async {
    final store = await openStore(MemoryStorage());
    final rows = serverRows();
    final shadow = shadowOn(store)
      ..pageList(strategyId, pageList(rows), tag(0))
      ..page(strategyId, pageSnapshot(rows), tag(0));
    await shadow.idle;

    expect(verdicts(shadow), [isA<ComparedEqual>(), isA<ComparedEqual>()]);
    expect(sessionsOpened(shadow), ['the strategy was added']);
    final listed = (store.library as LibraryOpen).list.strategies.single;
    expect(listed.sync, isNot(isA<KeptHere>()));
  });

  test(
      'page results that arrive before the first page list are all kept '
      'and recorded in order once it comes', () async {
    final store = await openStore(MemoryStorage());
    final before = serverRows();
    final after = serverRows(agentAt: const Offset(300, 40));
    final shadow = shadowOn(store)
      ..page(strategyId, pageSnapshot(before), tag(0))
      ..page(strategyId, pageSnapshot(after), tag(0))
      ..pageList(strategyId, pageList(before), tag(0));
    await shadow.idle;

    expect(verdicts(shadow), allEqual);
    expect(shadow.ledger, hasLength(3));
    final shown = await store.readPage(strategyId, pageId);
    final element = (shown as Found<PageContent>).value.elements.single;
    expect(element, after.elementsOn(pageId).single);
  });

  test('a teammate\'s edit reaches the store with the next page result',
      () async {
    final store = await openStore(MemoryStorage());
    final before = serverRows();
    final moved = serverRows(agentAt: const Offset(300, 40));
    final after = before.withRows([
      for (final row in moved.elementsOn(pageId))
        if (row case LiveElement element)
          LiveElement(
            publicId: element.publicId,
            pagePublicId: element.pagePublicId,
            payload: element.payload,
            sortIndex: element.sortIndex,
            revision: element.revision + 1,
          ),
    ]);
    final shadow = shadowOn(store)
      ..pageList(strategyId, pageList(before), tag(0))
      ..page(strategyId, pageSnapshot(before), tag(0))
      ..page(strategyId, pageSnapshot(after), tag(0));
    await shadow.idle;

    expect(verdicts(shadow), allEqual);
    final shown = await store.readPage(strategyId, pageId);
    final element = (shown as Found<PageContent>).value.elements.single;
    expect((element as LiveElement).revision, 2);
  });

  group('a result\'s session is the one its tag names', () {
    test(
        'a result read on a new connection opens a session before it is '
        'recorded, even before anything says the connection came back',
        () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(1))
        ..pageList(strategyId, pageList(rows), tag(1));
      await shadow.idle;

      expect(verdicts(shadow), allEqual);
      expect(sessionsOpened(shadow), [
        'the strategy was added',
        'the connection came back',
      ]);
    });

    test(
        'a result read on a connection that has ended is skipped with that '
        'reason', () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(1))
        ..page(strategyId, pageSnapshot(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(1));
      await shadow.idle;

      expect(verdicts(shadow), [
        isA<ComparedEqual>(),
        isA<ComparedEqual>(),
        isA<Skipped>().having(
          (skipped) => skipped.reason,
          'reason',
          SkipReason.endedConnection,
        ),
        isA<ComparedEqual>(),
      ]);
      expect(sessionsOpened(shadow), [
        'the strategy was added',
        'the connection came back',
      ]);
    });

    test(
        'after a first open the store refused, an older connection is still '
        'skipped as ended', () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final stray = RemoteFullPage(
        page: RemotePage(
          publicId: 'stray',
          strategyPublicId: 'another-strategy',
          name: 'Stray',
          sortIndex: 5,
          isAttack: true,
          revision: 1,
          createdAt: at,
          updatedAt: at,
        ),
        content: settingsAt(1),
      );
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows, more: [stray]), tag(1))
        ..pageList(strategyId, pageList(rows), tag(0));
      await shadow.idle;

      expect(verdicts(shadow), [
        isA<RefusedByStore>(),
        isA<Skipped>().having(
          (skipped) => skipped.reason,
          'reason',
          SkipReason.endedConnection,
        ),
      ]);
      expect((store.library as LibraryOpen).list.strategies, isEmpty);
    });

    test('a result taken after the shadow ended is not recorded', () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..end('the account changed')
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await shadow.idle;

      expect(verdicts(shadow), [isA<ComparedEqual>()]);
      expect(shadow.ended, 'the account changed');
      expect(shadow.stopped, isNull);
    });

    test('a result received offline is skipped with that reason', () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows), offline)
        ..page(strategyId, pageSnapshot(rows), offline);
      await shadow.idle;

      expect(
        verdicts(shadow),
        everyElement(
          isA<Skipped>().having(
            (skipped) => skipped.reason,
            'reason',
            SkipReason.receivedOffline,
          ),
        ),
      );
      expect((store.library as LibraryOpen).list.strategies, isEmpty);
    });

    test(
        'after a restart the strategy is found in the store and opened with '
        'the app\'s start, not added again', () async {
      final storage = MemoryStorage();
      final rows = serverRows();
      final first = await openStore(storage);
      final before = shadowOn(first)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await before.idle;
      await first.close();

      final second = await openStore(storage);
      final after = shadowOn(second)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await after.idle;

      expect(verdicts(after), allEqual);
      expect(sessionsOpened(after), ['the app started']);
    });

    test(
        'a page result whose page list never comes stays not processed, '
        'never counted as anything else', () async {
      final store = await openStore(MemoryStorage());
      final shadow = shadowOn(store)
        ..page(strategyId, pageSnapshot(serverRows()), tag(0));
      await shadow.idle;

      expect(verdicts(shadow).single, isA<NotProcessed>());
    });
  });

  group('the comparison', () {
    test(
        'a page result bringing newer settings than the page list holds is '
        'compared against what the store was given', () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows, content: settingsAt(1)), tag(0))
        ..page(
          strategyId,
          pageSnapshot(rows, content: settingsAt(2, agentSize: 55)),
          tag(0),
        )
        ..pageList(
          strategyId,
          pageList(rows, content: settingsAt(2, agentSize: 55)),
          tag(0),
        );
      await shadow.idle;

      expect(verdicts(shadow), allEqual);
    });

    test(
        'a page list that drops the open page leaves it in the store, since '
        'only a read the sender starts shows a page gone, and the comparison '
        'does not count it', () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows, more: [secondPage()]), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0))
        ..pageList(
          strategyId,
          pageList(rows, more: [secondPage()], withOpenPage: false),
          tag(0),
        );
      await shadow.idle;

      expect(verdicts(shadow), allEqual);
      expect(await store.readPage(strategyId, pageId), isA<Found<Object>>());
    });

    test(
        'an entry in the strategy that the server did not send is a '
        'difference', () async {
      final storage = MemoryStorage();
      final rows = serverRows();
      final first = await openStore(storage);
      final before = shadowOn(first)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await before.idle;
      await first.close();
      final contents = {
        for (final MapEntry(:key, :value) in storage.contents.entries)
          key: {...value},
      };
      contents[strategyArea(strategyId)]!['stray'] = '{}';

      final second = await openStore(MemoryStorage(contents));
      final after = shadowOn(second)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await after.idle;

      expect(
        after.ledger.last.verdict,
        isA<ComparedDifferent>().having(
          (different) => different.differences,
          'differences',
          contains(contains('a name this build does not know')),
        ),
      );
    });

    test(
        'the strategy row, the page list and its order are compared, and a '
        'store read back after reopening compares equal', () async {
      final storage = MemoryStorage();
      final rows = serverRows();
      final store = await openStore(storage);
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows, more: [secondPage()]), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await shadow.idle;
      await store.close();

      final reopened = await openStore(storage);
      expect(await shadow.readBack(reopened), {strategyId: isEmpty});
      expect(
        (await shadow.readBack(await openStore(MemoryStorage())))[strategyId],
        contains('the store does not hold the strategy'),
      );
    });

    test(
        'the store keeps the strategy as the work of the account the shadow '
        'serves, and a read back under another account names the difference',
        () async {
      final storage = MemoryStorage();
      final rows = serverRows();
      final store = await openStore(storage);
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows), tag(0));
      await shadow.idle;
      expect(
        store.library,
        isA<LibraryOpen>().having(
          (open) => open.list.strategies.single.sync,
          'sync',
          isA<KeptInCloud>().having(
            (sync) => sync.owner,
            'owner',
            OwnedBy(servedAccount),
          ),
        ),
      );
      await store.close();

      final reopened = await openStore(storage);
      final other = CloudShadow(
        reopened,
        build: 'b',
        canRead: appCanRead,
        breathe: none,
      )..serve(Account('account-b'));
      other.pageList(strategyId, pageList(rows), tag(0));
      await other.idle;
      expect(
        other.ledger.single.verdict,
        isA<RefusedByStore>().having(
          (refused) => refused.why,
          'why',
          contains('WorkOfAnotherAccount'),
        ),
      );
      expect(await shadow.readBack(reopened), {strategyId: isEmpty});
      await reopened.close();

      final contents = {
        for (final MapEntry(:key, :value) in storage.contents.entries)
          key: {...value},
      };
      final area = strategyArea(strategyId);
      final row = jsonDecode(contents[area]!['cloud']!) as Map<String, Object?>;
      contents[area]!['cloud'] = jsonEncode({...row, 'account': 'account-b'});
      expect(
        (await shadow
            .readBack(await openStore(MemoryStorage(contents))))[strategyId],
        contains(startsWith('account: the store holds the work for')),
      );
    });

    test('the page list order is part of the comparison', () async {
      final storage = MemoryStorage();
      final rows = serverRows();
      final store = await openStore(storage);
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows, more: [secondPage()]), tag(0));
      await shadow.idle;

      final other = await openStore(MemoryStorage());
      final reordered = shadowOn(other)
        ..pageList(strategyId, pageList(rows, more: [secondPage()]), tag(0));
      await reordered.idle;
      final page = secondPage().page;
      final moved = RemoteFullPage(
        page: RemotePage(
          publicId: page.publicId,
          strategyPublicId: strategyId,
          name: page.name,
          sortIndex: -1,
          isAttack: page.isAttack,
          revision: 2,
          createdAt: at,
          updatedAt: at,
        ),
        content: settingsAt(1),
      );
      final otherShadow = shadowOn(other)
        ..pageList(strategyId, pageList(rows, more: [moved]), tag(0));
      await otherShadow.idle;

      expect(
        (await shadow.readBack(other))[strategyId],
        contains(startsWith('page list:')),
      );
    });

    group('of rows', () {
      PageContent shownOf(StrategyRowSet rows) => PageContent(
            page: rows.page(pageId)!,
            settings: SettingsStored(rows.settingsOf(pageId)!),
            elements: rows.elementsOn(pageId),
            lineupGroups: const [],
            unknownKinds: const [],
            unplaced: const [],
            foreignNames: const [],
          );

      List<String> compare(StrategyRowSet shown, StrategyRowSet server) =>
          pageDifferences(
            shown: shownOf(shown),
            page: server.page(pageId)!,
            settings: server.settingsOf(pageId),
            elements: {
              for (final row in server.elementsOn(pageId)) row.publicId: row,
            },
            lineupGroups: const {},
          );

      test('finds nothing when the rows are the same', () {
        expect(compare(serverRows(), serverRows()), isEmpty);
      });

      test('names an item whose content differs', () {
        expect(
          compare(serverRows(), serverRows(agentAt: const Offset(1, 2))),
          [contains('item a1:')],
        );
      });

      test('names an item deleted on one side only', () {
        final empty = serverRows().withRows([
          DeletedElement(
            publicId: 'a1',
            pagePublicId: pageId,
            payload:
                (serverRows().elementsOn(pageId).single as LiveElement).payload,
            sortIndex: 0,
            revision: 2,
          ),
        ]);
        expect(compare(empty, serverRows()), [contains('item a1:')]);
      });
    });
  });

  test(
      'an unexpected throw stops the shadow with its reason, reaches '
      'nothing else, and nothing after it runs', () async {
    final store = await openStore(MemoryStorage());
    final rows = serverRows();
    final shadow = shadowOn(
      store,
      canRead: CanRead(
        element: (_) => throw StateError('a decoder broke'),
        lineupGroup: appCanRead.lineupGroup,
      ),
    )
      ..pageList(strategyId, pageList(rows), tag(0))
      ..page(strategyId, pageSnapshot(rows), tag(0))
      ..page(strategyId, pageSnapshot(rows), tag(0));
    await shadow.idle;

    expect(shadow.stopped, contains('a decoder broke'));
    expect(shadow.reports.whereType<ShadowStopped>(), hasLength(1));
    expect(verdicts(shadow), [
      isA<ComparedEqual>(),
      isA<NotProcessed>(),
      isA<NotProcessed>(),
    ]);
  });

  group('the second review', () {
    test(
        'a result read on a connection that has since dropped is skipped, '
        'not compared', () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..connectionLost()
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await shadow.idle;

      expect(
        shadow.ledger.last.verdict,
        isA<Skipped>().having(
          (skipped) => skipped.reason,
          'reason',
          SkipReason.endedConnection,
        ),
      );
      expect(shadow.reports.whereType<ShadowConnectionLost>(), hasLength(1));
    });

    test(
        'a scheduler that throws stops the shadow, and its idle still '
        'completes', () async {
      final store = await openStore(MemoryStorage());
      final shadow = shadowOn(
        store,
        breathe: () => Future<void>.error(StateError('no frames')),
      )..pageList(strategyId, pageList(serverRows()), tag(0));
      await shadow.idle;

      expect(shadow.stopped, contains('no frames'));
      expect(verdicts(shadow).single, isA<NotProcessed>());
    });

    test(
        'a job waiting on the scheduler writes nothing once the shadow has '
        'stopped', () async {
      final store = await openStore(MemoryStorage());
      final frame = Completer<void>();
      final shadow = shadowOn(store, breathe: () => frame.future)
        ..pageList(strategyId, pageList(serverRows()), tag(0));
      await pumpEventQueue();
      shadow.stop('stopped by the test');
      frame.complete();
      await shadow.idle;

      expect((store.library as LibraryOpen).list.strategies, isEmpty);
      expect(verdicts(shadow).single, isA<NotProcessed>());
    });

    test(
        'page results backed up before the first page list are replayed one '
        'scheduled job each', () async {
      final store = await openStore(MemoryStorage());
      var frames = 0;
      final rows = serverRows();
      final shadow = shadowOn(store, breathe: () async => frames++);
      for (var index = 0; index < 24; index++) {
        shadow.page(strategyId, pageSnapshot(rows), tag(0));
      }
      await shadow.idle;
      final before = frames;
      shadow.pageList(strategyId, pageList(rows), tag(0));
      await shadow.idle;

      expect(frames - before, greaterThanOrEqualTo(25));
      expect(verdicts(shadow), allEqual);
    });

    test(
        'the read back compares the contents of every page this run received '
        'content for, empty ones included', () async {
      final storage = MemoryStorage();
      final rows = serverRows();
      final store = await openStore(storage);
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows, more: [secondPage()]), tag(0))
        ..page(strategyId, emptySecondPage(), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await shadow.idle;
      await store.close();
      final contents = {
        for (final MapEntry(:key, :value) in storage.contents.entries)
          key: {...value},
      };
      contents[strategyArea(strategyId)]![
          'content/${digestOf('p2')}/z/${digestOf('stray')}'] = '{}';

      final differences = (await shadow
          .readBack(await openStore(MemoryStorage(contents))))[strategyId]!;
      expect(differences, [contains('page p2: a kind this build skips')]);
    });

    test(
        'a page this run received no content for is compared by its row and '
        'settings only, so content kept from an earlier run is no difference',
        () async {
      final storage = MemoryStorage();
      final rows = serverRows();
      final first = await openStore(storage);
      final before = shadowOn(first)
        ..pageList(strategyId, pageList(rows, more: [secondPage()]), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await before.idle;
      await first.close();

      final second = await openStore(storage);
      final after = shadowOn(second)
        ..pageList(strategyId, pageList(rows, more: [secondPage()]), tag(0))
        ..page(strategyId, emptySecondPage(), tag(0));
      await after.idle;
      await second.close();

      expect(verdicts(after), allEqual);
      expect(
        await after.readBack(await openStore(storage)),
        {strategyId: isEmpty},
      );
    });

    test(
        'with no strategy ever recorded, the read back has nothing to '
        'compare', () async {
      final shadow = shadowOn(await openStore(MemoryStorage()));
      expect(await shadow.readBack(await openStore(MemoryStorage())), isEmpty);
    });
  });

  group('with the local shadow on the same store', () {
    late Directory directory;
    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    Future<LibraryStore> withCloudStrategy() async {
      final store = await openStoreOn(MemoryEngine(MemoryStorage()));
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0));
      await shadow.idle;
      return store;
    }

    test('the local copy and its check leave the cloud strategy alone',
        () async {
      directory = await Directory.systemTemp.createTemp('icarus-cloud-shadow-');
      await openScratchHive(
        directory,
        strategies: [handBuilt().copyWith(id: 'local-1')],
      );
      final store = await withCloudStrategy();

      await copyFromHive(store);
      final check = await checkFromHive(store) as StoreChecked;

      expect(
        (store.library as LibraryOpen)
            .list
            .strategies
            .map((summary) => summary.publicId),
        unorderedEquals(['local-1', strategyId]),
      );
      expect(check.sameStrategies, 1);
      expect(check.strategyProblems, isEmpty);
    });

    test(
        'a Hive strategy whose id the store keeps in the cloud is named as '
        'such by the check, and the copy leaves the cloud rows as they are',
        () async {
      directory = await Directory.systemTemp.createTemp('icarus-cloud-shadow-');
      await openScratchHive(directory, strategies: [handBuilt()]);
      final store = await withCloudStrategy();

      final copy = await copyFromHive(store);
      final check = await checkFromHive(store) as StoreChecked;

      expect(
        copy.strategies.single,
        isA<StrategyNotMirrored>().having(
          (copy) => copy.reason,
          'reason',
          isA<StoreRefusedIt>().having(
            (refused) => refused.refusal,
            'reason',
            isA<KeptInTheCloud>(),
          ),
        ),
      );
      expect(check.strategyProblems.single, isA<StrategyKeptInCloud>());
      final shown = await store.readPage(strategyId, pageId);
      expect(
        (shown as Found<PageContent>).value.elements.single,
        serverRows().elementsOn(pageId).single,
      );
    });
  });
}
