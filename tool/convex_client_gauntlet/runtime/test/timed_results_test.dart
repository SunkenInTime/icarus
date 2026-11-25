import 'dart:convert';
import 'dart:io';

import 'package:convex_flutter/convex_flutter.dart' as convex_flutter;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus_convex_runtime_gauntlet/workload.dart';

String _setting(String name) => Platform.environment[name] ?? '';

const _writes = 5;
const _patience = Duration(seconds: 30);
const _clockSlack = Duration(minutes: 5);

List<String> _folderNames(convex_flutter.TimedAnswer answer) => [
  for (final folder in jsonDecode(answer.value!) as List)
    (folder as Map)['name'] as String,
];

void main() {
  final deploymentUrl = _setting('CONVEX_URL');

  test(
    'reads and live results carry their snapshot into Dart',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null;
      await convex_flutter.ConvexClient.initialize(
        convex_flutter.ConvexConfig(
          deploymentUrl: deploymentUrl,
          clientId: 'icarus-timed-results',
          operationTimeout: _patience,
          healthCheckQuery: 'users:me',
        ),
      );
      final client = convex_flutter.ConvexClient.instance;
      final token = _setting('GAUNTLET_ACCESS_TOKEN');
      await client.setAuthWithRefresh(fetchToken: () async => token);
      await client.mutation(
        name: 'users:ensureCurrentUser',
        args: const {'clientProtocolVersion': cloudProtocolVersion},
      );

      const tree = 'folders:listTree';
      const treeArgs = {'scope': 'all'};
      final live = <convex_flutter.TimedAnswer>[];
      final handle = await client.subscribeTimed(
        name: tree,
        args: treeArgs,
        onResult: live.add,
      );
      final grouped = <convex_flutter.TimedGroupUpdate>[];
      final groupHandle = await client.subscribeGroupTimed(
        queries: [
          (name: tree, args: treeArgs),
          (name: 'users:me', args: const {}),
        ],
        onUpdate: grouped.add,
      );
      final reads = [await client.queryTimed(tree, treeArgs)];
      final written = <String>[];
      final answers = <String, convex_flutter.TimedAnswer>{};

      for (var write = 0; write < _writes; write++) {
        final name =
            'Timed results $write ${DateTime.now().microsecondsSinceEpoch}';
        final answer = await client.mutationTimed(
          name: 'folders:create',
          args: {
            'clientProtocolVersion': cloudProtocolVersion,
            'publicId':
                'timed-results-$write-${DateTime.now().microsecondsSinceEpoch}',
            'name': name,
          },
        );
        expect(answer.error, isNull);
        expect(answer.snapshot, greaterThan(reads.last.snapshot));
        answers[name] = answer;
        final read = await client.queryTimed(tree, treeArgs);
        expect(read.snapshot, greaterThanOrEqualTo(answer.snapshot));
        expect(_folderNames(read), contains(name));
        expect(read.snapshot, greaterThan(reads.last.snapshot));
        expect(read.ts!, greaterThan(reads.last.ts!));
        reads.add(read);

        final shown = DateTime.now().add(_patience);
        while (!live.any((answer) => _folderNames(answer).contains(name))) {
          if (DateTime.now().isAfter(shown)) {
            fail('no live result showed folder $write within $_patience');
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        written.add(name);
      }
      List<String>? treeOf(convex_flutter.TimedGroupUpdate update) =>
          switch (update.values.firstOrNull) {
            final tree? => [
              for (final folder in jsonDecode(tree) as List)
                (folder as Map)['name'] as String,
            ],
            null => null,
          };
      final groupShown = DateTime.now().add(_patience);
      while (!grouped.any(
        (update) => treeOf(update)?.toSet().containsAll(written) ?? false,
      )) {
        if (DateTime.now().isAfter(groupShown)) {
          fail('no grouped update showed every folder within $_patience');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      handle.cancel();
      groupHandle.cancel();
      final groupedSeen = [...grouped];

      final results = [...reads, ...live];
      final stamps = [...results, ...answers.values];
      expect(stamps.map((answer) => answer.client).toSet(), hasLength(1));
      expect(
        {
          ...stamps.map((answer) => answer.connection),
          ...groupedSeen.map((update) => update.connection),
        },
        {0},
        reason: 'a local deployment never drops the socket in this run',
      );
      for (final MapEntry(key: name, value: answer) in answers.entries) {
        for (final result in results) {
          if (result.snapshot >= answer.snapshot) {
            expect(
              _folderNames(result),
              contains(name),
              reason:
                  'a result at or after the answer\'s snapshot has the write',
            );
          }
        }
      }

      for (var at = 1; at < groupedSeen.length; at++) {
        expect(
          groupedSeen[at].snapshot,
          greaterThan(groupedSeen[at - 1].snapshot),
        );
      }
      for (final update in groupedSeen) {
        expect(update.error, isNull);
        expect(update.ts, isNotNull);
        expect(update.client, stamps.first.client);
        if (treeOf(update) case final names?) {
          for (final MapEntry(key: name, value: answer) in answers.entries) {
            if (update.snapshot >= answer.snapshot) {
              expect(names, contains(name));
            }
          }
        }
      }
      final now = DateTime.now().microsecondsSinceEpoch * 1000;
      for (final answer in results) {
        expect(answer.error, isNull);
        expect(
          (answer.ts! - now).abs(),
          lessThan(_clockSlack.inMicroseconds * 1000),
          reason: 'ts is the server clock in nanoseconds',
        );
      }
      for (final name in written) {
        final firstSnapshotShowing = results
            .where((answer) => _folderNames(answer).contains(name))
            .map((answer) => answer.snapshot)
            .reduce((a, b) => a < b ? a : b);
        for (final answer in results) {
          if (answer.snapshot >= firstSnapshotShowing) {
            expect(
              _folderNames(answer),
              contains(name),
              reason: 'a later snapshot keeps the write',
            );
          }
        }
      }
      for (final a in results) {
        for (final b in results) {
          if (a.snapshot == b.snapshot) {
            expect(a.value, b.value, reason: 'one snapshot, one result');
            expect(a.ts, b.ts);
          }
          if (a.snapshot < b.snapshot) {
            expect(a.ts!, lessThanOrEqualTo(b.ts!));
          }
        }
      }

      const missing = {
        'clientProtocolVersion': cloudProtocolVersion,
        'strategyPublicId': 'timed-results-no-such-strategy',
      };
      final refused = await client.queryTimed('strategy:getShell', missing);
      expect(refused.value, isNull);
      expect(refused.error?.data, isNotNull);
      expect(refused.ts, isNotNull);
      expect(refused.snapshot, greaterThanOrEqualTo(reads.last.snapshot));

      final liveErrors = <convex_flutter.TimedAnswer>[];
      final errorHandle = await client.subscribeTimed(
        name: 'strategy:getShell',
        args: missing,
        onResult: liveErrors.add,
      );
      final answered = DateTime.now().add(_patience);
      while (liveErrors.isEmpty) {
        if (DateTime.now().isAfter(answered)) {
          fail('the live query of a missing strategy never answered');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      errorHandle.cancel();
      expect(liveErrors.first.value, isNull);
      expect(liveErrors.first.error?.data, refused.error!.data);
      expect(liveErrors.first.ts, isNotNull);
      expect(liveErrors.first.snapshot, greaterThanOrEqualTo(refused.snapshot));

      final failed = await client.mutationTimed(
        name: 'folders:create',
        args: const {
          'clientProtocolVersion': cloudProtocolVersion,
          'publicId': 'timed-results-orphan',
          'name': 'Orphan',
          'parentFolderPublicId': 'timed-results-no-such-folder',
        },
      );
      expect(failed.value, isNull);
      expect(failed.error?.data, isNotNull);
      expect(failed.ts, isNotNull);
      expect(failed.snapshot, greaterThanOrEqualTo(liveErrors.first.snapshot));
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: deploymentUrl.isEmpty
        ? 'Run through tool/run_with_local_deployment.mjs'
        : false,
  );
}
