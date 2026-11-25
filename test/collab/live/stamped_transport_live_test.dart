import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';

import 'load_convex_bundle.dart';

const _deploymentUrl = String.fromEnvironment('CONVEX_URL');
const _accessToken = String.fromEnvironment('GAUNTLET_ACCESS_TOKEN');
const _bundleUrl = String.fromEnvironment('CONVEX_BUNDLE_URL');
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
    'the stamped transport stamps reads, watches, groups and answers on '
    '${kIsWeb ? 'web' : 'native'}',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadConvexBundle(_bundleUrl);
      await ConvexClient.initialize(
        const ConvexConfig(
          deploymentUrl: _deploymentUrl,
          clientId: 'icarus-stamped-transport-live',
          operationTimeout: _patience,
        ),
      );
      final client = ConvexClient.instance;
      await client.setAuthWithRefresh(fetchToken: () async => _accessToken);
      final transport = StampedPlatformTransport(client);
      final api = IcarusConvexApi(transport);
      await api.users.ensureCurrentUser(clientProtocolVersion: _protocol);

      final tree = api.folders.listTree(
        scope: const ConvexOptional.present(FoldersListTreeArgsScope.all),
      );
      final live = <Stamped<List<FoldersListTreeResultItem>>>[];
      final watching = tree.stampedOn(transport).watch().listen(live.add);
      final grouped = <Stamped<List<Object?>>>[];
      final groupWatching = StampedConvexQuery.watchTogether(
        transport,
        [tree, api.users.me()],
      ).listen(grouped.add);
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
      final generation = await transport.connectionGeneration();

      final results = [...reads, ...live, second];
      final stamps = [
        for (final result in results) result.stamp,
        for (final answer in answers.values) answer.stamp,
        for (final update in grouped) update.stamp,
      ];
      expect({for (final stamp in stamps) stamp.client}, hasLength(1));
      expect(
        {for (final stamp in stamps) stamp.connection},
        {generation},
        reason: 'a local deployment never drops the socket in this run',
      );
      expect(second.stamp.snapshot,
          greaterThanOrEqualTo(reads.last.stamp.snapshot));
      expect(_names(second).toSet().containsAll(everyName), isTrue);
      for (final a in results) {
        for (final b in results) {
          if (a.stamp.snapshot == b.stamp.snapshot) {
            expect(_names(a), _names(b), reason: 'one snapshot, one result');
          }
        }
      }
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
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: _deploymentUrl.isEmpty
        ? 'Run through tool/convex_client_gauntlet/runtime/tool/'
            'run_with_local_deployment.mjs'
        : false,
  );
}
