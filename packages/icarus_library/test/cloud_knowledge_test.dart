import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';
import 'support.dart';

const monthLater = Duration(days: 31);

Client online({StrategyRowSet? base}) =>
    Client(base: base)..must(const ConnectionReturned());

StrategyRowSet withElements(List<ElementRow> elements) =>
    strategyRows(elements: elements);

StrategyRowSet replacedLife({String pageId = 'page-a'}) => withElements([
  element('e1', pageId: pageId, fields: const {'rotation': 135}),
  element('e2'),
  element('e3', pageId: 'page-b'),
]);

void sendAndAnswer(Client client, Server server, List<String> ids) {
  final attempt = client.claim(ids);
  for (final op in client.lastSent()) {
    client.must(OpAnswered(attempt, server.apply(clientId, op)));
  }
}

List<SendBatch> sentSince(Client client, int from) =>
    client.effects.skip(from).whereType<SendBatch>().toList();

void main() {
  group('knowledge lapses at 29 days', () {
    test('a strategy read in full is known from that read; at 29 days less '
        'a millisecond nothing waits, and at 29 days every op waits for the '
        'page list', () {
      final client = online();
      expect(client.queue.strategy.knowledge, KnownSince(now));
      client.edit(movePatch('move', x: 40));
      final justBefore = now.add(
        trustRowsFor - const Duration(milliseconds: 1),
      );
      expect(entryViews(client.queue, justBefore)['move']!.holds, isEmpty);
      expect(entryViews(client.queue, now.add(trustRowsFor))['move']!.holds, [
        const AwaitingResult(PageListResult()),
      ]);
    });

    test('a clock that reads earlier than the start of the interval lapses '
        'it, since how long it has been is not known', () {
      final client = online();
      client.edit(movePatch('move', x: 40));
      final earlier = now.subtract(const Duration(seconds: 1));
      expect(entryViews(client.queue, earlier)['move']!.holds, [
        const AwaitingResult(PageListResult()),
      ]);
    });

    test('the start of the interval is stored and outlives restarts and '
        'reconnects, which a session-held start did not', () {
      final client = online();
      client
        ..clock = now.add(const Duration(days: 10))
        ..must(const AppRestarted(build: build))
        ..must(const ConnectionReturned())
        ..clock = now.add(const Duration(days: 20))
        ..must(const ConnectionLost())
        ..must(const ConnectionReturned());
      client.read(initialRows(), pages: ['page-a']);
      expect(client.queue.strategy.knowledge, KnownSince(now));
      final facts = factsFromText(
        jsonEncode(factsToJson(testAccount, client.queue.strategy)),
      );
      expect(
        facts,
        isA<CloudRowRead<CloudFacts>>().having(
          (read) => read.value.facts.knowledge,
          'knowledge',
          KnownSince(now),
        ),
      );
      client
        ..clock = now.add(trustRowsFor)
        ..edit(movePatch('move', x: 40));
      expect(client.view('move').holds, [
        const AwaitingResult(PageListResult()),
      ]);
    });

    test('cloud facts stored without a start read as lapsed: one complete '
        'read before anything is sent', () {
      final client = online();
      final stored = {...factsToJson(testAccount, client.queue.strategy)}
        ..remove('knownSince');
      expect(
        factsFromText(jsonEncode(stored)),
        isA<CloudRowRead<CloudFacts>>().having(
          (read) => read.value.facts.knowledge,
          'knowledge',
          const KnowledgeExpired(),
        ),
      );
    });
  });

  group('while lapsed nothing is sent; the complete read is the one exit', () {
    test('the ops wait for the page list, then each page in turn; a read of '
        'every page opens a new interval from the first of them', () {
      final client = online();
      client.clock = now.add(monthLater);
      client.edit(movePatch('move', x: 40));
      expect(
        notApplicable(
          client.step(
            BatchClaimed(clientId: clientId, opIds: ['move'], at: client.at),
          ),
        ),
        isA<HeldBack>(),
      );
      client.arrive(headerReadOf(initialRows()));
      expect(client.view('move').holds, [
        const AwaitingResult(PageResult('page-a')),
      ]);
      final readFrom = client.at;
      client.clock = client.at.add(const Duration(seconds: 2));
      client.arrive(pageReadOf(initialRows(), 'page-a'));
      expect(client.view('move').holds, [
        const AwaitingResult(PageResult('page-b')),
      ]);
      client.clock = client.at.add(const Duration(seconds: 2));
      client.arrive(pageReadOf(initialRows(), 'page-b'));
      expect(client.queue.strategy.knowledge, KnownSince(readFrom));
      expect(client.view('move').sendable, isTrue);
    });

    test('Sol #1: an edit of a copy drawn from an earlier life of its row is '
        'asked, never sent over the replacement: whole write, field merge or '
        'delete', () {
      for (final op in <StrategyOp>[
        movePatch('write', x: 40),
        movePatch(
          'write',
          x: 40,
          merge: FieldMerge(fields: const ['position']),
        ),
        elementDelete('write'),
      ]) {
        final client = online();
        client.clock = now.add(monthLater);
        final from = client.effects.length;
        client.edit(op);
        client.read(replacedLife());
        expect(
          client.view('write').state,
          const NeedsUser(ChangedUnseen()),
          reason: '$op',
        );
        expect(sentSince(client, from), isEmpty);
      }
    });

    test('Sol #2: once the new life is read, this device\'s acknowledged edit '
        'of it stays drawn: the earlier life\'s higher revision is gone', () {
      final server = Server()
        ..rows = withElements([
          element('e1', fields: const {'rotation': 135}),
          element('e2'),
          element('e3', pageId: 'page-b'),
        ]);
      final client = online(
        base: withElements([
          element('e1', revision: 2),
          element('e2'),
          element('e3', pageId: 'page-b'),
        ]),
      );
      client.clock = now.add(monthLater);
      client.read(server.rows);
      client.edit(movePatch('move', x: 40));
      sendAndAnswer(client, server, ['move']);
      expect(client.queue.landed.single.revision, 2);
      expect(client.queue.shown.highest[const ElementTarget('e1')], 1);
      expect(
        (client.visible.element('e1')! as LiveElement).payload.data
            .toJson()['position'],
        {'dx': 40.0, 'dy': 0},
      );
    });

    test('Sol #3: a replacement on another page is where the complete read '
        'shows it, whatever revision the earlier life reached', () {
      final client = online(
        base: withElements([
          element('e1', revision: 2),
          element('e2'),
          element('e3', pageId: 'page-b'),
        ]),
      );
      client.clock = now.add(monthLater);
      client.arrive(headerReadOf(replacedLife(pageId: 'page-b')));
      client.arrive(pageReadOf(replacedLife(pageId: 'page-b'), 'page-b'));
      client.arrive(pageReadOf(replacedLife(pageId: 'page-b'), 'page-a'));
      final shown = client.queue.shown.rows[const ElementTarget('e1')]!;
      expect((shown.page, shown.revision), ('page-b', 1));
    });

    test('Sol #4: after the clock moved back, the complete read retires '
        'every landed record whatever its revision or send time, and nothing '
        'is left waiting', () {
      final server = Server();
      final client = online();
      client.edit(movePatch('move', x: 40));
      sendAndAnswer(client, server, ['move']);
      client.edit(movePatch('merge', x: 50, expected: 2, merge: null));
      expect(client.queue.landed, isNotEmpty);
      client.clock = now.subtract(const Duration(days: 1));
      client.read(replacedLife());
      expect(client.queue.landed, isEmpty);
      expect(resultsNeeded(client.queue, client.at), isEmpty);
    });

    test('Sol #4: an in-place patch that landed with no page on the wire is '
        'retired by the complete read with every other landed record, so no '
        'retirement read repeats', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch(
          'merge',
          x: 40,
          merge: FieldMerge(fields: const ['position']),
        ),
      );
      sendAndAnswer(client, server, ['merge']);
      expect(client.queue.landed.single.op, isA<ElementPatchOp>());
      server.rows = withElements([
        element('e2'),
        element('e3', pageId: 'page-b'),
      ]);
      client.clock = now.add(monthLater);
      client.read(server.rows);
      expect(client.queue.landed, isEmpty);
    });
  });

  group('what each op made before the complete read becomes', () {
    test(
      'an op whose row is as it was authored goes out checked on the '
      'fresh revision, with no basis, though the row\'s revision moved on',
      () {
        final server = Server()
          ..rows = withElements([
            element('e1', revision: 6),
            element('e2'),
            element('e3', pageId: 'page-b'),
          ]);
        final client = online(
          base: withElements([
            element('e1', revision: 4),
            element('e2'),
            element('e3', pageId: 'page-b'),
          ]),
        );
        client.clock = now.add(monthLater);
        client.edit(
          movePatch(
            'merge',
            x: 40,
            expected: 4,
            merge: FieldMerge(fields: const ['position']),
          ),
        );
        client.read(server.rows);
        final entry = client.queue.entry('merge')! as PendingOp;
        expect(entry.basis, isNull);
        client.claim(['merge']);
        expect(isUncheckedSend(client.lastSent().single), isFalse);
        expect(expectedOf(client.lastSent().single), 6);
      },
    );

    test('a field merge is judged by its whole row: a teammate\'s edit of '
        'another field asks the user', () {
      final client = online();
      client.clock = now.add(monthLater);
      client.edit(
        movePatch(
          'merge',
          x: 40,
          merge: FieldMerge(fields: const ['position']),
        ),
      );
      client.read(
        withElements([
          element('e1', revision: 2, fields: const {'rotation': 90}),
          element('e2'),
          element('e3', pageId: 'page-b'),
        ]),
      );
      expect(client.view('merge').state, const NeedsUser(ChangedUnseen()));
    });

    test('an own attempt that landed unanswered is settled by the read that '
        'shows it, even after a teammate touched another field', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch(
          'merge',
          x: 40,
          merge: FieldMerge(fields: const ['position']),
        ),
      );
      final attempt = client.claim(['merge']);
      server.apply(clientId, client.lastSent().single);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      server.rows = withOp(
        server.rows,
        movePatch('teammate', x: 40, rotation: 90, expected: 2),
      );
      client.clock = now.add(monthLater);
      final from = client.effects.length;
      client.read(server.rows);
      expect(client.queue.entry('merge'), isNull);
      expect(
        client.effects.skip(from),
        contains(
          const OpRemoved('merge', SettledByRead(ReadSettled.alreadyAsWritten)),
        ),
      );
    });

    test('a delete whose row the complete read no longer holds is done, not '
        'asked', () {
      final client = online();
      client.clock = now.add(monthLater);
      client.edit(elementDelete('drop'));
      client.read(
        withElements([element('e2'), element('e3', pageId: 'page-b')]),
      );
      expect(client.queue.entry('drop'), isNull);
      expect(
        client.effects,
        contains(const OpRemoved('drop', SettledByRead(ReadSettled.rowGone))),
      );
    });

    test(
      'keep mine and an op authored on an unreadable row are asked again',
      () {
        final server = Server()
          ..rows = withOp(initialRows(), movePatch('teammate', rotation: 90));
        final client = online();
        client.edit(movePatch('move', x: 40));
        sendAndAnswer(client, server, ['move']);
        expect(client.view('move').state, isA<NeedsUser>());
        client.must(
          UserKeptMine(
            'move',
            movePatch('mine', x: 40, expected: 2),
            authored: const AuthoredNoRow(),
          ),
        );
        client.must(
          UserEdited(switch (editOf(
            movePatch('blind', elementId: 'e2', x: 40),
            authored: const AuthoredUnreadable(),
            rowPage: 'page-a',
          )) {
            EditMade(:final edit) => edit,
            final other => fail('$other'),
          }),
        );
        client.clock = now.add(monthLater);
        client.read(server.rows);
        expect(client.view('mine').state, const NeedsUser(ChangedUnseen()));
        expect(client.view('blind').state, const NeedsUser(ChangedUnseen()));
      },
    );
  });

  group('the three cases the note did not cover', () {
    test('a send in flight at the lapse whose answer comes while the read is '
        'half done stays pending with its attempt on record, is judged at '
        'completion, and the resend is answered "applied when first '
        'received"', () {
      final server = Server();
      final client = online();
      client.clock = now.add(trustRowsFor - const Duration(minutes: 1));
      client.edit(movePatch('move', x: 40));
      final attempt = client.claim(['move']);
      final before = server.rows;
      final answer = server.apply(clientId, client.lastSent().single);
      client.clock = now.add(trustRowsFor + const Duration(minutes: 1));
      client.arrive(headerReadOf(before));
      client.arrive(pageReadOf(before, 'page-a'));
      client.must(OpAnswered(attempt, answer));
      expect(client.queue.entry('move'), isNotNull);
      client.arrive(pageReadOf(before, 'page-b'));
      client.clock = client.at.add(const Duration(seconds: 1));
      expect(client.view('move').sendable, isTrue);
      sendAndAnswer(client, server, ['move']);
      expect(client.queue.entry('move'), isNull);
      expect(client.queue.landed.single.revision, 2);
      expect(
        (client.visible.element('e1')! as LiveElement).payload.data
            .toJson()['position'],
        {'dx': 40.0, 'dy': 0},
      );
    });

    test('a send in flight at the lapse whose answer comes after the read '
        'completed is taken as usual, and stays drawn over the page read '
        'before it landed', () {
      final server = Server();
      final client = online();
      client.clock = now.add(trustRowsFor - const Duration(minutes: 1));
      client.edit(movePatch('move', x: 40));
      final attempt = client.claim(['move']);
      final before = server.rows;
      final answer = server.apply(clientId, client.lastSent().single);
      client.clock = now.add(trustRowsFor + const Duration(minutes: 1));
      client.read(before);
      client.must(OpAnswered(attempt, answer));
      expect(client.queue.entry('move'), isNull);
      expect(client.queue.landed.single.revision, 2);
    });

    test('a tombstone first seen in the complete read is not remembered, so '
        'when it is purged and its id comes back the new life is taken; every '
        'remembered revision belongs to a row live in the interval', () {
      final client = online();
      client.clock = now.add(monthLater);
      client.read(
        withElements([
          deletedElement('e1', revision: 7),
          element('e2'),
          element('e3', pageId: 'page-b'),
        ]),
      );
      const e1 = ElementTarget('e1');
      expect(client.queue.shown.highest.containsKey(e1), isFalse);
      expect(client.queue.shown.rows.containsKey(e1), isFalse);
      client.clock = client.at.add(const Duration(days: 1));
      client.arrive(
        pageReadOf(
          withElements([
            element('e2'),
            element('e3', pageId: 'page-b'),
            element('e1', pageId: 'page-b', fields: const {'rotation': 135}),
          ]),
          'page-b',
        ),
      );
      final shown = client.queue.shown.rows[e1]!;
      expect((shown.page, shown.revision), ('page-b', 1));
    });

    test('a tombstone of a row this device saw live in the interval is '
        'remembered as it always was', () {
      final client = online();
      client.read(
        withElements([
          deletedElement('e1', revision: 2),
          element('e2'),
          element('e3', pageId: 'page-b'),
        ]),
      );
      expect(client.queue.shown.highest[const ElementTarget('e1')], 2);
    });

    test('a reconnect or a restart in the middle of the complete read keeps '
        'the pages already read: only the rest are read', () {
      for (final interruption in <QueueEvent>[
        const ConnectionReturned(),
        const AppRestarted(build: build),
      ]) {
        final client = online();
        client.clock = now.add(monthLater);
        client.edit(movePatch('move', x: 40));
        client.arrive(headerReadOf(initialRows()));
        client.arrive(pageReadOf(initialRows(), 'page-a'));
        client.must(interruption);
        expect(client.view('move').holds, [
          const AwaitingResult(PageResult('page-b')),
        ]);
        client.arrive(pageReadOf(initialRows(), 'page-b'));
        expect(
          client.queue.strategy.knowledge,
          isA<KnownSince>(),
          reason: '$interruption',
        );
      }
    });
  });
}
