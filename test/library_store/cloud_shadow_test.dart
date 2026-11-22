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

ResultTag tag(int connection, [int account = 0]) =>
    (connection: connection, account: account);

const offline = (connection: null, account: 0);

Future<void> none() async {}

CloudShadow shadowOn(LibraryStore store, {CanRead? canRead}) => CloudShadow(
      store,
      build: 'b',
      canRead: canRead ?? appCanRead,
      breathe: none,
    );

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
        'reason, and so is one read under an earlier account', () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(1))
        ..page(strategyId, pageSnapshot(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(1, 1))
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
        isA<Skipped>().having(
          (skipped) => skipped.reason,
          'reason',
          SkipReason.earlierAccount,
        ),
      ]);
      expect(sessionsOpened(shadow), [
        'the strategy was added',
        'the connection came back',
        'the account changed',
      ]);
    });

    test(
        'signing out and in as another account with the strategy open opens '
        'a new session on the same connection', () async {
      final store = await openStore(MemoryStorage());
      final rows = serverRows();
      final shadow = shadowOn(store)
        ..pageList(strategyId, pageList(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0))
        ..page(strategyId, pageSnapshot(rows), tag(0, 2));
      await shadow.idle;

      expect(verdicts(shadow), allEqual);
      expect(
        sessionsOpened(shadow).last,
        'the account changed',
      );
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
        'a strategy closed with page results still waiting for its page list '
        'skips them with that reason', () async {
      final store = await openStore(MemoryStorage());
      final shadow = shadowOn(store)
        ..page(strategyId, pageSnapshot(serverRows()), tag(0))
        ..strategyClosed();
      await shadow.idle;

      expect(
        verdicts(shadow).single,
        isA<Skipped>().having(
          (skipped) => skipped.reason,
          'reason',
          SkipReason.strategyClosed,
        ),
      );
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
        'a page list that drops the open page is compared as the page being '
        'gone', () async {
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
      expect(await store.readPage(strategyId, pageId), isA<NotFound<Object>>());
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
      expect(await shadow.differencesIn(reopened), isEmpty);
      expect(
        await shadow.differencesIn(await openStore(MemoryStorage())),
        contains('the store does not hold the strategy'),
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
        await shadow.differencesIn(other),
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
