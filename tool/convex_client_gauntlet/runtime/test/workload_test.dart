import 'package:flutter_test/flutter_test.dart';
import 'package:icarus_convex_runtime_gauntlet/workload.dart';

void main() {
  test('each seed has one deterministic 1,000-op trace', () {
    for (var seed = 0; seed < 50; seed += 1) {
      final first = buildOperationTrace(seed);
      final second = buildOperationTrace(seed);
      expect(first, hasLength(operationsPerSeed));
      expect(canonicalHash(first), canonicalHash(second));
      expect(
        first.map((operation) => operation['opId']).toSet(),
        hasLength(operationsPerSeed),
      );
    }
  });

  test('the trace covers every synced entity boundary', () {
    final trace = buildOperationTrace(0);
    expect(
      trace.map((operation) => operation['entityType']).toSet(),
      containsAll(<String>[
        'strategy',
        'page',
        'pageContent',
        'element',
        'lineup',
      ]),
    );
    expect(
      trace.where((operation) => operation['kind'] == 'delete'),
      isNotEmpty,
    );
    expect(
      trace.where((operation) => operation['kind'] == 'reorder'),
      isNotEmpty,
    );
  });

  test('canonical snapshots exclude transport clocks', () {
    Object? state(double createdAt, double updatedAt) => canonicalSnapshot(
      seed: 0,
      snapshot: {
        'header': {'publicId': 'seed-0-strategy', 'createdAt': createdAt},
        'pages': [
          {
            'publicId': 'seed-0-page',
            'contentCreatedAt': createdAt,
            'contentUpdatedAt': updatedAt,
          },
        ],
        'elements': <Object?>[],
        'lineups': <Object?>[],
      },
      folders: <Object?>[],
    );

    expect(canonicalHash(state(1, 2)), canonicalHash(state(10, 20)));
  });
}
