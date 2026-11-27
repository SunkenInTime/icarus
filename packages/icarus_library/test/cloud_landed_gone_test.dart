import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_ordering_rules_test.dart'
    show arrivalAt, connectedOn, listWithout, pointAt;
import 'cloud_support.dart';

Client landedAddAt(int snapshot, {String page = 'page-a'}) {
  final client = connectedOn();
  client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
  client.edit(elementAdd('add', pageId: page));
  final attempt = client.claim(['add']);
  client.must(
    OpAnswered(
      attempt,
      const AppliedAnswer('add', revision: 1, life: fixtureLife),
      point: pointAt(snapshot),
    ),
  );
  expect(client.queue.landed, hasLength(1));
  return client;
}

void main() {
  group('landed work on a page that is gone retires on a result about that '
      'page at or after its answer', () {
    test('a page-gone of its page after the answer retires it', () {
      final client = landedAddAt(10);
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(20)));
      expect(client.queue.landed, isEmpty);
    });

    test('a list after the answer that no longer has its page retires it', () {
      final client = landedAddAt(10);
      client.must(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(20)),
      );
      expect(client.queue.landed, isEmpty);
    });

    test('a page-gone of its page from before the answer leaves it', () {
      final client = landedAddAt(20);
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(10)));
      expect(client.queue.shown.pages, isNot(contains('page-a')));
      expect(client.queue.landed, hasLength(1));
    });

    test('a page-gone of another page never retires it, though its own page '
        'is gone by an older result', () {
      final client = landedAddAt(10);
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(8)));
      expect(client.queue.landed, hasLength(1));
      client.must(arrivalAt(client, const PageGone('page-b'), pointAt(30)));
      expect(client.queue.landed, hasLength(1));
    });

    test('a list that no longer has its page, taken before the answer '
        'arrived, retires it when the answer lands', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
      client.edit(elementAdd('add'));
      final attempt = client.claim(['add']);
      client.must(
        arrivalAt(client, listWithout(initialRows(), 'page-a'), pointAt(20)),
      );
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('add', revision: 1, life: fixtureLife),
          point: pointAt(10),
        ),
      );
      expect(client.queue.entry('add'), isNull);
      expect(client.queue.landed, isEmpty);
    });

    test('a page-gone at the answer\'s point but at an earlier server time '
        'leaves it', () {
      final client = landedAddAt(10);
      client.must(
        arrivalAt(
          client,
          const PageGone('page-a'),
          pointAt(12, time: pointAt(10).serverTime! - 1),
        ),
      );
      expect(client.queue.landed, hasLength(1));
    });
  });
}
