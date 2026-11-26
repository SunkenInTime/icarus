import 'dart:async';

import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart'
    show ConvexFunctionException;
import 'package:icarus/collab/store_reads.dart' show pointOf;
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/collab/src/convex_client_types.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus_library/icarus_library.dart' as store;

sealed class StoreBatchOutcome {
  const StoreBatchOutcome();
}

final class StoreBatchAnswered extends StoreBatchOutcome {
  StoreBatchAnswered(
    List<store.OpAnswer> answers, {
    required this.complete,
    required this.point,
    this.serverTime,
  }) : answers = List.unmodifiable(answers);

  final List<store.OpAnswer> answers;
  final bool complete;
  final store.ResultPoint point;
  final int? serverTime;
}

final class StoreBatchRefusedWhole extends StoreBatchOutcome {
  const StoreBatchRefusedWhole(
    this.refusal, {
    required this.point,
    this.currentLife,
  });

  final store.BatchRefusal refusal;
  final store.ResultPoint point;
  final int? currentLife;
}

final class StoreBatchLost extends StoreBatchOutcome {
  const StoreBatchLost(this.failure, this.why);

  final store.TransportFailure failure;
  final String why;
}

final class StoreBatchAccountMismatch extends StoreBatchOutcome {
  const StoreBatchAccountMismatch(this.why, {required this.point});

  final String why;
  final store.ResultPoint point;
}

final class StoreBatchOutsideWindow extends StoreBatchOutcome {
  const StoreBatchOutsideWindow(this.why, {required this.point});

  final String why;
  final store.ResultPoint point;
}

sealed class ServerTimeAsk {
  const ServerTimeAsk();
}

final class ServerTimeNotAsked extends ServerTimeAsk {
  const ServerTimeNotAsked();
}

final class ServerTimeAsked extends ServerTimeAsk {
  const ServerTimeAsked({this.basis});

  final int? basis;
}

typedef StoreBatchSend = Future<StoreBatchOutcome> Function({
  required String strategyPublicId,
  required String clientId,
  required List<store.StrategyOp> ops,
  required Map<String, int> lives,
  required int? strategyLife,
  required store.Account account,
  required ServerTimeAsk serverTime,
});

StoreBatchSend storeBatchSenderOver(ConvexStrategyRepository repository) => ({
      required strategyPublicId,
      required clientId,
      required ops,
      required lives,
      required strategyLife,
      required account,
      required serverTime,
    }) async {
      if (ops.isEmpty) {
        throw ArgumentError.value(ops, 'ops', 'a batch sends at least one op');
      }
      final Stamped<({List<OpAck> acks, double? serverTime})> answer;
      try {
        answer = await repository.applyWireBatchStamped(
          strategyPublicId: strategyPublicId,
          clientId: clientId,
          ops: [
            for (final op in ops)
              {
                ...op.toJson(),
                if (lives[op.opId] case final life?) 'expectedLife': life,
              },
          ],
          strategyLife: strategyLife,
          accountSubject: account.subject,
          sendsLiveBasis: serverTime is ServerTimeAsked,
          liveBasis: switch (serverTime) {
            ServerTimeAsked(:final basis?) => basis.toDouble(),
            _ => null,
          },
        );
      } catch (error) {
        return storeBatchOutcomeOfError(error, point: null);
      }
      return switch (answer) {
        StampedValue(:final value, :final stamp) => storeBatchOutcomeOf(
            ops,
            value.acks,
            point: pointOf(stamp),
            serverTime: value.serverTime?.toInt(),
          ),
        StampedError(:final error, :final stamp) => storeBatchOutcomeOfError(
            ConvexFunctionException.fromTransport(error),
            point: pointOf(stamp),
          ),
      };
    };

StoreBatchOutcome storeBatchOutcomeOf(
  List<store.StrategyOp> sent,
  List<OpAck> acks, {
  required store.ResultPoint point,
  int? serverTime,
}) {
  final sentIds = {for (final op in sent) op.opId};
  final answers = <store.OpAnswer>[];
  for (final ack in acks) {
    if (!sentIds.contains(ack.opId)) {
      return StoreBatchLost(
        store.TransportFailure.malformedAnswer,
        'the server answered ${ack.opId}, which this batch did not send',
      );
    }
    final answer = storeAnswerOf(ack);
    if (answer == null) {
      return StoreBatchLost(
        store.TransportFailure.malformedAnswer,
        'the server answered ${ack.opId} in a form the queue does not read',
      );
    }
    answers.add(answer);
  }
  final answered = {for (final answer in answers) answer.opId};
  return StoreBatchAnswered(
    answers,
    complete: sentIds.every(answered.contains),
    point: point,
    serverTime: serverTime,
  );
}

