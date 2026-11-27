import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

const drawnAt = {'dx': 0, 'dy': 0};
const movedTo = {'dx': 50, 'dy': 0};
const editedTo = {'dx': 10, 'dy': 0};

StrategyRowSet drawnRows() => strategyRows(
  elements: [
    element('e1', fields: {'position': drawnAt}),
    element('e2'),
  ],
);

StrategyRowSet movedByTeammate() => withOp(
  drawnRows(),
  ElementPatchOp(
    opId: 't',
    elementPublicId: 'e1',
    expectedElementRevision: 1,
    payload: agentPayload('e1', {'position': movedTo}),
  ),
);

StrategyRowSet replacedByTeammate() {
  final rows = drawnRows();
  final drawn = rows.element('e1')! as LiveElement;
  return rows.withRows([
    LiveElement(
      publicId: 'e1',
      pagePublicId: 'page-a',
      payload: agentPayload('e1', {'position': movedTo}),
      sortIndex: drawn.sortIndex,
      revision: 1,
      unknownFields: jsonObject({'createdAt': fixtureLife + 5}),
    ),
  ]);
}

ElementPatchOp moveFromDrawn(String opId) => movePatch(
  opId,
  merge: FieldMerge(
    fields: const ['position'],
    base: const {'position': drawnAt},
  ),
);

Future<LibraryStore> drawnThen(StrategyRowSet server) async {
  final store = await openCloudStore(MemoryEngine(MemoryStorage()));
  await addCloud(store, drawnRows());
  await readServer(store, server, pages: ['page-a']);
  return store;
}

Future<BatchResult> commitMade(
  LibraryStore store,
  List<StrategyOp> ops,
  HowMade made,
) async => store.commitAllAs(
  testAccount,
  strategyId,
  ops,
  seen: await seenIn(store),
  made: made,
);

Future<MadeLive> madeLiveNow(LibraryStore store, {int ago = 0}) async =>
    MadeLive(await sessionOf(store) - ago);

Future<Object?> shownPosition(LibraryStore store) async {
  final page = pageOf(await store.readPage(strategyId, 'page-a'));
  final row = page.elements.firstWhere((row) => row.publicId == 'e1');
  return ((row as LiveElement).payload.data['position']! as JsonObject)
      .toJson();
}

Future<PendingOp> entryOf(LibraryStore store, String id) async =>
    (await syncOf(store)).queue.entry(id)! as PendingOp;

Future<PendingState> stateOf(LibraryStore store, String id) async =>
    (await syncOf(store)).views[id]!.state;

Future<void> holdServerTime(LibraryStore store) async => recordAll(store, [
  ServerTimeHeld(
    heldServerTime,
    at: Duration.zero,
    session: await sessionOf(store),
    point: tick(),
  ),
]);

Future<SendBatch> claimInsideTheWindow(LibraryStore store) async {
  final views = (await syncOf(store)).views;
  return effectsOf(
    await recordAll(store, [
      BatchClaimed(
        clientId: clientId,
        opIds: [
          for (final MapEntry(:key, :value) in views.entries)
            if (value.sendable) key,
        ],
        at: fixedClock(),
        elapsed: () => const Duration(seconds: 1),
      ),
    ]),
  ).whereType<SendBatch>().single;
}

Matcher mergeBase(Object? base) => isA<ElementPatchOp>().having(
  (op) => op.merge?.base?.toJson(),
  'merge base',
  base,
);

