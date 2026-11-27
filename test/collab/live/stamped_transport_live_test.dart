import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';

const _deploymentUrl = String.fromEnvironment('CONVEX_URL');
const _accessToken = String.fromEnvironment('GAUNTLET_ACCESS_TOKEN');
const _protocol = 6.0;
const _writes = 3;
const _patience = Duration(seconds: 30);

List<String> _names(Stamped<List<FoldersListTreeResultItem>> result) =>
    switch (result) {
      StampedValue(:final value) => [for (final folder in value) folder.name],
      StampedError(:final error) => fail('the folder tree failed: $error'),
    };

Future<void> _until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(_patience);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('$what within $_patience');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test(
    'the stamped transport stamps reads, watches, groups and answers, and a '
    'read after a batch refused op by op is at or after its snapshot',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await ConvexClient.initialize(
        const ConvexConfig(
          deploymentUrl: _deploymentUrl,
          clientId: 'icarus-stamped-transport-live',
          operationTimeout: _patience,
        ),
      );
      final client = ConvexClient.instance;
      addTearDown(client.dispose);
      await client.setAuthWithRefresh(fetchToken: () async => _accessToken);
      final transport = StampedPlatformTransport(client);
      final api = IcarusConvexApi(transport);
      await api.users.ensureCurrentUser(clientProtocolVersion: _protocol);

      final tree = api.folders.listTree(
        scope: const ConvexOptional.present(FoldersListTreeArgsScope.all),
      );
      final live = <Stamped<List<FoldersListTreeResultItem>>>[];
      final watching = tree.stampedOn(transport).watch().listen(live.add);
      addTearDown(watching.cancel);
      final grouped = <Stamped<List<Object?>>>[];
      final groupWatching = StampedConvexQuery.watchTogether(
        transport,
        [tree, api.users.me()],
      ).listen(grouped.add);
      addTearDown(groupWatching.cancel);
      final reads = [await tree.stampedOn(transport).fetch()];
      final answers = <String, Stamped<ConvexValue>>{};

      for (var write = 0; write < _writes; write++) {
        final name =
            'Stamped transport $write ${DateTime.now().microsecondsSinceEpoch}';
        final answer = await transport.mutationStamped(
          'folders:create',
          encodeFoldersCreateArgs(
            clientProtocolVersion: _protocol,
            name: name,
            publicId:
                'stamped-transport-$write-${DateTime.now().microsecondsSinceEpoch}',
          ),
        );
        expect(answer, isA<StampedValue<ConvexValue>>());
        expect(answer.stamp.snapshot, greaterThan(reads.last.stamp.snapshot));
        answers[name] = answer;
        final read = await tree.stampedOn(transport).fetch();
        expect(_names(read), contains(name));
        expect(
            read.stamp.snapshot, greaterThanOrEqualTo(answer.stamp.snapshot));
        reads.add(read);
        await _until(
          () => live.any((result) => _names(result).contains(name)),
          'no live result showed folder $write',
        );
      }
      final everyName = answers.keys.toSet();
      await _until(
        () => grouped.any(
          (update) => switch (update) {
            StampedValue(:final value) =>
              (value.first! as List<FoldersListTreeResultItem>)
                  .map((folder) => folder.name)
                  .toSet()
                  .containsAll(everyName),
            StampedError() => false,
          },
        ),
        'no grouped update showed every folder',
      );

      final second = await tree.stampedOn(transport).watch().first;
      await watching.cancel();
      await groupWatching.cancel();
      final generation = await transport.generation();

      final results = [...reads, ...live, second];
      final stamps = [
        for (final result in results) result.stamp,
        for (final answer in answers.values) answer.stamp,
        for (final update in grouped) update.stamp,
      ];
      expect({for (final stamp in stamps) stamp.client}, {generation.client});
      expect(
        {for (final stamp in stamps) stamp.connection},
        {generation.connection},
        reason: 'a local deployment never drops the socket in this run',
      );
      expect(second.stamp.snapshot,
          greaterThanOrEqualTo(reads.last.stamp.snapshot));
      expect(_names(second).toSet().containsAll(everyName), isTrue);
      var sameSnapshot = 0;
      for (final a in results) {
        for (final b in results) {
          if (!identical(a, b) && a.stamp.snapshot == b.stamp.snapshot) {
            sameSnapshot++;
            expect(_names(a), _names(b), reason: 'one snapshot, one result');
          }
        }
      }
      expect(sameSnapshot, greaterThan(0),
          reason: 'the second watch starts from the snapshot already held');
      for (final MapEntry(key: name, value: answer) in answers.entries) {
        for (final result in results) {
          if (result.stamp.snapshot >= answer.stamp.snapshot &&
              result.stamp.serverTime! >= answer.stamp.serverTime!) {
            expect(_names(result), contains(name));
          }
        }
      }
      for (var at = 1; at < grouped.length; at++) {
        expect(
          grouped[at].stamp.snapshot,
          greaterThan(grouped[at - 1].stamp.snapshot),
        );
      }

      final refused = await transport.mutationStamped(
        'folders:create',
        encodeFoldersCreateArgs(
          clientProtocolVersion: _protocol,
          name: 'Orphan',
          publicId: 'stamped-transport-orphan',
          parentFolderPublicId:
              const ConvexOptional.present('stamped-transport-no-such-folder'),
        ),
      );
      expect(
        refused,
        isA<StampedError<ConvexValue>>()
            .having((it) => it.error.rawCode, 'code', 'NOT_FOUND'),
      );
      expect(
          refused.stamp.snapshot, greaterThanOrEqualTo(second.stamp.snapshot));
      expect(refused.stamp.connection, generation.connection);
      expect(refused.stamp.client, generation.client);
      expect(refused.stamp.serverTime, isNotNull);

      final strategyPublicId =
          'stamped-transport-strategy-${DateTime.now().microsecondsSinceEpoch}';
      await api.strategies.create(
        clientProtocolVersion: _protocol,
        mapData: 'ascent',
        name: 'Stamped transport refusals',
        publicId: strategyPublicId,
      );
      final shell = api.strategy.getShell(
        clientProtocolVersion: _protocol,
        strategyPublicId: strategyPublicId,
      );
      double revisionIn(Stamped<StrategyGetShellResult> read) => switch (read) {
            StampedValue(:final value) => value.header.revision,
            StampedError(:final error) => fail('the shell failed: $error'),
          };
      final created = revisionIn(await shell.stampedOn(transport).fetch());
      final everyOpRefused = await transport.mutationStamped(
        'ops:applyBatch',
        encodeOpsApplyBatchArgs(
          clientId: 'icarus-stamped-transport-live',
          clientProtocolVersion: _protocol,
          strategyPublicId: strategyPublicId,
          ops: [
            for (final at in [0, 1])
              OpsApplyBatchArgsOpsItemStrategyPatch(
                opId: '$strategyPublicId-stale-$at',
                expectedStrategyRevision: 7,
                payload: OpsApplyBatchArgsOpsItemStrategyPatchPayload(
                  name: ConvexOptional.present('Never $at'),
                ),
              ),
          ],
        ),
      );
      final batch = switch (everyOpRefused) {
        StampedValue(:final value) => decodeOpsApplyBatchResult(value),
        StampedError(:final error) => fail('the batch failed whole: $error'),
      };
      expect(batch.results, hasLength(2));
      expect(
        batch.results,
        everyElement(
          isA<OpsApplyBatchResultResultsItemRejected>().having(
            (rejected) => rejected.reason,
            'reason',
            OpsApplyBatchResultResultsItemRejectedReason.revisionMismatch,
          ),
        ),
      );
      expect(everyOpRefused.stamp.client, generation.client);
      expect(everyOpRefused.stamp.connection, generation.connection);
      expect(everyOpRefused.stamp.serverTime, isNotNull);
      final readAfter = await shell.stampedOn(transport).fetch();
      expect(readAfter.stamp.connection, everyOpRefused.stamp.connection);
      expect(
        readAfter.stamp.snapshot,
        greaterThanOrEqualTo(everyOpRefused.stamp.snapshot),
        reason: 'a batch refused op by op is answered once its snapshot is '
            'visible, so a read after it is at or after that snapshot',
      );
      expect(revisionIn(readAfter), created);

      final unconvertible = ConvexObject({
        r'$reserved': const ConvexString('not a field name'),
      });
      expect(
        await transport.mutationStamped('folders:create', unconvertible),
        isA<StampedError<ConvexValue>>()
            .having((it) => it.error.rawCode, 'code', 'CONVEX_ERROR')
            .having(
                (it) => it.error.message, 'message', contains(r'$reserved')),
        reason: 'the native client sends them, and the server refuses them',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: _deploymentUrl.isEmpty
        ? 'Run through tool/convex_client_gauntlet/runtime/tool/'
            'run_with_local_deployment.mjs'
        : false,
  );
}
