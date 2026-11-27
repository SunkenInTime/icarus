import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

Map<String, Object?> summaryAsTheBuildBeforeWroteIt(
  Map<String, Object?> summary,
) =>
    {
      for (final MapEntry(:key, :value) in summary.entries)
        if (key != 'agentsInOrder' && key != 'firstPageIsAttack')
          key: switch (key) {
            'summaryVersion' => 5,
            'tallies' => {
                for (final MapEntry(:key, :value)
                    in (value! as Map<String, Object?>).entries)
                  key: tallyAsTheBuildBeforeWroteIt(value),
              },
            'elsewhere' => tallyAsTheBuildBeforeWroteIt(value),
            _ => value,
          },
    };

Map<String, Object?> tallyAsTheBuildBeforeWroteIt(Object? tally) => {
      for (final MapEntry(:key, :value)
          in (tally! as Map<String, Object?>).entries)
        if (key != 'order') key: value,
    };

Future<int> ageSummaries(SqliteEngine engine) async {
  final lease = switch (await engine.lease()) {
    Leased(:final lease) => lease,
    final other => fail('$other'),
  };
  final entries = switch (await lease.entries('library', 'summary/')) {
    Done(:final value) => value,
    final other => fail('$other'),
  };
  expect(
    await lease.commit([
      for (final (:key, :value) in entries)
        Put(
          'library',
          key,
          jsonEncode(
            summaryAsTheBuildBeforeWroteIt(
              jsonDecode(value) as Map<String, Object?>,
            ),
          ),
        ),
    ]),
    isA<CommitApplied>(),
  );
  await lease.release();
  return entries.length;
}

const resultsOfANewerBuild = '{"version":99}';

Future<int> resultsAsANewerBuildWroteThem(StorageEngine engine) async {
  final lease = switch (await engine.lease()) {
    Leased(:final lease) => lease,
    final other => fail('$other'),
  };
  final areas = switch (await lease.areas('s/')) {
    Done(:final value) => value,
    final other => fail('$other'),
  };
  final changes = <Change>[
    for (final area in areas)
      if (await lease.read(area, 'read/header') is KeyHeld)
        Put(area, 'read/header', resultsOfANewerBuild),
  ];
  expect(await lease.commit(changes), isA<CommitApplied>());
  await lease.release();
  return changes.length;
}
