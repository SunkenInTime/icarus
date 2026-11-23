import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/collab/generated/icarus_convex_api.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus_library/icarus_library.dart';

final class _Recording implements ConvexTransport {
  final mutations = <(String, Map<String, Object?>)>[];
  Object? Function()? answer;

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) async {
    mutations.add((name, args.toDart()));
    final reply = answer?.call() ??
        {'results': <Object?>[], 'strategyPublicId': strategy};
    return ConvexValue.fromDart(reply);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const strategy = 'strategy-1';
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
      repository = ConvexStrategyRepository(IcarusConvexApi(transport));
    });

    test(
        'with the shipped flags, the strategy\'s account, and the opt-in to '
        'ACCOUNT_MISMATCH', () async {
      await storeBatchSenderOver(repository)(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1')],
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

    test('both paths send the same arguments besides the opt-in', () async {
      await repository.applyBatch(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [shippedRename('op-1')],
        accountSubject: 'account-a',
      );
      await repository.applyWireBatch(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1').toJson()],
        accountSubject: 'account-a',
      );
      final [(_, shipped), (_, wire)] = transport.mutations;
      expect(
        {...wire}..remove('readsAccountMismatch'),
        shipped,
      );
    });

    test('an answer is read as the queue\'s answer', () async {
      transport.answer = () => {
            'results': [
              {'opId': 'op-1', 'status': 'applied', 'appliedRevision': 3},
            ],
            'strategyPublicId': strategy,
          };
      final outcome = await storeBatchSenderOver(repository)(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1')],
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

    test('a thrown refusal is read as the queue\'s verdict', () async {
      transport.answer = () => throw ConvexFunctionException(
            code: ConvexErrorCode.accountMismatch,
            rawCode: 'ACCOUNT_MISMATCH',
            message: 'Forbidden: signed in as a different account',
          );
      expect(
        await storeBatchSenderOver(repository)(
          strategyPublicId: strategy,
          clientId: 'client-1',
          ops: [rename('op-1')],
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
              {'opId': 'op-1', 'status': 'applied', 'appliedRevision': 3},
            ],
            'strategyPublicId': strategy,
            'serverTime': 1764000000500.0,
          };
      final send = storeBatchSenderOver(repository);
      final withBasis = await send(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-1')],
        account: owner,
        serverTime: const ServerTimeAsked(basis: 1764000000000),
      );
      await send(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: [rename('op-2')],
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

    test('an empty batch makes no call', () async {
      await repository.applyWireBatch(
        strategyPublicId: strategy,
        clientId: 'client-1',
        ops: const [],
        accountSubject: 'account-a',
      );
      expect(transport.mutations, isEmpty);
    });
  });

  group('the server\'s answers as the queue reads them', () {
    test('applied, changed nothing, rejected and failed', () {
      expect(
        storeAnswerOf(const app.AppliedOpAck(opId: 'a', revision: 4)),
        isA<AppliedAnswer>().having((answer) => answer.revision, 'rev', 4),
      );
      expect(
        storeAnswerOf(
          const app.NoopOpAck(opId: 'a', currentRevision: 4, wasApplied: true),
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
          app.RejectedOpAck(
            opId: 'a',
            rejectionReason: app.OpRejectionReason.revisionMismatch,
            current: app.ElementCurrentSnapshot(
              revision: 5,
              value: const {'payload': {}},
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
        storeBatchOutcomeOf(sent, const [
          app.AppliedOpAck(opId: 'a', revision: 2),
        ]),
        isA<StoreBatchAnswered>().having(
          (outcome) => outcome.complete,
          'complete',
          false,
        ),
      );
      expect(
        storeBatchOutcomeOf(sent, const [
          app.AppliedOpAck(opId: 'z', revision: 2),
        ]),
        isA<StoreBatchLost>().having(
          (outcome) => outcome.failure,
          'failure',
          TransportFailure.malformedAnswer,
        ),
      );
    });

    test('each refusal code has one meaning to the queue', () {
      StoreBatchOutcome of(String code) => storeBatchOutcomeOfError(
            ConvexFunctionException(
              code: ConvexErrorCode.fromWireName(code),
              rawCode: code,
              message: 'refused',
            ),
          );
      Matcher refused(BatchRefusal refusal) =>
          isA<StoreBatchRefusedWhole>().having((o) => o.refusal, 'r', refusal);
      expect(of('UNAUTHENTICATED'), refused(BatchRefusal.unauthenticated));
      expect(
        of('CLIENT_UPGRADE_REQUIRED'),
        refused(BatchRefusal.upgradeRequired),
      );
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
        storeBatchOutcomeOfError(TimeoutException('slow')),
        isA<StoreBatchLost>().having(
          (o) => o.failure,
          'failure',
          TransportFailure.timeout,
        ),
      );
      expect(
        storeBatchOutcomeOfError(const FormatException('bad')),
        isA<StoreBatchLost>().having(
          (o) => o.failure,
          'failure',
          TransportFailure.malformedAnswer,
        ),
      );
    });
  });
}
