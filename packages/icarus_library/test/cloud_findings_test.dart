import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/store/layout.dart'
    show AttemptName, PendingName;
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

final Matcher needsUser = isA<NeedsUser>();

bool sendable(Client client, String id) => client.view(id).sendable;

LiveElement rowWith(
  String id, {
  required int revision,
  int payloadVersion = 1,
  Map<String, Object?> fields = const {},
}) => LiveElement(
  publicId: id,
  pagePublicId: 'page-a',
  payload: ElementPayload(
    kind: ElementKind.agent,
    payloadVersion: payloadVersion,
    data: {'id': id, 'elementType': 'agent', ...fields},
  ),
  sortIndex: 0,
  revision: revision,
);

StrategyRowSet withElement(StrategyRowSet rows, ElementRow row) =>
    StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: [
        for (final other in rows.elements)
          if (other.publicId != row.publicId) other,
        row,
      ],
    );

ElementAddOp putBackOf(String opId, StrategyRows rows, String id) {
  final row = rows.element(id)! as LiveElement;
  return ElementAddOp(
    opId: opId,
    elementPublicId: id,
    pagePublicId: row.pagePublicId,
    payload: row.payload,
    sortIndex: row.sortIndex,
    expectedElementRevision: row.revision + 1,
  );
}

void main() {
  group('rules review', () {
    test('1: a lost answer is expired at the 30-day boundary itself, and a '
        'clock that moves back does not make it replayable', () {
      final client = Client()..must(const ConnectionReturned());
      client.edit(elementDelete('x'));
      final attempt = client.claim(['x']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      final boundary = now.add(serverRemembersAnswersFor);
      client.clock = boundary;
      expect(sendable(client, 'x'), isFalse);
      client.must(const ConnectionLost());
      client.clock = boundary.subtract(const Duration(seconds: 1));
      expect(sendable(client, 'x'), isFalse);
    });

    test('2: a field edit against a row whose payload version changed is '
        'checked as a whole write', () {
      final client = Client();
      client.edit(
        movePatch('move', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      client.read(
        withElement(
          initialRows(),
          rowWith(
            'e1',
            revision: 2,
            payloadVersion: 2,
            fields: {'rotation': 90},
          ),
        ),
      );
      expect(client.view('move').go, needsUser);
    });

    test('3a: after a restart a revision-checked entry waits for a read made '
        'in the new session', () {
      final client = Client();
      client.edit(elementDelete('x'));
      client.must(const AppRestarted(build: build));
      expect(sendable(client, 'x'), isFalse);
      client.read(initialRows(), pages: ['page-a']);
      expect(sendable(client, 'x'), isTrue);
    });

    test('3b: a put-back whose delete was answered more than 30 days ago '
        'needs the user even when the tombstone matches', () {
      final client = Client();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      client.edit(putBackOf('back', drawn, 'e1'));
      final attempt = client.claim(['del']);
      client.must(OpAnswered(attempt, const AppliedAnswer('del', revision: 2)));
      client.clock = now.add(
        serverRemembersAnswersFor + const Duration(days: 1),
      );
      client.must(const AppRestarted(build: build));
      client.read(
        withOp(initialRows(), elementDelete('del')),
        pages: ['page-a'],
      );
      expect(client.view('back').go, needsUser);
    });

    test('3c: a put-back is not released by a read that started before the '
        'delete was answered', () {
      final client = Client();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      client.edit(putBackOf('back', drawn, 'e1'));
      final attempt = client.claim(['del']);
      final early = client.startRead();
      client.must(OpAnswered(attempt, const AppliedAnswer('del', revision: 2)));
      client.arrive(
        pageReadOf(withOp(initialRows(), elementDelete('del')), 'page-a'),
        read: early,
      );
      expect(sendable(client, 'back'), isFalse);
    });

    test('5a: a page delete whose answer was lost is settled by a read made '
        'after it that finds the page gone', () {
      final client = Client();
      client.edit(pageDelete('drop', 'page-b'));
      client.read(initialRows(), pages: ['page-b']);
      final attempt = client.claim(['drop']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.must(const AppRestarted(build: build));
      client.arrive(const PageGone('page-b'));
      expect(client.queue.entry('drop'), isNull);
    });

    test('5b: a read started before a disconnect does not satisfy the '
        'check after it', () {
      final client = Client()..must(const ConnectionReturned());
      client.edit(pageDelete('drop', 'page-b'));
      client.must(const ConnectionLost());
      final early = client.startRead();
      client.must(const ConnectionReturned());
      client.arrive(pageReadOf(initialRows(), 'page-b'), read: early);
      expect(sendable(client, 'drop'), isFalse);
    });
  });

  group('rules review, smaller findings', () {
    test('a field edit sent as a field merge does not wait for a read after a '
        'restart or reconnect, while a revision-checked one does', () {
      final client = Client();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      client.edit(elementDelete('drop', elementId: 'e2'));
      client.must(const AppRestarted(build: build));
      client.must(const ConnectionReturned());
      expect(sendable(client, 'drag'), isTrue);
      expect(sendable(client, 'drop'), isFalse);
      client.read(initialRows(), pages: ['page-a']);
      expect(sendable(client, 'drop'), isTrue);
      client.must(const ConnectionLost());
      client.must(const ConnectionReturned());
      expect(sendable(client, 'drag'), isTrue);
      expect(sendable(client, 'drop'), isFalse);
    });

    test('an applied move to another page settles only when a read shows the '
        'item on the destination page', () {
      final client = Client()..must(const ConnectionReturned());
      client.read(initialRows());
      final move = movePatch('move', pageId: 'page-b');
      client.edit(move);
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(attempt, const AppliedAnswer('move', revision: 2)),
      );
      final server = withOp(initialRows(), move);
      client.arrive(pageReadOf(server, 'page-a'));
      expect(client.queue.entry('move'), isNotNull);
      client.arrive(pageReadOf(server, 'page-b'));
      expect(client.queue.entry('move'), isNull);
    });

    test('a strategy gone from the server keeps every entry', () {
      final client = Client()..must(const ConnectionReturned());
      client.edit(movePatch('move'));
      client.arrive(const StrategyGone());
      expect(standingOf(client.queue), Standing.deletedOnServer);
      expect(client.queue.entry('move'), isNotNull);
    });

    test('an upgrade refusal for a batch an older build sent does not hold '
        'sending in the newer build', () {
      final client = Client()..must(const ConnectionReturned());
      client.read(initialRows());
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(const AppRestarted(build: 'a newer build'));
      client.must(BatchRefused(attempt, BatchRefusal.upgradeRequired));
      expect(client.effects, isNot(contains(isA<HoldSendingForUpgrade>())));
      expect(standingOf(client.queue), Standing.good);
    });

    test('confirming edit access after an attempt never made is not '
        'applicable', () {
      final client = Client();
      expect(
        client.step(const EditAccessConfirmed(afterAttempt: 7)),
        isA<NotApplicable>().having((n) => n.why, 'why', isA<NoSuchAttempt>()),
      );
    });

    test('a later accepted batch is evidence of edit access', () {
      final client = Client()..must(const ConnectionReturned());
      client.read(initialRows());
      client.edit(movePatch('first'));
      client.edit(movePatch('second', elementId: 'e2'));
      final early = client.claim(['first']);
      final late = client.claim(['second']);
      client.must(BatchRefused(early, BatchRefusal.editAccessRemoved));
      expect(standingOf(client.queue), Standing.editAccessLost);
      client.must(OpAnswered(late, const AppliedAnswer('second', revision: 2)));
      expect(standingOf(client.queue), Standing.good);
    });

    test('the queue counts cannot be changed by whoever reads them', () {
      final counts = queueCounts(Client().queue, now);
      expect(counts.waiting.clear, throwsUnsupportedError);
      expect(counts.attention.clear, throwsUnsupportedError);
    });
  });

  group('storage review', () {
    test('1: an older response arriving after a newer read does not roll '
        'the page back', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final old = await startRead(store);
      final oldResponse = pageReadOf(initialRows(), 'page-a');
      savedValue(await store.commit(strategyId, movePatch('move', x: 40)));
      final sent = await claimAll(store);
      final server = withOp(initialRows(), sent.ops.single);
      await recordAll(store, [
        OpAnswered(sent.attempt, const AppliedAnswer('move', revision: 2)),
      ]);
      await readServer(store, server, pages: ['page-a']);
      await recordAll(store, [BaseArrived(oldResponse, read: old)]);
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(elementOn(page, 'e1'), server.element('e1'));
    });

    test('2: a page read for a page whose row is not stored yet writes '
        'nothing', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final before = storage.contents;
      final added = withOp(initialRows(), pageAdd('add', 'page-c'));
      final read = await startRead(store);
      final counters = storage.contents;
      final result = await store.record(strategyId, [
        BaseArrived(pageReadOf(added, 'page-c'), read: read),
      ]);
      expect(result, isA<Saved<Recorded, CommitRefusal>>());
      expect(sameContents(storage.contents, counters), isTrue);
      expect(sameContents(before, counters), isFalse);
    });

    test('3: what a header read settles is what reaches disk', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final change = PageSettingsPatchOp(
        opId: 'size',
        pagePublicId: 'page-a',
        expectedPageSettingsRevision: 1,
        settings: const PageSettings(
          agentSize: 40,
          abilitySize: 20,
          useNeutralTeamColors: false,
        ),
      );
      savedValue(await store.commit(strategyId, change));
      final sent = await claimAll(store);
      final server = withOp(initialRows(), sent.ops.single);
      await recordAll(store, [
        OpAnswered(sent.attempt, const AppliedAnswer('size', revision: 2)),
      ]);
      await readServer(store, server, pages: const []);
      final inMemory = (await syncOf(store)).queue.base;
      await store.close();
      final reopened = await openCloudStore(MemoryEngine(storage));
      expect((await syncOf(reopened)).queue.base, inMemory);
    });

    test('6: a strategy deleted on the server keeps the edit the user '
        'made', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('move', x: 40)));
      final sent = await claimAll(store);
      await recordAll(store, [
        OpAnswered(sent.attempt, const AppliedAnswer('move', revision: 2)),
      ]);
      final read = await startRead(store);
      await recordAll(store, [BaseArrived(const StrategyGone(), read: read)]);
      final cloud = await syncOf(store);
      expect(cloud.queue.entry('move'), isNotNull);
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(
        elementOn(page, 'e1'),
        withOp(initialRows(), movePatch('move', x: 40)).element('e1'),
      );
    });

    test('4: an entry this build cannot read holds the whole queue, so its '
        'attempt is never pruned and nothing is sent', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('a')));
      savedValue(
        await store.commit(strategyId, movePatch('b', elementId: 'e2')),
      );
      final sent = await claimAll(store);
      await store.close();
      final contents = editable(storage.contents);
      final area = strategyArea(strategyId);
      final name = PendingName(1).name;
      contents[area]![name] = contents[area]![name]!.replaceFirst(
        '"version":1',
        '"version":2',
      );
      final disk = MemoryStorage(contents);
      store = await openCloudStore(MemoryEngine(disk));
      final result = await store.record(strategyId, [
        OpAnswered(sent.attempt, const AppliedAnswer('a', revision: 2)),
      ]);
      expect(result, isA<Refused<Recorded, CommitRefusal>>());
      expect(sameContents(disk.contents, contents), isTrue);
      expect(disk.contents[area]!.containsKey(AttemptName(1).name), isTrue);
    });

    test('5: a strategy holding queue rows this build cannot read is not '
        'erased by removing it as unreadable, and an op id never collides '
        'with an unreadable row', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('unreadable/5')));
      await store.close();
      final contents = editable(storage.contents);
      final area = strategyArea(strategyId);
      contents[area]!['counters'] = '{"version":2}';
      contents[area]![PendingName(5).name] = '{"version":2}';
      contents['library']!.remove(summaryName(strategyId));
      final disk = MemoryStorage(contents);
      store = await openCloudStore(MemoryEngine(disk));
      await store.findStrategies();
      await store.readStrategy(strategyId);
      final removed = await store.editLibrary([
        RemoveUnreadableStrategy(StrategyRef(area)),
      ]);
      expect(removed, isNot(isA<Saved<LibraryEdited, LibraryRefusal>>()));
      expect(disk.contents[area]!.containsKey(PendingName(0).name), isTrue);
    });

    test('A6: copying a page online and deleting the copy drains without '
        'asking the user', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await recordAll(store, [const ConnectionReturned()]);
      savedValue(
        await store.commit(
          strategyId,
          pageAdd('copy', 'page-c', copyFrom: 'page-a'),
        ),
      );
      savedValue(
        await store.commit(
          strategyId,
          pageDelete('drop', 'page-c', expected: 2),
        ),
      );
      var server = initialRows();
      for (var round = 0; round < 6; round++) {
        await readServer(store, server);
        final cloud = await syncOf(store);
        if (cloud.queue.entries.isEmpty) break;
        for (final view in cloud.views.values) {
          expect(view.go, isNot(isA<NeedsUser>()));
        }
        if (cloud.views.values.every((view) => !view.sendable)) continue;
        final sent = await claimAll(store);
        final answers = <QueueEvent>[];
        for (final op in sent.ops) {
          switch (applyOp(server, op)) {
            case final OpApplied done:
              server = server.withRows([
                for (final row in done.rows)
                  if ((op, row) case (
                    PageAddOp(copyContentFromPagePublicId: _?),
                    final LiveElement element,
                  ))
                    LiveElement(
                      publicId: 'server-${element.publicId.hashCode.abs()}',
                      pagePublicId: element.pagePublicId,
                      payload: element.payload,
                      sortIndex: element.sortIndex,
                      revision: element.revision,
                    )
                  else
                    row,
              ]);
              answers.add(
                OpAnswered(
                  sent.attempt,
                  AppliedAnswer(op.opId, revision: server.strategy.revision),
                ),
              );
            case _:
              fail('the server refused ${op.opId}');
          }
        }
        await recordAll(store, answers);
      }
      expect((await syncOf(store)).queue.entries, isEmpty);
    });
  });
}
