import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

String area = strategyArea(strategyId);

const newerShape = '{"version":99}';

String newerShapeOf(String group) =>
    group == header ? newerShape : '{"page":"page-a","version":99}';

const header = 'read/header';

String pageGroup(String page) => 'read/page/${digestOf(page)}';

Future<Contents> storedAfter(
  Future<void> Function(LibraryStore store) work, {
  StrategyRowSet? rows,
}) async {
  final storage = MemoryStorage();
  final store = await openCloudStore(MemoryEngine(storage));
  await addCloud(store, rows ?? initialRows());
  await recordAll(store, [const AppRestarted(build: build)]);
  await work(store);
  await store.close();
  return editable(storage.contents);
}

Contents damaged(Contents contents, String group) {
  final edited = editable(contents);
  expect(edited[area], contains(group));
  edited[area]![group] = newerShapeOf(group);
  return edited;
}

Map<String, String> besideResults(Contents contents) => {
  for (final MapEntry(:key, :value) in contents[area]!.entries)
    if (!key.startsWith('read/')) key: value,
};

Map<String, String> resultsOf(Contents contents) => {
  for (final MapEntry(:key, :value) in contents[area]!.entries)
    if (key.startsWith('read/')) key: value,
};

typedef Opened = ({
  LibraryStore store,
  MemoryStorage disk,
  CloudStrategy cloud,
});

Future<Opened> opened(Contents contents) async {
  final disk = MemoryStorage(contents);
  final store = await openCloudStore(MemoryEngine(disk));
  final cloud = await syncOf(store);
  return (store: store, disk: disk, cloud: cloud);
}

Future<void> commit(LibraryStore store, StrategyOp op) async => savedValue(
  await store.commitAs(testAccount, strategyId, op, seen: await seenIn(store)),
);

Future<int> answer(LibraryStore store, String opId, int revision) async {
  final sent = await claimAll(store);
  await recordAll(store, [
    OpAnswered(
      sent.attempt,
      AppliedAnswer(opId, revision: revision, life: fixtureLife),
      point: tick(),
    ),
  ]);
  return sent.attempt;
}

Future<Object?> drawnXOf(LibraryStore store) async {
  final row = elementOn(
    pageOf(await store.readPage(strategyId, 'page-a')),
    'e1',
  );
  final payload = (row as LiveElement).payload.data.toJson();
  return (payload['position']! as Map)['dx'];
}

bool sendable(CloudStrategy cloud, String opId) =>
    cloud.views[opId]?.sendable ?? false;

