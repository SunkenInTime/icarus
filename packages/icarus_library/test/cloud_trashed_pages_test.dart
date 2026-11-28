import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_ordering_rules_test.dart'
    show arrivalAt, connectedOn, pageA, pointAt, stateIn;
import 'cloud_server.dart';
import 'cloud_support.dart';

final theyTrashedA = withOp(initialRows(), pageDelete('their-drop', 'page-a'));

final purgedA = withoutPage(theyTrashedA, 'page-a');

Set<Target> itemsOn(Client client, String page) => {
  for (final MapEntry(:key, :value) in client.queue.shown.rows.entries)
    if (value.page == page) key,
};

Client readA() {
  final client = connectedOn();
  client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
  client.must(arrivalAt(client, pageA(), pointAt(3)));
  expect(itemsOn(client, 'page-a'), isNotEmpty);
  return client;
}

void expectInTheTrash(Client client, String page) {
  final shown = client.queue.shown;
  expect(shown.trashed, contains(page));
  expect(shown.pages, isNot(contains(page)));
  expect(shown.content, isNot(contains(page)));
  expect(shown.pageReads, isNot(contains(page)));
  expect(itemsOn(client, page), isEmpty);
  expect(shown.list, isNot(isA<ReadOwed>()));
  expect(owedReads(client.queue), isEmpty);
}

