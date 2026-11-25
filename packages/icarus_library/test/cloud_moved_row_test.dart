import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

void main() {
  test(
    'a whole write behind this device\'s own landed work waits for the page '
    'the row was last shown on, not the page the editor still draws it on',
    () {
      final moved = strategyRows(
        elements: [
          element('e1'),
          element('e2', pageId: 'page-b', revision: 2),
          element('e3', pageId: 'page-b'),
        ],
      );
      final client = Client(base: initialRows())..must(reconnected());
      client.read(initialRows());
      client.read(moved);
      client.base = initialRows();
      client.edit(
        movePatch(
          'merge',
          elementId: 'e2',
          merge: FieldMerge(fields: const ['position']),
        ),
      );
      final attempt = client.claim(['merge']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('merge', revision: 4, life: fixtureLife),
          point: tick(),
        ),
      );
      expect(client.queue.landed.single.produced, isNull);
      client
        ..must(const ConnectionLost())
        ..must(reconnected());
      client.edit(movePatch('whole', elementId: 'e2', expected: 4));
      expect(client.view('whole').holds, [
        awaitingResult(RowResult(const ElementTarget('e2'), 'page-b')),
      ]);
    },
  );
}
