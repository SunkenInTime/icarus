import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

const _budget = 1.45;

String _row(int index) => jsonEncode({
  'publicId': 'item-$index',
  'pagePublicId': 'page',
  'sortIndex': index,
  'revision': 1,
  'deleted': false,
  'payload': {
    'kind': index.isEven ? 'agent' : 'drawing',
    'payloadVersion': 1,
    'data': index.isEven
        ? {
            'id': 'item-$index',
            'elementType': 'agent',
            'type': 'jett',
            'position': {'dx': index * 1.5, 'dy': 20.5},
          }
        : {
            'id': 'item-$index',
            'elementType': 'drawing',
            'points': [
              for (var i = 0; i < 1000; i++)
                {'dx': 100 + i * 0.731, 'dy': 200 + (i % 37) * 1.913},
            ],
          },
  },
});

int _micros(void Function() task) {
  final watch = Stopwatch()..start();
  task();
  return watch.elapsedMicroseconds;
}

int _fastest(List<int> values) => values.reduce((a, b) => a < b ? a : b);

void main() {
  test(
    'reading a page costs at most $_budget times decoding its rows, so no per-value copy has come back',
    () {
      final texts = [for (var i = 0; i < 300; i++) _row(i)];
      final page = RowSpot(names: (id) => id == 'page');
      void decode() {
        for (final text in texts) {
          jsonDecode(text);
        }
      }

      void read() {
        for (final text in texts) {
          final parsed = ElementRow.parse(
            admit(text),
            spot: RowSpot(names: (id) => true),
            page: page,
            canRead: (_) => true,
          );
          if (parsed is! Placed<ElementRow>) fail('$parsed');
        }
      }

      for (final text in texts) {
        expect(
          ElementRow.parse(
            admit(text),
            spot: RowSpot(names: (id) => true),
            page: page,
            canRead: (_) => true,
          ),
          isA<Placed<ElementRow>>().having(
            (placed) => placed.row,
            'row',
            isA<LiveElement>(),
          ),
        );
      }
      for (var i = 0; i < 3; i++) {
        decode();
        read();
      }
      final decoded = <int>[];
      final reads = <int>[];
      for (var i = 0; i < 25; i++) {
        decoded.add(_micros(decode));
        reads.add(_micros(read));
      }
      final ratio = _fastest(reads) / _fastest(decoded);
      printOnFailure('read / jsonDecode = ${ratio.toStringAsFixed(2)}');
      expect(ratio, lessThan(_budget));
    },
  );
}