void main() {
  group('a page in the trash: one decision for a list showing it trashed, a '
      'read answering not found, and my own delete landing', () {
    for (final (name, first, second) in [
      ('the list, then the not-found read', 10, 11),
      ('the not-found read, then the list', 11, 10),
      ('the list and the not-found read at one order', 10, 10),
    ]) {
      test('$name: the page ends in the trash, with no content, no items '
          'and no read mark, and nothing owed', () {
        final client = readA();
        client.must(
          arrivalAt(client, headerReadOf(theyTrashedA), pointAt(first)),
        );
        client.step(
          arrivalAt(
            client,
            pageReadOf(theyTrashedA, 'page-a'),
            pointAt(second),
          ),
        );
        if (first > second) {
          client.must(
            arrivalAt(client, headerReadOf(theyTrashedA), pointAt(12)),
          );
        }
        expectInTheTrash(client, 'page-a');
        expect(client.effects, isNot(contains(isA<ReportSameOrderDiffers>())));
      });
    }

    test('both arrival orders end in the same queue', () {
      Client deliver(List<(ArrivedBase, int)> results) {
        final client = readA();
        for (final (base, at) in results) {
          client.step(arrivalAt(client, base, pointAt(at)));
        }
        client.must(arrivalAt(client, headerReadOf(theyTrashedA), pointAt(20)));
        return client;
      }

      final listFirst = deliver([
        (headerReadOf(theyTrashedA), 10),
        (pageReadOf(theyTrashedA, 'page-a'), 11),
      ]);
      final readFirst = deliver([
        (pageReadOf(theyTrashedA, 'page-a'), 11),
        (headerReadOf(theyTrashedA), 10),
      ]);
      expect(
        readFirst.queue.shown.sameContentAs(listFirst.queue.shown),
        isTrue,
      );
      expect(
        readFirst.queue.shown.trashed.keys,
        listFirst.queue.shown.trashed.keys,
      );
      expect(
        readFirst.queue.shown.pages.keys,
        listFirst.queue.shown.pages.keys,
      );
    });

    test('a not-found read never removes a page the list holds as trashed', () {
      final client = readA();
      client.must(arrivalAt(client, headerReadOf(theyTrashedA), pointAt(10)));
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(11)));
      expectInTheTrash(client, 'page-a');
      expect(client.queue.shown.goneThisSession, isNot(contains('page-a')));
    });

    test('a not-found read never blocks an older list from installing the '
        'page as trashed', () {
      final client = readA();
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(11)));
      client.step(arrivalAt(client, headerReadOf(theyTrashedA), pointAt(10)));
      expect(client.queue.shown.pages, isNot(contains('page-a')));
      client.must(arrivalAt(client, headerReadOf(theyTrashedA), pointAt(12)));
      expectInTheTrash(client, 'page-a');
    });

    test('a not-found read of a page this device never held does not stop '
        'an older list from installing it in the trash', () {
      final added = withOp(
        initialRows(),
        pageAdd('their-add', 'page-c', expected: 1),
      );
      final trashedC = withOp(
        added,
        pageDelete('their-drop', 'page-c', expected: added.strategy.revision),
      );
      final client = readA();
      client.must(arrivalAt(client, const PageGone('page-c'), pointAt(11)));
      client.must(arrivalAt(client, headerReadOf(trashedC), pointAt(10)));
      expect(client.queue.shown.trashed, contains('page-c'));
    });

    test('an edit behind my own landed work on a page the store holds in the '
        'trash is not asked as page gone and does not wait for a row no read '
        'will show: it goes, for the server to judge', () {
      final client = readA();
      client.edit(movePatch('first', merge: FieldMerge(fields: ['position'])));
      final attempt = client.claim(['first']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('first', revision: 2, life: fixtureLife),
          point: pointAt(10),
        ),
      );
      client.edit(onVisible(client.visible, movePatch('second', x: 70)));
      final trashed = withOp(
        withOp(
          initialRows(),
          movePatch('first', merge: FieldMerge(fields: ['position'])),
        ),
        pageDelete('their-drop', 'page-a'),
      );
      client.must(arrivalAt(client, headerReadOf(trashed), pointAt(11)));
      expect(
        client.view('second').holds,
        isNot(contains(isA<AwaitingResult>())),
      );
      expect(client.view('second').sendable, isTrue);
    });

    test('a not-found read of a page the list shows live: not live any '
        'more, the list owed, and the list decides between the trash and '
        'gone', () {
      final trashed = readA();
      trashed.edit(movePatch('mine', x: 40));
      trashed.must(arrivalAt(trashed, const PageGone('page-a'), pointAt(10)));
      expect(trashed.queue.shown.pages, isNot(contains('page-a')));
      expect(trashed.queue.shown.trashed, isNot(contains('page-a')));
      expect(trashed.queue.shown.list, isA<ReadOwed>());
      expect(stateIn(trashed, 'mine'), isNot(isA<NeedsUser>()));
      expect(trashed.view('mine').sendable, isFalse);
      trashed.must(arrivalAt(trashed, headerReadOf(theyTrashedA), pointAt(11)));
      expectInTheTrash(trashed, 'page-a');
      expect(trashed.view('mine').sendable, isTrue);

      final gone = readA();
      gone.edit(movePatch('mine', x: 40));
      gone.must(arrivalAt(gone, const PageGone('page-a'), pointAt(10)));
      gone.must(arrivalAt(gone, headerReadOf(purgedA), pointAt(11)));
      expect(gone.queue.shown.trashed, isNot(contains('page-a')));
      expect(gone.queue.shown.pages, isNot(contains('page-a')));
    });

    test('my own delete landing drops the page\'s content and read mark, and '
        'asks for no read of it', () {
      final client = readA();
      client.edit(pageDelete('drop', 'page-a'));
      final attempt = client.claim(['drop']);
      client.must(
        OpAnswered(
          attempt,
          AppliedAnswer(
            'drop',
            revision: theyTrashedA.strategy.revision,
            life: fixtureLife,
          ),
          point: pointAt(10),
        ),
      );
      final shown = client.queue.shown;
      expect(shown.content, isNot(contains('page-a')));
      expect(shown.pageReads, isNot(contains('page-a')));
      expect(itemsOn(client, 'page-a'), isEmpty);
      expect(pagesNeverRead(client.queue), isNot(contains('page-a')));
      expect(
        resultsNeeded(client.queue, client.at),
        isNot(contains(const PageResult('page-a'))),
      );
      client.must(arrivalAt(client, headerReadOf(theyTrashedA), pointAt(11)));
      expectInTheTrash(client, 'page-a');
      expect(client.queue.landed, isEmpty);
    });

    test('landed work on a page a teammate then trashed is retired by the '
        'page list that shows it in the trash', () {
      final client = readA();
      client.edit(movePatch('mine', x: 40));
      final attempt = client.claim(['mine']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('mine', revision: 2, life: fixtureLife),
          point: pointAt(10),
        ),
      );
      expect(client.queue.landed, isNotEmpty);
      final trashed = withOp(
        withOp(initialRows(), movePatch('mine', x: 40)),
        pageDelete('their-drop', 'page-a'),
      );
      client.must(arrivalAt(client, headerReadOf(trashed), pointAt(11)));
      expect(client.queue.landed, isEmpty);
      expectInTheTrash(client, 'page-a');
    });
  });
}