store.OpAnswer? storeAnswerOf(OpAck ack) => switch (ack) {
      AppliedOpAck(:final opId, :final revision, life: final life?) =>
        store.AppliedAnswer(opId, revision: revision, life: life),
      AppliedOpAck(:final opId, :final revision) =>
        store.AnswerWithoutLife(opId, revision: revision),
      NoopOpAck(
        :final opId,
        currentRevision: final revision?,
        currentLife: final life?,
        :final wasApplied
      ) =>
        store.NoopAnswer(
          opId,
          revision: revision,
          life: life,
          replay: _replayOf(wasApplied),
        ),
      NoopOpAck(:final opId, currentRevision: final revision?) =>
        store.AnswerWithoutLife(opId, revision: revision),
      NoopOpAck(:final opId) => store.NoopWithoutRevision(opId),
      RejectedOpAck(:final opId, :final rejectionReason, :final current) =>
        switch ((_rejectionOf(rejectionReason), _copyOf(current))) {
          (final reason?, final copy?) =>
            store.RejectedAnswer(opId, reason, copy),
          (_?, null) =>
            store.AnswerWithoutLife(opId, revision: current?.revision),
          (null, _) => null,
        },
      FailedOpAck(:final opId, :final code, :final rawCode, :final message) =>
        store.FailedAnswer(
            opId,
            switch (store.FailureCode.values
                .where((known) =>
                    known.wireName == rawCode || known.wireName == code)
                .firstOrNull) {
              final known? => store.KnownFailure(known),
              null => store.OtherFailure(rawCode),
            },
            message),
    };

store.ServerCopy? _copyOf(CurrentOpSnapshot? current) => switch (current) {
      null => const store.NoServerCopy(),
      CurrentOpSnapshot(life: null) => null,
      CurrentOpSnapshot(:final revision, :final life?, :final value) =>
        store.ServerSnapshot(
          target: switch (current) {
            StrategyCurrentSnapshot() => store.SnapshotTarget.strategy,
            PageCurrentSnapshot() => store.SnapshotTarget.page,
            PageContentCurrentSnapshot() => store.SnapshotTarget.pageContent,
            ElementCurrentSnapshot() => store.SnapshotTarget.element,
            LineupCurrentSnapshot() => store.SnapshotTarget.lineup,
          },
          revision: revision,
          life: life,
          value: value,
        ),
    };

store.NoopReplay _replayOf(bool wasApplied) => wasApplied
    ? store.NoopReplay.appliedWhenFirstReceived
    : store.NoopReplay.notApplied;

store.RejectionReason? _rejectionOf(OpRejectionReason reason) =>
    store.RejectionReason.values
        .where((known) => known.wireName == reason.wireName)
        .firstOrNull;

int? _currentLifeIn(Object error) => switch (switch (error) {
      ConvexFunctionException(:final data?) => data.toDart(),
      ConvexClientFunctionError(:final data) => data,
      _ => null,
    }) {
      {'currentLife': final num life}
          when life.isFinite &&
              life == life.truncate() &&
              life > 0 &&
              life <= _largestSafeWhole =>
        life.toInt(),
      _ => null,
    };

const _largestSafeWhole = 9007199254740991;

StoreBatchOutcome storeBatchOutcomeOfError(
  Object error, {
  required store.ResultPoint? point,
}) {
  if (point != null && isAccountMismatchError(error)) {
    return StoreBatchAccountMismatch('$error', point: point);
  }
  if (point != null && isUncheckedOutsideWindowError(error)) {
    return StoreBatchOutsideWindow('$error', point: point);
  }
  final refusal = switch (error) {
    _ when isClientUpgradeRequiredError(error) =>
      store.BatchRefusal.upgradeRequired,
    _ when isTypedConvexUnauthenticatedError(error) =>
      store.BatchRefusal.unauthenticated,
    _ when isTypedConvexForbiddenError(error) =>
      store.BatchRefusal.editAccessRemoved,
    _ when isTypedConvexNotFoundError(error) =>
      store.BatchRefusal.strategyDeleted,
    _ when isStrategyReplacedError(error) =>
      store.BatchRefusal.strategyReplaced,
    _ => null,
  };
  if ((refusal, point) case (final refusal?, final point?)) {
    return StoreBatchRefusedWhole(
      refusal,
      point: point,
      currentLife: refusal == store.BatchRefusal.strategyReplaced
          ? _currentLifeIn(error)
          : null,
    );
  }
  if (error is TimeoutException) {
    return StoreBatchLost(store.TransportFailure.timeout, '$error');
  }
  if (error is FormatException || error is ConvexNormalizationError) {
    return StoreBatchLost(store.TransportFailure.malformedAnswer, '$error');
  }
  return StoreBatchLost(store.TransportFailure.network, '$error');
}
