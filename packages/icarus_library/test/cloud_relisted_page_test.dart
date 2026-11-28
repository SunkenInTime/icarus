import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_ordering_rules_test.dart'
    show arrivalAt, connectedOn, listWithout, pageA, pointAt;
import 'cloud_support.dart';

Set<Target> itemsOnA(Client client) => {
  for (final MapEntry(:key, :value) in client.queue.shown.rows.entries)
    if (value.page == 'page-a') key,
};

Client relisted(List<(ArrivedBase, int)> results) {
  final client = connectedOn();
  for (final (base, at) in results) {
    client.step(arrivalAt(client, base, pointAt(at)));
  }
  return client;
}

void main() {
  group('a page read older than the list that brought the page back onto '
      'the live list', () {
    final leftOut = (listWithout(initialRows(), 'page-a') as ArrivedBase, 10);
    final back = (headerReadOf(initialRows()) as ArrivedBase, 20);
    final before = (pageA() as ArrivedBase, 8);

    for (final (name, order) in [
      ('delivered last', [leftOut, back, before]),
      ('delivered between the two lists', [leftOut, before, back]),
    ]) {
      test('$name, does not mark the page\'s content read: the page draws '
          'no items and still owes a read', () {
        final client = relisted(order);
        final shown = client.queue.shown;
        expect(shown.pages, contains('page-a'));
        expect(shown.content, isNot(contains('page-a')));
        expect(itemsOnA(client), isEmpty);
        expect(pagesNeverRead(client.queue), contains('page-a'));
      });
    }

    test('both orders end in the same queue', () {
      final last = relisted([leftOut, back, before]).queue.shown;
      final between = relisted([leftOut, before, back]).queue.shown;
      expect(last.content.keys, between.content.keys);
      expect(last.pages.keys, between.pages.keys);
      expect(last.rows, between.rows);
    });

    test('a page read newer than the list that left the page out, but older '
        'than the list that brought it back, fills the page', () {
      final client = relisted([leftOut, back, (pageA(), 15)]);
      expect(client.queue.shown.content, contains('page-a'));
      expect(itemsOnA(client), isNotEmpty);
    });

    test('known behaviour, not the fixed case: with the list that brought '
        'the page back delivered first and the older list that left it out '
        'dropped as older, the read from before it left fills the page with '
        'its items, held as any page read older than its list is, and a later '
        'read replaces them', () {
      final client = relisted([back, leftOut, before]);
      expect(client.queue.shown.content, contains('page-a'));
      expect(itemsOnA(client), isNotEmpty);
      final later = withOp(
        initialRows(),
        elementAdd('their-add', elementId: 'e9', pageId: 'page-a'),
      );
      client.must(arrivalAt(client, pageReadOf(later, 'page-a'), pointAt(21)));
      expect(itemsOnA(client), contains(const ElementTarget('e9')));
    });

    test('a page read newer than that list still fills the page', () {
      final client = relisted([leftOut, back, (pageA(), 21)]);
      expect(client.queue.shown.content, contains('page-a'));
      expect(itemsOnA(client), isNotEmpty);
    });
  });
}
