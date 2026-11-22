import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/library_store_open.dart';
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

RemotePageList pageList(StrategyRowSet rows, {int revision = 1}) {
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
      for (final page in rows.pages)
        RemoteFullPage(
          page: remotePage(page),
          content: remoteContent(rows, page.publicId),
        ),
    ],
  );
}

RemotePageSnapshot pageSnapshot(StrategyRowSet rows) => RemotePageSnapshot(
      page: remotePage(rows.page(pageId)!),
      content: remoteContent(rows, pageId),
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

List<T> reportsOf<T>(CloudShadow shadow) =>
    shadow.reports.whereType<T>().toList();

List<CloudShadowReport> problems(CloudShadow shadow) => [
      for (final report in shadow.reports)
        if (report is ShadowDiffers ||
            report is ShadowStoreFailed ||
            report is ShadowRefused)
          report,
    ];

void main() {
  test(
      'the first page list adds the strategy, and the open page then matches '
      'the server row for row', () async {
    final store = await openStore(MemoryStorage());
    final shadow = CloudShadow(store, build: 'b', canRead: appCanRead)
      ..connection(0)
      ..account('me');
    final rows = serverRows();
    shadow
      ..pageList(strategyId, pageList(rows), stamp: 0)
      ..page(strategyId, pageSnapshot(rows), stamp: 0);
    await shadow.idle;

    expect(problems(shadow), isEmpty);
    expect(reportsOf<ShadowSessionOpened>(shadow).single.because,
        'the strategy was added');
    expect(reportsOf<ShadowEqual>(shadow), hasLength(1));
    expect(store.library, isA<LibraryOpen>());
    final listed = (store.library as LibraryOpen).list.strategies.single;
    expect(listed.sync, isNot(isA<KeptHere>()));
  });

  test('a page that arrives before the page list waits for it', () async {
    final store = await openStore(MemoryStorage());
    final shadow = CloudShadow(store, build: 'b', canRead: appCanRead)
      ..connection(0);
    final rows = serverRows();
    shadow
      ..page(strategyId, pageSnapshot(rows), stamp: 0)
      ..pageList(strategyId, pageList(rows), stamp: 0);
    await shadow.idle;

    expect(problems(shadow), isEmpty);
    expect(reportsOf<ShadowEqual>(shadow), hasLength(1));
  });

  test('a teammate\'s edit reaches the store with the next page result',
      () async {
    final store = await openStore(MemoryStorage());
    final shadow = CloudShadow(store, build: 'b', canRead: appCanRead)
      ..connection(0);
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
    shadow
      ..pageList(strategyId, pageList(before), stamp: 0)
      ..page(strategyId, pageSnapshot(before), stamp: 0)
      ..page(strategyId, pageSnapshot(after), stamp: 0);
    await shadow.idle;

    expect(problems(shadow), isEmpty);
    expect(reportsOf<ShadowEqual>(shadow), hasLength(2));
    final shown = await store.readPage(strategyId, pageId);
    final element = (shown as Found<PageContent>).value.elements.single;
    expect((element as LiveElement).revision, 2);
  });

  test(
      'a reconnect opens a new session, and an answer from the dropped '
      'connection is not recorded', () async {
    final store = await openStore(MemoryStorage());
    final shadow = CloudShadow(store, build: 'b', canRead: appCanRead)
      ..connection(0);
    final rows = serverRows();
    shadow
      ..pageList(strategyId, pageList(rows), stamp: 0)
      ..page(strategyId, pageSnapshot(rows), stamp: 0)
      ..connection(null)
      ..connection(1)
      ..page(strategyId, pageSnapshot(rows), stamp: 0)
      ..page(strategyId, pageSnapshot(rows), stamp: 1)
      ..pageList(strategyId, pageList(rows), stamp: 1);
    await shadow.idle;

    expect(problems(shadow), isEmpty);
    final sessions = reportsOf<ShadowSessionOpened>(shadow);
    expect(sessions.map((report) => report.because), [
      'the strategy was added',
      'the connection came back',
    ]);
    expect(sessions.last.session, greaterThan(sessions.first.session));
    expect(
      reportsOf<ShadowSkipped>(shadow).single.why,
      'received on a connection that ended',
    );
    expect(
      reportsOf<ShadowRecorded>(shadow).last.session,
      sessions.last.session,
    );
    expect(reportsOf<ShadowEqual>(shadow), hasLength(3));
  });

  test(
      'after a restart the strategy is found in the store and opened with '
      'the app\'s start, not added again', () async {
    final storage = MemoryStorage();
    final rows = serverRows();
    final first = await openStore(storage);
    final before = CloudShadow(first, build: 'b', canRead: appCanRead)
      ..connection(0)
      ..pageList(strategyId, pageList(rows), stamp: 0)
      ..page(strategyId, pageSnapshot(rows), stamp: 0);
    await before.idle;
    await first.close();

    final second = await openStore(storage);
    final after = CloudShadow(second, build: 'b', canRead: appCanRead)
      ..connection(0)
      ..pageList(strategyId, pageList(rows), stamp: 0)
      ..page(strategyId, pageSnapshot(rows), stamp: 0);
    await after.idle;

    expect(problems(after), isEmpty);
    expect(reportsOf<ShadowSessionOpened>(after).single.because,
        'the app started');
    expect(reportsOf<ShadowEqual>(after), isNotEmpty);
  });

  test('an account change opens a new session', () async {
    final store = await openStore(MemoryStorage());
    final rows = serverRows();
    final shadow = CloudShadow(store, build: 'b', canRead: appCanRead)
      ..connection(0)
      ..account('first')
      ..pageList(strategyId, pageList(rows), stamp: 0)
      ..account('second')
      ..page(strategyId, pageSnapshot(rows), stamp: 0);
    await shadow.idle;

    expect(problems(shadow), isEmpty);
    expect(
      reportsOf<ShadowSessionOpened>(shadow).map((report) => report.because),
      ['the strategy was added', 'the account changed'],
    );
    expect(reportsOf<ShadowEqual>(shadow), hasLength(1));
  });

  test('nothing is recorded while offline', () async {
    final store = await openStore(MemoryStorage());
    final rows = serverRows();
    final shadow = CloudShadow(store, build: 'b', canRead: appCanRead)
      ..connection(null)
      ..pageList(strategyId, pageList(rows), stamp: null)
      ..page(strategyId, pageSnapshot(rows), stamp: null);
    await shadow.idle;

    expect(reportsOf<ShadowSkipped>(shadow), hasLength(2));
    expect((store.library as LibraryOpen).list.strategies, isEmpty);
  });

  group('the comparison', () {
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
          settings: server.settingsOf(pageId)!,
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

  group('with the local shadow on the same store', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('icarus-cloud-shadow-');
      await openScratchHive(
        directory,
        strategies: [handBuilt().copyWith(id: 'local-1')],
      );
    });
    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test('the local copy and its check leave the cloud strategy alone',
        () async {
      final store = await openStoreOn(MemoryEngine(MemoryStorage()));
      final rows = serverRows();
      final shadow = CloudShadow(store, build: 'b', canRead: appCanRead)
        ..connection(0)
        ..pageList(strategyId, pageList(rows), stamp: 0)
        ..page(strategyId, pageSnapshot(rows), stamp: 0);
      await shadow.idle;

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
      final shown = await store.readPage(strategyId, pageId);
      expect(shown, isA<Found<PageContent>>());
    });
  });
}
