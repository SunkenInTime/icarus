import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus_convex_runtime_gauntlet/runner.dart';
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
      for (final operation in first) {
        expect(operation['type'], isA<String>());
        expect(operation, isNot(contains('kind')));
        expect(operation, isNot(contains('entityType')));
        expect(operation, isNot(contains('entityPublicId')));
        expect(operation, isNot(contains('expectedRevision')));
      }
    }
  });

  test('the trace covers every synced entity boundary', () {
    final trace = buildOperationTrace(0);
    final types = trace.map((operation) => operation['type'] as String);
    expect(
      types.map((type) => type.split('.').first).toSet(),
      containsAll(<String>{
        'strategy',
        'page',
        'pageContent',
        'element',
        'lineup',
      }),
    );
    expect(types.where((type) => type.endsWith('.delete')), isNotEmpty);
    expect(types.where((type) => type.endsWith('.reorder')), isNotEmpty);
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

  test('rejected auth fixture is an expired, decodable JWT', () {
    final parts = rejectedExpiredAccessToken.split('.');
    expect(parts, hasLength(3));
    final claims =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, dynamic>;
    expect(claims['exp'], 0);
  });
}
