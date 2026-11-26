import 'dart:convert';
import 'dart:typed_data';

import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/collab/generated/icarus_convex_api.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

const releasedStrategy = 'strategy-1';
const releasedClient = 'client-1';
const releasedAccount = 'account-a';

final class ArgumentsRecorder implements ConvexTransport {
  final calls = <(String, ConvexObject)>[];

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) async {
    calls.add((name, args));
    return ConvexValue.fromDart({
      'results': <Object?>[],
      'strategyPublicId': releasedStrategy,
      'serverTime': 1795000000000.0,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

typedef ReleasedCase = ({
  String name,
  Future<void> Function(ConvexStrategyRepository repository) send,
});

final _payload = <String, dynamic>{
  'kind': 'agent',
  'payloadVersion': 2,
  'data': {
    'id': 'jett',
    'elementType': 'agent',
    'position': {'x': 1.5, 'y': 2.0},
  },
};

final _lineup = <String, dynamic>{
  'kind': 'lineups',
  'payloadVersion': 1,
  'data': {'id': 'g1', 'links': <Object?>[]},
};

final _settings = <String, dynamic>{
  'agentSize': 34.5,
  'abilitySize': 20,
  'useNeutralTeamColors': false,
};

final releasedOps = <String, app.StrategyOp>{
  'strategy.patch': const app.StrategyPatchOp(
    opId: 'op-strategy-patch',
    payload: {
      'name': 'Renamed',
      'mapData': 'bind',
      'themeProfileId': 'ember',
      'themeOverridePalette': {
        'base': '#101010',
        'detail': '#202020',
        'highlight': '#303030',
      },
    },
    expectedStrategyRevision: 2,
  ),
  'page.add': app.PageAddOp(
    opId: 'op-page-add',
    pagePublicId: 'page-2',
    payload: {
      'name': 'Page 2',
      'isAttack': true,
      'isAutoNamed': false,
      'settings': _settings,
    },
    sortIndex: 1,
    expectedStrategyRevision: 3,
  ),
  'page.add copying a page': const app.PageAddOp(
    opId: 'op-page-copy',
    pagePublicId: 'page-3',
    payload: {'name': 'Page 3', 'isAttack': false},
    sortIndex: 2,
    expectedStrategyRevision: 4,
    copyContentFromPagePublicId: 'page-1',
  ),
  'page.patch': const app.PagePatchOp(
    opId: 'op-page-patch',
    pagePublicId: 'page-1',
    payload: {'name': 'First'},
    expectedPageRevision: 5,
  ),
  'page.delete': const app.PageDeleteOp(
    opId: 'op-page-delete',
    pagePublicId: 'page-2',
    expectedStrategyRevision: 6,
  ),
  'page.reorder': const app.PageReorderOp(
    opId: 'op-page-reorder',
    pagePublicId: 'page-1',
    sortIndex: 3,
    expectedStrategyRevision: 7,
  ),
  'page.content.patch': app.PageContentPatchOp(
    opId: 'op-page-content',
    pagePublicId: 'page-1',
    settings: _settings,
    expectedPageContentRevision: 8,
  ),
  'element.add': app.ElementAddOp(
    opId: 'op-element-add',
    elementPublicId: 'element-1',
    pagePublicId: 'page-1',
    payload: _payload,
    sortIndex: 4,
  ),
  'element.add over a revision': app.ElementAddOp(
    opId: 'op-element-readd',
    elementPublicId: 'element-2',
    pagePublicId: 'page-1',
    payload: _payload,
    sortIndex: 5,
    expectedElementRevision: 9,
  ),
  'element.patch whole': app.ElementPatchOp(
    opId: 'op-element-patch',
    elementPublicId: 'element-1',
    expectedElementRevision: 10,
    pagePublicId: 'page-1',
    payload: _payload,
    sortIndex: 6,
  ),
  'element.patch field merge': app.ElementPatchOp(
    opId: 'op-element-merge',
    elementPublicId: 'element-1',
    expectedElementRevision: 11,
    payload: _payload,
    merge: const FieldMerge(fields: ['position', '@sortIndex']),
  ),
  'element.patch field merge with a base': app.ElementPatchOp(
    opId: 'op-element-merge-base',
    elementPublicId: 'element-1',
    expectedElementRevision: 12,
    payload: _payload,
    merge: const FieldMerge(
      fields: ['position'],
      base: {
        'position': {'x': 1.0, 'y': 1},
      },
    ),
  ),
  'element.delete': const app.ElementDeleteOp(
    opId: 'op-element-delete',
    elementPublicId: 'element-1',
    pagePublicId: 'page-1',
    expectedElementRevision: 13,
  ),
  'element.delete last writer wins': const app.ElementDeleteOp(
    opId: 'op-element-delete-lww',
    elementPublicId: 'element-2',
    pagePublicId: 'page-1',
    expectedElementRevision: 14,
    lastWriterWins: true,
  ),
  'element.reorder': const app.ElementReorderOp(
    opId: 'op-element-reorder',
    elementPublicId: 'element-1',
    pagePublicId: 'page-1',
    sortIndex: 7,
    expectedElementRevision: 15,
  ),
  'lineup.add': app.LineupAddOp(
    opId: 'op-lineup-add',
    lineupPublicId: 'lineup-1',
    pagePublicId: 'page-1',
    payload: _lineup,
    sortIndex: 8,
  ),
  'lineup.patch': app.LineupPatchOp(
    opId: 'op-lineup-patch',
    lineupPublicId: 'lineup-1',
    expectedLineupRevision: 16,
    payload: _lineup,
  ),
  'lineup.patch field merge': app.LineupPatchOp(
    opId: 'op-lineup-merge',
    lineupPublicId: 'lineup-1',
    expectedLineupRevision: 17,
    payload: _lineup,
    merge: const FieldMerge(fields: ['position']),
  ),
  'lineup.delete': const app.LineupDeleteOp(
    opId: 'op-lineup-delete',
    lineupPublicId: 'lineup-1',
    pagePublicId: 'page-1',
    expectedLineupRevision: 18,
  ),
  'lineup.reorder': const app.LineupReorderOp(
    opId: 'op-lineup-reorder',
    lineupPublicId: 'lineup-1',
    pagePublicId: 'page-1',
    sortIndex: 9,
    expectedLineupRevision: 19,
  ),
};

List<ReleasedCase> releasedCases() => [
      for (final MapEntry(key: shape, value: op) in releasedOps.entries) ...[
        (
          name: 'applyBatch, $shape, with the account subject',
          send: (repository) => repository.applyBatch(
                strategyPublicId: releasedStrategy,
                clientId: releasedClient,
                ops: [op],
                accountSubject: releasedAccount,
              ),
        ),
        (
          name: 'applyBatch, $shape, without an account subject',
          send: (repository) => repository.applyBatch(
                strategyPublicId: releasedStrategy,
                clientId: releasedClient,
                ops: [op],
              ),
        ),
      ],
      (
        name: 'applyBatch, every shape in one batch, with the account subject',
        send: (repository) => repository.applyBatch(
              strategyPublicId: releasedStrategy,
              clientId: releasedClient,
              ops: releasedOps.values.toList(),
              accountSubject: releasedAccount,
            ),
      ),
      (
        name: 'sendWithLiveBasis, a field merge, with a basis',
        send: (repository) => repository.sendWithLiveBasis(
              strategyPublicId: releasedStrategy,
              clientId: releasedClient,
              ops: [releasedOps['element.patch field merge']!],
              liveBasis: 1795000000000.0,
            ),
      ),
      (
        name: 'sendWithLiveBasis, a field merge, without a basis',
        send: (repository) => repository.sendWithLiveBasis(
              strategyPublicId: releasedStrategy,
              clientId: releasedClient,
              ops: [releasedOps['element.patch field merge']!],
            ),
      ),
      for (final reads in [true, false])
        (
          name: 'sendEmptyBatch, reading ACCOUNT_MISMATCH: $reads',
          send: (repository) => repository.sendEmptyBatch(
                strategyPublicId: releasedStrategy,
                accountSubject: releasedAccount,
                readsAccountMismatch: reads,
              ),
        ),
    ];

String? encodedSpecially(Object? value) => switch (value) {
      BigInt() => 'a BigInt',
      Uint8List() => 'bytes',
      double() when !value.isFinite || (value == 0 && value.isNegative) =>
        'the float $value',
      List() => value.map(encodedSpecially).nonNulls.firstOrNull,
      Map() => value.values.map(encodedSpecially).nonNulls.firstOrNull,
      _ => null,
    };

typedef ReleasedCall = ({
  String name,
  ConvexObject args,
});

Future<ReleasedCall> releasedCall(ReleasedCase released) async {
  final recorder = ArgumentsRecorder();
  await released.send(ConvexStrategyRepository(IcarusConvexApi(recorder)));
  final (name, args) = recorder.calls.single;
  return (name: name, args: args);
}

Map<String, Object?> recordingOf(String name, ReleasedCall call) => {
      'case': name,
      'function': call.name,
      'arguments': [
        for (final MapEntry(:key, :value) in call.args.toDart().entries)
          [key, jsonEncode(value)],
      ],
    };

Future<List<Map<String, Object?>>> recordReleased() async => [
      for (final released in releasedCases())
        recordingOf(released.name, await releasedCall(released)),
    ];
