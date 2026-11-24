import 'dart:async';

import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus_library/icarus_library.dart' as store;

sealed class StoreBatchOutcome {
  const StoreBatchOutcome();
}

final class StoreBatchAnswered extends StoreBatchOutcome {
  StoreBatchAnswered(
    List<store.OpAnswer> answers, {
    required this.complete,
    this.serverTime,
  }) : answers = List.unmodifiable(answers);

  final List<store.OpAnswer> answers;
  final bool complete;
  final int? serverTime;
}

final class StoreBatchRefusedWhole extends StoreBatchOutcome {
  const StoreBatchRefusedWhole(this.refusal);

  final store.BatchRefusal refusal;
}

final class StoreBatchLost extends StoreBatchOutcome {
  const StoreBatchLost(this.failure, this.why);

  final store.TransportFailure failure;
  final String why;
}

final class StoreBatchAccountMismatch extends StoreBatchOutcome {
  const StoreBatchAccountMismatch(this.why);

  final String why;
}

final class StoreBatchOutsideWindow extends StoreBatchOutcome {
  const StoreBatchOutsideWindow(this.why);

  final String why;
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
  required store.Account account,
  required ServerTimeAsk serverTime,
});

StoreBatchSend storeBatchSenderOver(ConvexStrategyRepository repository) => ({
      required strategyPublicId,
      required clientId,
      required ops,
      required lives,
      required account,
      required serverTime,
    }) async {
      final ({List<OpAck> acks, double? serverTime}) answer;
      try {
        answer = await repository.applyWireBatch(
          strategyPublicId: strategyPublicId,
          clientId: clientId,
          ops: [
            for (final op in ops)
              {
                ...op.toJson(),
                if (lives[op.opId] case final life?) 'expectedLife': life,
              },
          ],
          sendsLives: true,
          accountSubject: account.subject,
          sendsLiveBasis: serverTime is ServerTimeAsked,
          liveBasis: switch (serverTime) {
            ServerTimeAsked(:final basis?) => basis.toDouble(),
            _ => null,
          },
        );
      } catch (error) {
        return storeBatchOutcomeOfError(error);
      }
      return storeBatchOutcomeOf(
        ops,
        answer.acks,
        serverTime: answer.serverTime?.toInt(),
      );
    };

StoreBatchOutcome storeBatchOutcomeOf(
  List<store.StrategyOp> sent,
  List<OpAck> acks, {
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
    serverTime: serverTime,
  );
}

store.OpAnswer? storeAnswerOf(OpAck ack) => switch (ack) {
      AppliedOpAck(:final opId, :final revision, :final life) =>
        store.AppliedAnswer(opId, revision: revision, life: life),
      NoopOpAck(
        :final opId,
        currentRevision: final revision?,
        :final currentLife,
        :final wasApplied
      ) =>
        store.NoopAnswer(
          opId,
          revision: revision,
          life: currentLife,
          replay: wasApplied
              ? store.NoopReplay.appliedWhenFirstReceived
              : store.NoopReplay.notApplied,
        ),
      NoopOpAck(:final opId) => store.NoopWithoutRevision(opId),
      RejectedOpAck(:final opId, :final rejectionReason, :final current) =>
        switch (_rejectionOf(rejectionReason)) {
          final reason? => store.RejectedAnswer(
              opId,
              reason,
              switch (current) {
                null => const store.NoServerCopy(),
                final snapshot => store.ServerSnapshot(
                    target: switch (snapshot) {
                      StrategyCurrentSnapshot() =>
                        store.SnapshotTarget.strategy,
                      PageCurrentSnapshot() => store.SnapshotTarget.page,
                      PageContentCurrentSnapshot() =>
                        store.SnapshotTarget.pageContent,
                      ElementCurrentSnapshot() => store.SnapshotTarget.element,
                      LineupCurrentSnapshot() => store.SnapshotTarget.lineup,
                    },
                    revision: snapshot.revision,
                    life: snapshot.life,
                    value: snapshot.value,
                  ),
              }),
          null => null,
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

store.RejectionReason? _rejectionOf(OpRejectionReason reason) =>
    store.RejectionReason.values
        .where((known) => known.wireName == reason.wireName)
        .firstOrNull;

StoreBatchOutcome storeBatchOutcomeOfError(Object error) {
  if (isClientUpgradeRequiredError(error)) {
    return const StoreBatchRefusedWhole(store.BatchRefusal.upgradeRequired);
  }
  if (isTypedConvexUnauthenticatedError(error)) {
    return const StoreBatchRefusedWhole(store.BatchRefusal.unauthenticated);
  }
  if (isAccountMismatchError(error)) {
    return StoreBatchAccountMismatch('$error');
  }
  if (isUncheckedOutsideWindowError(error)) {
    return StoreBatchOutsideWindow('$error');
  }
  if (isTypedConvexForbiddenError(error)) {
    return const StoreBatchRefusedWhole(store.BatchRefusal.editAccessRemoved);
  }
  if (isTypedConvexNotFoundError(error)) {
    return const StoreBatchRefusedWhole(store.BatchRefusal.strategyDeleted);
  }
  if (error is TimeoutException) {
    return StoreBatchLost(store.TransportFailure.timeout, '$error');
  }
  if (error is FormatException || error is ConvexNormalizationError) {
    return StoreBatchLost(store.TransportFailure.malformedAnswer, '$error');
  }
  return StoreBatchLost(store.TransportFailure.network, '$error');
}