void main() {
  for (final (label, damagedGroup) in [
    ('the page list', header),
    ('a page', pageGroup('page-a')),
  ]) {
    group('stored results of $label in a shape this build cannot read', () {
      late Contents stored;

      setUp(() async {
        stored = await storedAfter((store) async {
          await commit(store, movePatch('sent', x: 40));
          await answer(store, 'sent', 2);
          await commit(store, movePatch('waiting', elementId: 'e3', x: 50));
        });
      });

      test('are dropped: the strategy loads with its queue, and its base '
          'rows, entries, attempts and landed work are byte for byte as they '
          'were', () async {
        final contents = damaged(stored, damagedGroup);
        final (:store, :disk, :cloud) = await opened(contents);
        expect(cloud.queue.entries.map((entry) => entry.id), ['waiting']);
        expect(cloud.queue.landed.single.op.opId, 'sent');
        expect(besideResults(disk.contents), besideResults(contents));
        expect(
          resultsOf(disk.contents).values,
          isNot(contains(newerShapeOf(damagedGroup))),
        );
        expect(store.resultsDropped, [
          StoredResultsDropped(
            strategyPublicId: strategyId,
            group: damagedGroup,
            problem:
                'shown results: a shown results version this build '
                'does not read',
          ),
        ]);
        await store.close();
      });

      test('restart from the stored rows with nothing read this session, the '
          'page list and the pages with pending work owed, and the rows-agree '
          'check runs against what was rebuilt and passes', () async {
        final (:store, disk: _, :cloud) = await opened(
          damaged(stored, damagedGroup),
        );
        final shown = cloud.queue.shown;
        expect(shown.list, const ReadOwed(since: ResultAtOrAfter.anyResult));
        for (final read in shown.pageReads.values) {
          expect(read, const ReadOwed(since: ResultAtOrAfter.anyResult));
        }
        expect(shown.listSeen, isNull);
        expect(shown.pagesSeen, isEmpty);
        expect(shown.marks.isEmpty, isTrue);
        expect(shown.listTaken, isNull);
        expect(shown.pagesTaken, isEmpty);
        final rows = initialRows();
        expect(shown.highest, {
          const StrategyTarget(): versionOfRow(rows.strategy),
          for (final page in rows.pages)
            PageTarget(page.publicId): versionOfRow(page),
          for (final row in rows.settings)
            SettingsTarget(row.pagePublicId): versionOfRow(row),
          for (final row in rows.elements)
            ElementTarget(row.publicId): versionOfRow(row),
        });
        expect(await refusedFor(store), isNull);
        await store.close();
      });

      test('is reported once: a second load finds the results it wrote and '
          'drops nothing', () async {
        final first = await opened(damaged(stored, damagedGroup));
        await first.store.close();
        final written = editable(first.disk.contents);
        final second = await opened(written);
        expect(second.store.resultsDropped, isEmpty);
        expect(second.disk.contents, written);
        await second.store.close();
      });

      test('pending work is sent once fresh results are read', () async {
        final (:store, disk: _, cloud: _) = await opened(
          damaged(stored, damagedGroup),
        );
        await recordAll(store, [const AppRestarted(build: build)]);
        await readServer(
          store,
          withOp(initialRows(), movePatch('sent', x: 40)),
        );
        final cloud = await syncOf(store);
        expect(cloud.queue.landed, isEmpty);
        expect(sendable(cloud, 'waiting'), isTrue);
        final sent = await claimAll(store);
        expect(sent.ops.map((op) => op.opId), ['waiting']);
        await store.close();
      });

      test('removing the strategy afterwards leaves nothing of it', () async {
        final quiet = await storedAfter((store) async {});
        final (:store, :disk, cloud: _) = await opened(
          damaged(quiet, damagedGroup),
        );
        expect(store.resultsDropped, hasLength(1));
        savedValue(await store.editLibrary([const RemoveStrategy(strategyId)]));
        expect(disk.contents[area] ?? const {}, isEmpty);
        await store.close();
      });
    });
  }

  test('a queue entry this build cannot read still holds the strategy, and '
      'stored results it cannot read beside it are left as they are', () async {
    final stored = await storedAfter(
      (store) => commit(store, movePatch('good')),
    );
    final contents = damaged(stored, header);
    contents[area]!['pending/${'7'.padLeft(16, '0')}'] = newerShape;
    final disk = MemoryStorage(contents);
    final store = await openCloudStore(MemoryEngine(disk));
    expect(
      strategyOf(await store.readStrategy(strategyId)).sync,
      isA<CloudHeld>().having(
        (held) => held.rows.map((row) => row.ref.name).toSet(),
        'rows',
        {header, 'pending/${'7'.padLeft(16, '0')}'},
      ),
    );
    expect(store.resultsDropped, isEmpty);
    expect(disk.contents, contents);
    await store.close();
  });

  test('a strategy whose stored rows disagree is still refused, and its '
      'stored results are not dropped', () async {
    final stored = await storedAfter((store) async {});
    final contents = damaged(stored, header);
    final row = contents[area]!.keys.firstWhere((key) => key.contains('/e/'));
    contents[area]![row] = '{"broken":true}';
    final disk = MemoryStorage(contents);
    final store = await openCloudStore(MemoryEngine(disk));
    await store.readPage(strategyId, 'page-a');
    expect(await refusedFor(store), isNotNull);
    expect(store.resultsDropped, isEmpty);
    expect(disk.contents, contents);
    await store.close();
  });

  group('what the stored results held is safe to drop:', () {
    test('a ROW_REPLACED debt is paid by any result of a later session, and '
        'a read labelled with the ended session is refused', () async {
      late int ended;
      late ResultPoint inFlight;
      final stored = await storedAfter((store) async {
        await commit(store, movePatch('move'));
        final sent = await claimAll(store);
        ended = await sessionOf(store);
        inFlight = tick();
        await recordAll(store, [
          OpAnswered(
            sent.attempt,
            const RejectedAnswer(
              'move',
              RejectionReason.rowReplaced,
              NoServerCopy(),
            ),
            point: tick(),
          ),
        ]);
        expect(
          isDebt((await syncOf(store)).queue.shown.pageRead('page-a')),
          isTrue,
        );
      });
      for (final contents in [stored, damaged(stored, header)]) {
        final (:store, disk: _, cloud: _) = await opened(contents);
        await recordAll(store, [const AppRestarted(build: build)]);
        final late = await recordAll(store, [
          arrivedAs(
            pageReadOf(initialRows(), 'page-a'),
            session: ended,
            asked: inFlight,
          ),
        ]);
        expect(
          late.outcomes.single,
          isA<ReportNotApplicable>().having(
            (outcome) => outcome.why,
            'why',
            isA<FromAnEndedSession>(),
          ),
        );
        await recordAll(store, [
          await arrivalIn(store, pageReadOf(initialRows(), 'page-a')),
        ]);
        final shown = (await syncOf(store)).queue.shown;
        expect(shown.pageRead('page-a'), const ReadThisSession());
        await store.close();
      }
    });

    test(
      'work a ROW_REPLACED debt held on its page stays held after the '
      'results are dropped until its page is read again, then goes out '
      'checked, at its revision and naming the lives it was written over',
      () async {
        final stored = await storedAfter((store) async {
          await commit(store, movePatch('move'));
          final sent = await claimAll(store);
          await commit(store, movePatch('other', elementId: 'e2'));
          await recordAll(store, [
            OpAnswered(
              sent.attempt,
              const RejectedAnswer(
                'move',
                RejectionReason.rowReplaced,
                NoServerCopy(),
              ),
              point: tick(),
            ),
          ]);
          expect(
            (await syncOf(store)).views['other']!.holds,
            contains(const AwaitingResult(PageResult('page-a'))),
          );
        });
        final (:store, disk: _, cloud: _) = await opened(
          damaged(stored, header),
        );
        await recordAll(store, [
          const AppRestarted(build: build),
          reconnected(),
        ]);
        expect(sendable(await syncOf(store), 'other'), isFalse);
        await recordAll(store, [
          await arrivalIn(store, headerReadOf(initialRows())),
          await arrivalIn(store, pageReadOf(initialRows(), 'page-a')),
        ]);
        expect(sendable(await syncOf(store), 'other'), isTrue);
        final batch = await claimAll(store);
        expect(batch.ops.map((op) => op.opId), ['other']);
        expect(batch.basis, isNull);
        expect(
          batch.ops.single,
          isA<ElementPatchOp>().having(
            (op) => op.expectedElementRevision,
            'expected',
            1,
          ),
        );
        expect(batch.lives, {'other': fixtureLife});
        expect(batch.strategyLife, isNotNull);
        await store.close();
      },
    );

    test('a STRATEGY_REPLACED debt naming a life is paid by the first list '
        'of a later session, which shows that life', () async {
      const named = fixtureLife + 86400000;
      final stored = await storedAfter((store) async {
        await commit(store, movePatch('move'));
        final sent = await claimAll(store);
        await recordAll(store, [
          BatchRefused(
            sent.attempt,
            BatchRefusal.strategyReplaced,
            currentLife: named,
            point: tick(),
          ),
        ]);
        expect(namedLifeOf((await syncOf(store)).queue.shown.list), named);
      });
      final rows = initialRows();
      final server = StrategyRowSet(
        strategy: strategyRow(
          createdAt: DateTime.fromMillisecondsSinceEpoch(named, isUtc: true),
        ),
        pages: rows.pages,
        settings: rows.settings,
        elements: rows.elements,
        lineupGroups: rows.lineupGroups,
      );
      final lists = <Shown>[];
      for (final contents in [stored, damaged(stored, header)]) {
        final (:store, disk: _, cloud: _) = await opened(contents);
        await recordAll(store, [const AppRestarted(build: build)]);
        await recordAll(store, [await arrivalIn(store, headerReadOf(server))]);
        lists.add((await syncOf(store)).queue.shown);
        await store.close();
      }
      for (final shown in lists) {
        expect(shown.list, const ReadThisSession());
        expect(shown.strategy?.life, named);
      }
    });

    test('a held page delete waits for a current page list and page result, '
        'and sends nothing until both are read', () async {
      final stored = await storedAfter((store) async {
        await commit(store, movePatch('move', x: 40));
        await answer(store, 'move', 2);
        await commit(store, pageDelete('delete', 'page-a'));
      });
      final (:store, disk: _, :cloud) = await opened(damaged(stored, header));
      await recordAll(store, [const AppRestarted(build: build)]);
      var queue = await syncOf(store);
      expect(sendable(queue, 'delete'), isFalse);
      expect(queue.views['delete']!.holds, anyElement(isA<AwaitingResult>()));
      expect(cloud.queue.entries.single.id, 'delete');
      final server = withOp(initialRows(), movePatch('move', x: 40));
      await readServer(store, server);
      queue = await syncOf(store);
      expect(sendable(queue, 'delete'), isTrue);
      await store.close();
    });

    test('a whole-row edit behind our own work waits for a row justified '
        'this session', () async {
      final rename = PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-a',
        expectedPageRevision: 1,
        name: 'First',
      );
      final again = PagePatchOp(
        opId: 'again',
        pagePublicId: 'page-a',
        expectedPageRevision: 2,
        name: 'Second',
      );
      final stored = await storedAfter((store) async {
        await commit(store, rename);
        await answer(store, 'rename', 2);
        await commit(store, again);
        expect(
          (await syncOf(store)).queue.entries.single,
          isA<PendingOp>().having(
            (entry) => entry.behindOwn,
            'behindOwn',
            true,
          ),
        );
      });
      final (:store, disk: _, cloud: _) = await opened(damaged(stored, header));
      await recordAll(store, [const AppRestarted(build: build)]);
      var queue = await syncOf(store);
      expect(sendable(queue, 'again'), isFalse);
      await readServer(store, withOp(initialRows(), rename));
      queue = await syncOf(store);
      expect(sendable(queue, 'again'), isTrue);
      expect(
        (await claimAll(store)).ops.single,
        isA<PagePatchOp>().having(
          (op) => op.expectedPageRevision,
          'expected',
          2,
        ),
      );
      await store.close();
    });

    test('landed work stays drawn until a fresh read shows it', () async {
      final stored = await storedAfter((store) async {
        await commit(store, movePatch('move', x: 40));
        await answer(store, 'move', 2);
      });
      final (:store, disk: _, :cloud) = await opened(damaged(stored, header));
      expect(cloud.queue.landed.single.op.opId, 'move');
      expect(await drawnXOf(store), 40);
      await recordAll(store, [const AppRestarted(build: build)]);
      await readServer(store, withOp(initialRows(), movePatch('move', x: 40)));
      expect((await syncOf(store)).queue.landed, isEmpty);
      expect(await drawnXOf(store), 40);
      await store.close();
    });

    Future<void> keptThroughTheLoad(Contents stored) async {
      final before = await opened(stored);
      final facts = before.cloud.queue.strategy;
      final entries = before.cloud.queue.entries;
      await before.store.close();
      final after = await opened(damaged(stored, header));
      expect(after.store.resultsDropped, hasLength(1));
      expect(after.cloud.queue.strategy, facts);
      expect(after.cloud.queue.entries, entries);
      expect(besideResults(after.disk.contents), besideResults(stored));
      await after.store.close();
    }

    test('lost edit access and an upgrade asked for live in the strategy '
        'facts, which the load leaves as they were', () async {
      final stored = await storedAfter((store) async {
        await commit(store, movePatch('one'));
        final first = await claimAll(store);
        await recordAll(store, [
          BatchRefused(
            first.attempt,
            BatchRefusal.upgradeRequired,
            point: tick(),
          ),
          const AppRestarted(build: 'build-2'),
        ]);
        final second = await claimAll(store);
        await recordAll(store, [
          BatchRefused(
            second.attempt,
            BatchRefusal.editAccessRemoved,
            point: tick(),
          ),
        ]);
        final facts = (await syncOf(store)).queue.strategy;
        expect(facts.accessLostAt, greaterThan(0));
        expect(facts.upgradeTold, isA<UpgradeToldTo>());
      });
      await keptThroughTheLoad(stored);
    });

    test('work set aside after a replacement lives in the strategy facts, '
        'which the load leaves as they were', () async {
      const later = fixtureLife + 86400000;
      final rows = initialRows();
      final replaced = StrategyRowSet(
        strategy: strategyRow(
          createdAt: DateTime.fromMillisecondsSinceEpoch(later, isUtc: true),
        ),
        pages: rows.pages,
        settings: rows.settings,
        elements: rows.elements,
        lineupGroups: rows.lineupGroups,
      );
      final stored = await storedAfter((store) async {
        await commit(store, movePatch('move'));
        final sent = await claimAll(store);
        await recordAll(store, [
          BatchRefused(
            sent.attempt,
            BatchRefusal.strategyReplaced,
            currentLife: later,
            point: tick(),
          ),
        ]);
        await recordAll(store, [
          await arrivalIn(store, headerReadOf(replaced)),
        ]);
        expect((await syncOf(store)).queue.strategy.setAside, isA<SetAside>());
      });
      await keptThroughTheLoad(stored);
    });

    test('a row the server refused lives in its entry, which the load leaves '
        'as it was', () async {
      final stored = await storedAfter((store) async {
        await commit(store, movePatch('move'));
        final sent = await claimAll(store);
        await recordAll(store, [
          OpAnswered(
            sent.attempt,
            const RejectedAnswer(
              'move',
              RejectionReason.rowReplaced,
              NoServerCopy(),
            ),
            point: tick(),
          ),
        ]);
        expect(
          (await syncOf(store)).queue.entries.single,
          isA<PendingOp>().having(
            (entry) => entry.refusal,
            'refusal',
            isNot(isA<NotRefused>()),
          ),
        );
      });
      await keptThroughTheLoad(stored);
    });
  });

  test('a refusal debt stored with a request step, as earlier builds wrote '
      'it, is unreadable: the results are dropped and rebuilt, reported '
      'once, and the work waiting on the page holds until fresh reads, then '
      'goes', () async {
    final stored = await storedAfter((store) async {
      await commit(store, movePatch('move'));
      final sent = await claimAll(store);
      await commit(store, movePatch('other', elementId: 'e2'));
      await recordAll(store, [
        OpAnswered(
          sent.attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
          point: tick(),
        ),
      ]);
    });
    final group = pageGroup('page-a');
    final contents = editable(stored);
    final current = contents[area]![group]!;
    expect(current, contains('"visibleAt":true'));
    contents[area]![group] = current.replaceFirst(
      '"visibleAt":true',
      '"step":4',
    );
    final first = await opened(contents);
    expect(first.store.resultsDropped, [
      isA<StoredResultsDropped>()
          .having((dropped) => dropped.strategyPublicId, 'strategy', strategyId)
          .having((dropped) => dropped.group, 'group', group),
    ]);
    expect(
      resultsOf(first.disk.contents).values.join(),
      isNot(contains('"step"')),
    );
    expect(sendable(first.cloud, 'other'), isFalse);
    await first.store.close();
    final written = editable(first.disk.contents);
    final (:store, :disk, :cloud) = await opened(written);
    expect(store.resultsDropped, isEmpty);
    expect(disk.contents, written);
    expect(sendable(cloud, 'other'), isFalse);
    await recordAll(store, [const AppRestarted(build: build)]);
    expect(sendable(await syncOf(store), 'other'), isFalse);
    await recordAll(store, [
      await arrivalIn(store, headerReadOf(initialRows())),
    ]);
    expect(sendable(await syncOf(store), 'other'), isFalse);
    await recordAll(store, [
      await arrivalIn(store, pageReadOf(initialRows(), 'page-a')),
    ]);
    expect(sendable(await syncOf(store), 'other'), isTrue);
    final sent = await claimAll(store);
    expect(sent.ops.map((op) => op.opId), ['other']);
    await store.close();
  });
}