void main() {
  group('made live in the current session', () {
    test('a merge over a row a teammate moved since the draw is applied '
        'without its base check, and keeps its authored base', () async {
      final store = await drawnThen(movedByTeammate());
      final committed = savedValue(
        await commitMade(store, [
          moveFromDrawn('mine'),
        ], await madeLiveNow(store)),
      );
      expect([for (final each in committed) each.change.opId], ['mine']);
      expect(await shownPosition(store), editedTo);
      final entry = await entryOf(store, 'mine');
      expect(entry.op, mergeBase(const {'position': drawnAt}));
      expect(entry.madeAs, MadeAs.live);
      expect(await stateOf(store, 'mine'), const Waiting());
    });

    test('sent inside the window it goes live, with no base', () async {
      final store = await drawnThen(movedByTeammate());
      await holdServerTime(store);
      savedValue(
        await commitMade(store, [
          moveFromDrawn('mine'),
        ], await madeLiveNow(store)),
      );
      final sent = await claimInsideTheWindow(store);
      expect(sent.ops.single, mergeBase(null));
    });

    test('sent when the send policy decides checked, it carries its authored '
        'base for the server to judge', () async {
      final store = await drawnThen(movedByTeammate());
      savedValue(
        await commitMade(store, [
          moveFromDrawn('mine'),
        ], await madeLiveNow(store)),
      );
      final sent = await claimAll(store);
      expect(sent.ops.single, mergeBase(const {'position': drawnAt}));
    });
  });

  group('made live in a session that has since ended is made checked', () {
    test('a base the held row moved past goes to the user', () async {
      final store = await drawnThen(movedByTeammate());
      final committed = savedValue(
        await commitMade(store, [
          moveFromDrawn('mine'),
        ], await madeLiveNow(store, ago: 1)),
      );
      expect(committed, isEmpty);
      expect(
        await stateOf(store, 'mine'),
        const NeedsUser(ChangedSinceDrawn(RejectionReason.fieldConflict)),
      );
      expect((await entryOf(store, 'mine')).madeAs, MadeAs.checked);
    });

    test('a base that holds commits, and is never sent live', () async {
      final store = await drawnThen(drawnRows());
      await holdServerTime(store);
      savedValue(
        await commitMade(store, [
          moveFromDrawn('mine'),
        ], await madeLiveNow(store, ago: 1)),
      );
      expect(await shownPosition(store), editedTo);
      final sent = await claimInsideTheWindow(store);
      expect(sent.ops.single, mergeBase(const {'position': drawnAt}));
    });
  });

  group('made checked', () {
    test('a base the held row moved past is queued for the user, counted as '
        'a server\'s refusal, and the rest of the batch commits', () async {
      final store = await drawnThen(movedByTeammate());
      final committed = savedValue(
        await commitMade(store, [
          moveFromDrawn('mine'),
          movePatch(
            'other',
            elementId: 'e2',
            merge: FieldMerge(fields: const ['position']),
          ),
        ], MadeChecked()),
      );
      expect([for (final each in committed) each.change.opId], ['other']);
      expect(
        await stateOf(store, 'mine'),
        const NeedsUser(ChangedSinceDrawn(RejectionReason.fieldConflict)),
      );
      expect((await entryOf(store, 'mine')).op, moveFromDrawn('mine'));
      expect((await syncOf(store)).tally.attention, {
        Attention.rejectedByServer: 1,
      });
      expect(await stateOf(store, 'other'), const Waiting());
    });

    test('a merge whose base holds is never sent live, where an unmarked one '
        'is', () async {
      for (final (made, base) in [
        (MadeChecked(), const {'position': drawnAt}),
        (null, null),
      ]) {
        final store = await drawnThen(drawnRows());
        await holdServerTime(store);
        savedValue(
          await store.commitAllAs(
            testAccount,
            strategyId,
            [moveFromDrawn('mine')],
            seen: await seenIn(store),
            made: made,
          ),
        );
        final sent = await claimInsideTheWindow(store);
        expect(sent.ops.single, mergeBase(base), reason: '$made');
      }
    });

    test('a delete is never sent last writer wins, where an unmarked one '
        'is', () async {
      for (final (made, lastWriterWins) in [
        (MadeChecked(), false),
        (null, true),
      ]) {
        final store = await drawnThen(drawnRows());
        await holdServerTime(store);
        savedValue(
          await store.commitAllAs(
            testAccount,
            strategyId,
            [elementDelete('drop', elementId: 'e2')],
            seen: await seenIn(store),
            made: made,
          ),
        );
        final sent = await claimInsideTheWindow(store);
        expect(
          (sent.ops.single as ElementDeleteOp).lastWriterWins,
          lastWriterWins,
          reason: '$made',
        );
      }
    });

    test('the send policy says checked whatever else holds', () {
      for (final attempted in [true, false]) {
        for (final connected in [true, false]) {
          for (final writtenThisSession in [true, false]) {
            for (final elapsed in [null, Duration.zero, liveFor * 2]) {
              expect(
                sendPolicy(
                  madeChecked: true,
                  attempted: attempted,
                  connected: connected,
                  writtenThisSession: writtenThisSession,
                  basis: const ServerTimeBasis(1, heldAt: Duration.zero),
                  elapsed: elapsed,
                ),
                SendPolicy.checked,
              );
            }
          }
        }
      }
    });

    test('an edit folds only into one made the same way, and a conflict '
        'folds into nothing', () async {
      for (final (first, second, entries) in [
        (null, MadeChecked(), 2),
        (MadeChecked(), MadeChecked(), 1),
      ]) {
        final store = await drawnThen(drawnRows());
        for (final (op, made) in [
          (moveFromDrawn('one'), first),
          (
            movePatch(
              'two',
              x: 20,
              merge: FieldMerge(
                fields: const ['position'],
                base: const {'position': editedTo},
              ),
            ),
            second,
          ),
        ]) {
          savedValue(
            await store.commitAllAs(
              testAccount,
              strategyId,
              [op],
              seen: await seenIn(store),
              made: made,
            ),
          );
        }
        expect(
          (await syncOf(store)).queue.entries,
          hasLength(entries),
          reason: '$first then $second',
        );
      }
      final store = await drawnThen(movedByTeammate());
      savedValue(
        await commitMade(store, [
          movePatch(
            'one',
            expected: 2,
            merge: FieldMerge(fields: ['position']),
          ),
        ], MadeChecked()),
      );
      savedValue(
        await commitMade(store, [
          movePatch(
            'two',
            x: 30,
            merge: FieldMerge(
              fields: const ['position'],
              base: const {'position': drawnAt},
            ),
          ),
        ], MadeChecked()),
      );
      expect((await syncOf(store)).queue.entries, hasLength(2));
      expect(
        await stateOf(store, 'two'),
        const NeedsUser(ChangedSinceDrawn(RejectionReason.fieldConflict)),
      );
    });
  });

  group('a row replaced since the draw', () {
    for (final (name, made) in [
      ('made live', (int session) => MadeLive(session, drawnLives: drawn)),
      ('made checked', (int _) => MadeChecked(drawnLives: drawn)),
    ]) {
      test('$name, the edit goes to the user and is not applied over the new '
          'row', () async {
        final store = await drawnThen(replacedByTeammate());
        final committed = savedValue(
          await commitMade(store, [
            movePatch('mine', merge: FieldMerge(fields: const ['position'])),
          ], made(await sessionOf(store))),
        );
        expect(committed, isEmpty);
        expect(
          await stateOf(store, 'mine'),
          const NeedsUser(ChangedSinceDrawn(RejectionReason.rowReplaced)),
        );
        expect(await shownPosition(store), movedTo);
      });
    }

    test('a life that matches the held row commits as drawn', () async {
      final store = await drawnThen(drawnRows());
      savedValue(
        await commitMade(store, [
          moveFromDrawn('mine'),
        ], MadeChecked(drawnLives: drawn)),
      );
      expect(await shownPosition(store), editedTo);
    });
  });

  group('the page between such a commit and the user\'s answer', () {
    test('shows the held value, even once the held row is back at the '
        'drawn base', () async {
      final store = await drawnThen(movedByTeammate());
      savedValue(
        await commitMade(store, [moveFromDrawn('mine')], MadeChecked()),
      );
      expect(await shownPosition(store), movedTo);
      await readServer(
        store,
        withOp(
          movedByTeammate(),
          ElementPatchOp(
            opId: 't2',
            elementPublicId: 'e1',
            expectedElementRevision: 2,
            payload: agentPayload('e1', {'position': drawnAt}),
          ),
        ),
        pages: ['page-a'],
      );
      expect(await shownPosition(store), drawnAt);
    });

    test('keeps the edit in the queue until the user answers', () async {
      final store = await drawnThen(movedByTeammate());
      savedValue(
        await commitMade(store, [moveFromDrawn('mine')], MadeChecked()),
      );
      await recordAll(store, [const UserDiscarded('mine')]);
      expect((await syncOf(store)).queue.entries, isEmpty);
      expect(await shownPosition(store), movedTo);
    });
  });

  group('the stored queue', () {
    PendingOp entryWith({
      MadeAs madeAs = MadeAs.unmarked,
      RefusalRecord refusal = const NotRefused(),
    }) => PendingOp(
      place: 3,
      work: OpWork(moveFromDrawn('mine')),
      scope: const OnPage('page-a'),
      authored: const AuthoredRow(revision: 1, life: fixtureLife, digest: 'd'),
      authoredIn: 2,
      authoredAt: DateTime.utc(2026, 11, 27),
      refusal: refusal,
      retriedAfter: 0,
      madeAs: madeAs,
    );

    PendingOp decoded(Object? json) =>
        switch (decodeEntry(3, json, sendable: true)) {
          Read(value: final PendingOp entry) => entry,
          final other => fail('$other'),
        };

    test('round-trips how an entry was made and a conflict at commit', () {
      for (final entry in [
        entryWith(madeAs: MadeAs.live),
        entryWith(madeAs: MadeAs.checked),
        entryWith(
          madeAs: MadeAs.checked,
          refusal: const ConflictedAtCommit(RejectionReason.fieldConflict),
        ),
        entryWith(
          madeAs: MadeAs.live,
          refusal: const ConflictedAtCommit(RejectionReason.rowReplaced),
        ),
      ]) {
        expect(decoded(entryToJson(entry)), entry);
      }
    });

    test('an entry with neither writes the record as before', () {
      expect(entryToJson(entryWith()), writtenBefore);
    });

    test('a record written before reads as unmarked and may still go '
        'live', () {
      final read = decoded(writtenBefore);
      expect(read, entryWith());
      expect(
        sendPolicy(
          madeChecked: read.madeAs == MadeAs.checked,
          attempted: false,
          connected: true,
          writtenThisSession: true,
          basis: const ServerTimeBasis(1, heldAt: Duration.zero),
          elapsed: Duration.zero,
        ),
        SendPolicy.live,
      );
    });

    test('a record refused by the server written before reads as it '
        'did', () {
      final read = decoded({
        ...writtenBefore,
        'refusal': {'rejected': 'field_conflict'},
      });
      expect(
        read.refusal,
        const RefusedWith(
          RejectedByServer(RejectionReason.fieldConflict, NoServerCopy()),
        ),
      );
    });

    test('an unknown way of making or conflict is unreadable', () {
      for (final json in [
        {...writtenBefore, 'madeAs': 'sideways'},
        {
          ...writtenBefore,
          'refusal': {'atCommit': 'NOT_A_REASON'},
        },
      ]) {
        expect(
          decodeEntry(3, json, sendable: true),
          isA<CouldNotRead<QueueEntry>>(),
        );
      }
    });
  });
}

final drawn = {const ElementKey('e1'): fixtureLife};

const writtenBefore = {
  'version': 1,
  'kind': 'op',
  'op': {
    'opId': 'mine',
    'type': 'element.patch',
    'elementPublicId': 'e1',
    'payload': {
      'kind': 'agent',
      'payloadVersion': 1,
      'data': {
        'id': 'e1',
        'elementType': 'agent',
        'position': {'dx': 10.0, 'dy': 0},
      },
    },
    'expectedElementRevision': 1,
    'merge': {
      'fields': ['position'],
      'base': [
        {'field': 'position', 'value': drawnAt},
      ],
    },
  },
  'scope': {'page': 'page-a'},
  'authored': {'revision': 1, 'life': fixtureLife, 'digest': 'd'},
  'authoredIn': 2,
  'authoredAt': 1795737600000,
  'retriedAfter': 0,
  'work': 'op',
  'refusal': null,
};
