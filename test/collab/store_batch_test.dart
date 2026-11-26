import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/collab/src/convex_client_types.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus_library/icarus_library.dart';

const _stamp =
    ResultStamp(client: 2, connection: 3, snapshot: 41, serverTime: 4100);

const _point =
    ResultPoint(client: 2, connection: 3, snapshot: 41, serverTime: 4100);

final class _Recording implements StampedConvexTransport {
  final mutations = <(String, Map<String, Object?>)>[];
  Object? Function()? answer;

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) async {
    mutations.add((name, args.toDart()));
    return ConvexValue.fromDart(
      answer?.call() ?? {'results': <Object?>[], 'strategyPublicId': strategy},
    );
  }

  @override
  Future<Stamped<ConvexValue>> mutationStamped(
    String name,
    ConvexObject args,
  ) async {
    mutations.add((name, args.toDart()));
    try {
      final reply = answer?.call() ??
          {'results': <Object?>[], 'strategyPublicId': strategy};
      return StampedValue(ConvexValue.fromDart(reply), _stamp);
    } on ConvexFunctionException catch (error) {
      return StampedError(
        ConvexTransportError(
          rawCode: error.rawCode,
          message: error.message,
          data: error.data,
        ),
        _stamp,
      );
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const strategy = 'strategy-1';
const life = 1700000000000;
final owner = Account('account-a');

app.StrategyOp shippedRename(String opId) => app.StrategyPatchOp(
      opId: opId,
      payload: const {'name': 'Renamed'},
      expectedStrategyRevision: 2,
    );

StrategyPatchOp rename(String opId) =>
    StrategyPatchOp(opId: opId, expectedStrategyRevision: 2, name: 'Renamed');

void main() {
  group('the store\'s batch goes out on the shipped call', () {
    late _Recording transport;
    late ConvexStrategyRepository repository;

    setUp(() {
      transport = _Recording();
      repository = ConvexStrategyRepository.stamped(transport);
    });

    test(
        'with the shipped flags, the strategy\'s account, and the opt-in to '
        'ACCOUNT_MISMATCH', () async {
      await storeBatchSenderOver(repository)(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1')],
        lives: const {},
        strategyLife: 1,
        account: owner,
        serverTime: const ServerTimeNotAsked(),
      );
      final (name, args) = transport.mutations.single;
      expect(name, 'ops:applyBatch');
      expect(args['accountSubject'], 'account-a');
      expect(args['readsAccountMismatch'], true);
      expect(args['checkTrashedPageDeletes'], true);
      expect(args['acceptsPictureIds'], true);
      expect(args['includeWasApplied'], true);
      expect(args['clientId'], 'client-1');
      expect(
        [for (final op in args['ops']! as List) (op as Map)['opId']],
        ['op-1'],
      );
    });

    test('the shipped applyBatch does not opt in', () async {
      await repository.applyBatch(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [shippedRename('op-1')],
        accountSubject: 'account-a',
      );
      final (_, args) = transport.mutations.single;
      expect(args.containsKey('readsAccountMismatch'), isFalse);
      expect(args['accountSubject'], 'account-a');
      expect(args['includeWasApplied'], true);
    });

    test('the shipped applyBatch sends the arguments released builds send',
        () async {
      await repository.applyBatch(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [shippedRename('op-1')],
        accountSubject: 'account-a',
      );
      final (name, args) = transport.mutations.single;
      expect(name, 'ops:applyBatch');
      expect(args, {
        'acceptsPictureIds': true,
        'accountSubject': 'account-a',
        'checkTrashedPageDeletes': true,
        'clientId': 'client-1',
        'clientProtocolVersion': app.currentCloudProtocolVersion.toDouble(),
        'elementFieldLevel': app.currentElementFieldLevel.toDouble(),
        'includeWasApplied': true,
        'ops': [
          {
            'type': 'strategy.patch',
            'expectedStrategyRevision': 2.0,
            'opId': 'op-1',
            'payload': {'name': 'Renamed'},
          },
        ],
        'strategyPublicId': strategy,
      });
    });

    test('both paths send the same arguments besides the opt-in', () async {
      await repository.applyBatch(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [shippedRename('op-1')],
        accountSubject: 'account-a',
      );
      await storeBatchSenderOver(repository)(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1')],
        lives: const {},
        strategyLife: null,
        account: owner,
        serverTime: const ServerTimeNotAsked(),
      );
      final [(_, shipped), (_, store)] = transport.mutations;
      expect(
        {...store}
          ..remove('readsAccountMismatch')
          ..remove('sendsLives'),
        shipped,
      );
    });

    test('an answer is read as the queue\'s answer', () async {
      transport.answer = () => {
            'results': [
              {
                'opId': 'op-1',
                'status': 'applied',
                'appliedRevision': 3,
                'appliedLife': life,
              },
            ],
            'strategyPublicId': strategy,
          };
      final outcome = await storeBatchSenderOver(repository)(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1')],
        lives: const {},
        strategyLife: 1,
        account: owner,
        serverTime: const ServerTimeNotAsked(),
      );
      expect(
        outcome,
        isA<StoreBatchAnswered>()
            .having((o) => o.complete, 'complete', isTrue)
            .having(
              (o) => o.answers.single,
              'answer',
              isA<AppliedAnswer>().having((a) => a.revision, 'revision', 3),
            ),
      );
    });

    test(
        'opts in to lives, names the life of each op the queue gave one, and '
        'reads the lives the server answers with', () async {
      transport.answer = () => {
            'results': [
              {
                'opId': 'op-1',
                'status': 'applied',
                'appliedRevision': 3,
                'appliedLife': life,
              },
              {
                'opId': 'op-2',
                'status': 'noop',
                'currentRevision': 3,
                'currentLife': life,
              },
              {
                'opId': 'op-3',
                'status': 'rejected',
                'reason': 'row_replaced',
                'current': {
                  'type': 'page',
                  'revision': 1,
                  'life': 1800000000000,
                  'value': {'name': 'A', 'sortIndex': 0, 'isAttack': true},
                },
              },
              {'opId': 'op-4', 'status': 'rejected', 'reason': 'row_replaced'},
            ],
            'strategyPublicId': strategy,
          };
      final outcome = await storeBatchSenderOver(repository)(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1'), rename('op-2'), rename('op-3'), rename('op-4')],
        lives: const {'op-1': 1700000000101, 'op-3': 1700000000303},
        strategyLife: 1700000000999,
        account: owner,
        serverTime: const ServerTimeNotAsked(),
      );
      final (_, args) = transport.mutations.single;
      expect(args['sendsLives'], true);
      expect(args['strategyLife'], 1700000000999);
      expect(
        [for (final op in args['ops']! as List) (op as Map)['expectedLife']],
        [1700000000101, null, 1700000000303, null],
      );
      if (outcome is StoreBatchLost) fail(outcome.why);
      final answers = (outcome as StoreBatchAnswered).answers;
      expect(
        answers[0],
        isA<AppliedAnswer>().having((a) => a.life, 'life', 1700000000000),
      );
      expect(
        answers[1],
        isA<NoopAnswer>().having((a) => a.life, 'life', 1700000000000),
      );
      expect(
        answers[2],
        isA<RejectedAnswer>()
            .having((a) => a.reason, 'reason', RejectionReason.rowReplaced)
            .having(
              (a) => a.current,
              'current',
              isA<ServerSnapshot>()
                  .having((c) => c.life, 'life', 1800000000000),
            ),
      );
      expect(
        answers[3],
        isA<RejectedAnswer>()
            .having((a) => a.reason, 'reason', RejectionReason.rowReplaced)
            .having((a) => a.current, 'current', isA<NoServerCopy>()),
      );
    });

    test('a thrown refusal is read as the queue\'s verdict', () async {
      transport.answer = () => throw const ConvexFunctionException(
            code: ConvexErrorCode.accountMismatch,
            rawCode: 'ACCOUNT_MISMATCH',
            message: 'Forbidden: signed in as a different account',
          );
      expect(
        await storeBatchSenderOver(repository)(
          strategyPublicId: strategy,
          clientId: 'client-1',
          ops: [rename('op-1')],
          lives: const {},
          strategyLife: 1,
          account: owner,
          serverTime: const ServerTimeNotAsked(),
        ),
        isA<StoreBatchAccountMismatch>(),
      );
    });

    test(
        'not asking for the server\'s time sends neither the opt-in nor a '
        'basis', () async {
      await storeBatchSenderOver(repository)(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1')],
        lives: const {},
        strategyLife: 1,
        account: owner,
        serverTime: const ServerTimeNotAsked(),
      );
      final (_, args) = transport.mutations.single;
      expect(args.containsKey('sendsLiveBasis'), isFalse);
      expect(args.containsKey('liveBasis'), isFalse);
    });

    test(
        'asking for the server\'s time opts in, sends the basis when there is '
        'one, and reads the answer\'s server time', () async {
      transport.answer = () => {
            'results': [
              {
                'opId': 'op-1',
                'status': 'applied',
                'appliedRevision': 3,
                'appliedLife': life,
              },
            ],
            'strategyPublicId': strategy,
            'serverTime': 1764000000500.0,
          };
      final send = storeBatchSenderOver(repository);
      final withBasis = await send(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1')],
        lives: const {},
        strategyLife: 1,
        account: owner,
        serverTime: const ServerTimeAsked(basis: 1764000000000),
      );
      await send(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-2')],
        lives: const {},
        strategyLife: 1,
        account: owner,
        serverTime: const ServerTimeAsked(),
      );
      final [(_, first), (_, second)] = transport.mutations;
      expect(first['sendsLiveBasis'], true);
      expect(first['liveBasis'], 1764000000000);
      expect(second['sendsLiveBasis'], true);
      expect(second.containsKey('liveBasis'), isFalse);
      expect(
        withBasis,
        isA<StoreBatchAnswered>()
            .having((o) => o.serverTime, 'serverTime', 1764000000500),
      );
    });

    test('an empty batch is refused before any call', () async {
      await expectLater(
        storeBatchSenderOver(repository)(
          strategyPublicId: strategy,
          clientId: 'client-1',
          ops: const [],
          lives: const {},
          strategyLife: null,
          account: owner,
          serverTime: const ServerTimeNotAsked(),
        ),
        throwsArgumentError,
      );
      expect(transport.mutations, isEmpty);
    });
  });

  group('the server\'s answers as the queue reads them', () {
    test(
        'an answer without a life is its own answer for that op, applied, '
        'replayed or rejected with a copy, and the batch\'s other answers '
        'are kept', () {
      for (final (ack, revision) in [
        (
          const app.NoopOpAck(opId: 'a', currentRevision: 4, wasApplied: true),
          4,
        ),
        (const app.NoopOpAck(opId: 'a', currentRevision: 4), 4),
        (const app.AppliedOpAck(opId: 'a', revision: 4), 4),
        (
          const app.RejectedOpAck(
            opId: 'a',
            rejectionReason: app.OpRejectionReason.revisionMismatch,
            current: app.ElementCurrentSnapshot(
              revision: 5,
              value: {'payload': {}},
            ),
          ),
          5,
        ),
      ]) {
        expect(
          storeAnswerOf(ack),
          isA<AnswerWithoutLife>()
              .having((answer) => answer.revision, 'revision', revision),
        );
      }
      final outcome = storeBatchOutcomeOf(
        [rename('a'), rename('b')],
        [
          const app.AppliedOpAck(opId: 'a', revision: 4),
          const app.AppliedOpAck(opId: 'b', revision: 3, life: life),
        ],
        point: _point,
      );
      expect(
        (outcome as StoreBatchAnswered).answers,
        [
          isA<AnswerWithoutLife>(),
          isA<AppliedAnswer>().having((answer) => answer.life, 'life', life),
        ],
      );
      expect(outcome.complete, isTrue);
    });

    test('applied, changed nothing, rejected and failed', () {
      expect(
        storeAnswerOf(
            const app.AppliedOpAck(opId: 'a', revision: 4, life: life)),
        isA<AppliedAnswer>().having((answer) => answer.revision, 'rev', 4),
      );
      expect(
        storeAnswerOf(
          const app.NoopOpAck(
            opId: 'a',
            currentRevision: 4,
            currentLife: life,
            wasApplied: true,
          ),
        ),
        isA<NoopAnswer>().having(
          (answer) => answer.replay,
          'replay',
          NoopReplay.appliedWhenFirstReceived,
        ),
      );
      expect(
        storeAnswerOf(const app.NoopOpAck(opId: 'a')),
        isA<NoopWithoutRevision>(),
      );
      expect(
        storeAnswerOf(
          const app.RejectedOpAck(
            opId: 'a',
            rejectionReason: app.OpRejectionReason.revisionMismatch,
            current: app.ElementCurrentSnapshot(
              revision: 5,
              life: life,
              value: {'payload': {}},
            ),
          ),
        ),
        isA<RejectedAnswer>()
            .having(
              (answer) => answer.reason,
              'reason',
              RejectionReason.revisionMismatch,
            )
            .having(
              (answer) => answer.current,
              'current',
              isA<ServerSnapshot>().having(
                (snapshot) => snapshot.target,
                'target',
                SnapshotTarget.element,
              ),
            ),
      );
      expect(
        storeAnswerOf(
          const app.FailedOpAck(
            opId: 'a',
            code: 'PAGE_DELETED',
            rawCode: 'PAGE_DELETED',
            message: 'gone',
          ),
        ),
        isA<FailedAnswer>().having(
          (answer) => answer.code,
          'code',
          const KnownFailure(FailureCode.pageDeleted),
        ),
      );
    });

    test('an answer for an op the batch did not send, or one missing, is named',
        () {
      final sent = [rename('a'), rename('b')];
      expect(
        storeBatchOutcomeOf(
            sent,
            const [
              app.AppliedOpAck(opId: 'a', revision: 2, life: life),
            ],
            point: _point),
        isA<StoreBatchAnswered>().having(
          (outcome) => outcome.complete,
          'complete',
          false,
        ),
      );
      expect(
        storeBatchOutcomeOf(
            sent,
            const [
              app.AppliedOpAck(opId: 'z', revision: 2, life: life),
            ],
            point: _point),
        isA<StoreBatchLost>().having(
          (outcome) => outcome.failure,
          'failure',
          TransportFailure.malformedAnswer,
        ),
      );
    });

    test(
        'STRATEGY_REPLACED carries the life the server names, from the '
        'desktop and the web clients, and none when an older server sends '
        'none', () {
      const life = 1795176055837;
      int? named(Object error) =>
          switch (storeBatchOutcomeOfError(error, point: _point)) {
            StoreBatchRefusedWhole(
              refusal: BatchRefusal.strategyReplaced,
              :final currentLife,
            ) =>
              currentLife,
            final other => fail('expected a replaced refusal, got $other'),
          };
      ConvexFunctionException desktop(ConvexValue? data) =>
          ConvexFunctionException(
            code: ConvexErrorCode.strategyReplaced,
            rawCode: 'STRATEGY_REPLACED',
            message: 'replaced',
            data: data,
          );
      expect(
        named(
          desktop(
            ConvexObject({
              'code': const ConvexString('STRATEGY_REPLACED'),
              'currentLife': const ConvexInteger(life),
            }),
          ),
        ),
        life,
      );
      expect(
        named(
          desktop(
            ConvexObject({
              'code': const ConvexString('STRATEGY_REPLACED'),
              'currentLife': ConvexFloat(life.toDouble()),
            }),
          ),
        ),
        life,
      );
      expect(
        named(
          const ConvexClientFunctionError(
            rawCode: 'STRATEGY_REPLACED',
            message: 'replaced',
            data: {'code': 'STRATEGY_REPLACED', 'currentLife': life},
          ),
        ),
        life,
      );
      expect(named(desktop(null)), isNull);
      for (final past in [
        const ConvexInteger(9007199254740992),
        const ConvexFloat(9007199254740992.0),
      ]) {
        expect(
          named(
            desktop(
              ConvexObject({
                'code': const ConvexString('STRATEGY_REPLACED'),
                'currentLife': past,
              }),
            ),
          ),
          isNull,
          reason: 'a life past the largest whole number JavaScript holds '
              'exactly, as ${past.runtimeType}',
        );
      }
      for (final notATime in [
        const ConvexInteger(0),
        const ConvexInteger(-1),
        const ConvexInteger(-9223372036854775808),
        const ConvexFloat(-1795613794067.0),
      ]) {
        expect(
          named(
            desktop(
              ConvexObject({
                'code': const ConvexString('STRATEGY_REPLACED'),
                'currentLife': notATime,
              }),
            ),
          ),
          isNull,
          reason: 'a life is a creation time, so it is above zero; '
              'got ${notATime.runtimeType}',
        );
      }
      expect(
        named(
          desktop(
            ConvexObject({
              'code': const ConvexString('STRATEGY_REPLACED'),
              'currentLife': const ConvexFloat(1.5),
            }),
          ),
        ),
        isNull,
      );
      expect(
        named(
          desktop(
            ConvexObject({
              'code': const ConvexString('STRATEGY_REPLACED'),
              'currentLife': const ConvexString('soon'),
            }),
          ),
        ),
        isNull,
      );
    });

    test('each refusal code has one meaning to the queue', () {
      StoreBatchOutcome of(String code) => storeBatchOutcomeOfError(
            ConvexFunctionException(
              code: ConvexErrorCode.fromWireName(code),
              rawCode: code,
              message: 'refused',
            ),
            point: _point,
          );
      Matcher refused(BatchRefusal refusal) =>
          isA<StoreBatchRefusedWhole>().having((o) => o.refusal, 'r', refusal);
      expect(of('UNAUTHENTICATED'), refused(BatchRefusal.unauthenticated));
      expect(
        of('CLIENT_UPGRADE_REQUIRED'),
        refused(BatchRefusal.upgradeRequired),
      );
      expect(of('STRATEGY_REPLACED'), refused(BatchRefusal.strategyReplaced));
      expect(of('FORBIDDEN'), refused(BatchRefusal.editAccessRemoved));
      expect(of('NOT_FOUND'), refused(BatchRefusal.strategyDeleted));
      expect(of('ACCOUNT_MISMATCH'), isA<StoreBatchAccountMismatch>());
      expect(of('UNCHECKED_OUTSIDE_WINDOW'), isA<StoreBatchOutsideWindow>());
      expect(
        of('RATE_LIMITED'),
        isA<StoreBatchLost>().having(
          (o) => o.failure,
          'failure',
          TransportFailure.network,
        ),
      );
      expect(
        storeBatchOutcomeOfError(TimeoutException('slow'), point: null),
        isA<StoreBatchLost>().having(
          (o) => o.failure,
          'failure',
          TransportFailure.timeout,
        ),
      );
      expect(
        storeBatchOutcomeOfError(const FormatException('bad'), point: null),
        isA<StoreBatchLost>().having(
          (o) => o.failure,
          'failure',
          TransportFailure.malformedAnswer,
        ),
      );
    });
  });
}
