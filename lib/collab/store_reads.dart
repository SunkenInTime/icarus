import 'dart:async';

import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart' show RemotePageSnapshot;
import 'package:icarus/collab/convex_client.dart'
    show ConvexClientFunctionError;
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus_library/icarus_library.dart' as store;

enum StoreReadRole {
  owner,
  editor,
  viewer;

  bool get edits => this != viewer;

  static StoreReadRole? of(String? wire) =>
      values.where((role) => role.name == wire).firstOrNull;
}

enum StoreReadRefusal {
  accountMismatch,
  unauthenticated,
  forbidden,
  upgradeRequired
}

sealed class StoreReadOutcome {
  const StoreReadOutcome();
}

final class StoreReadAnswered extends StoreReadOutcome {
  const StoreReadAnswered(this.base, {required this.point, this.role});

  final store.ArrivedBase base;
  final store.ResultPoint point;
  final StoreReadRole? role;
}

final class StoreReadRefused extends StoreReadOutcome {
  const StoreReadRefused(this.refusal, this.why, {required this.point});

  final StoreReadRefusal refusal;
  final String why;
  final store.ResultPoint point;
}

final class StoreReadUnreadable extends StoreReadOutcome {
  const StoreReadUnreadable(this.problem, {required this.point});

  final String problem;
  final store.ResultPoint point;
}

final class StoreReadLost extends StoreReadOutcome {
  const StoreReadLost(this.failure, this.why);

  final store.TransportFailure failure;
  final String why;
}

final class StoreReads {
  const StoreReads({required this.pageList, required this.page});

  final Future<StoreReadOutcome> Function({
    required String strategyPublicId,
    required store.Account account,
  }) pageList;

  final Future<StoreReadOutcome> Function({
    required String strategyPublicId,
    required String pagePublicId,
    required store.Account account,
  }) page;
}

store.ResultPoint pointOf(ResultStamp stamp) => store.ResultPoint(
      client: stamp.client,
      connection: stamp.connection,
      snapshot: stamp.snapshot,
      serverTime: stamp.serverTime,
    );

StoreReads storeReadsOver(
  ConvexStrategyRepository repository, {
  required store.CanRead canRead,
}) =>
    StoreReads(
      pageList: ({required strategyPublicId, required account}) async {
        try {
          return pageListOutcomeOf(
            await repository.readPageListStamped(
              strategyPublicId,
              accountSubject: account.subject,
            ),
          );
        } catch (error) {
          return storeReadOutcomeOfError(
            error,
            gone: const store.StrategyGone(),
            point: null,
          );
        }
      },
      page: ({
        required strategyPublicId,
        required pagePublicId,
        required account,
      }) async {
        try {
          return pageOutcomeOf(
            await repository.readPageStamped(
              strategyPublicId: strategyPublicId,
              pagePublicId: pagePublicId,
              accountSubject: account.subject,
            ),
            pagePublicId: pagePublicId,
            canRead: canRead,
          );
        } catch (error) {
          return storeReadOutcomeOfError(
            error,
            gone: store.PageGone(pagePublicId),
            point: null,
          );
        }
      },
    );

StoreReadOutcome pageListOutcomeOf(Stamped<RemotePageList> answer) =>
    switch (answer) {
      StampedValue(value: final list, :final stamp) => switch (
            pageListRead(list)) {
          RowsRead(:final value) => StoreReadAnswered(
              value,
              point: pointOf(stamp),
              role: StoreReadRole.of(list.header.role),
            ),
          RowsUnreadable(:final problem) =>
            StoreReadUnreadable(problem, point: pointOf(stamp)),
        },
      StampedError(:final error, :final stamp) => storeReadOutcomeOfError(
          ConvexFunctionException.fromTransport(error),
          gone: const store.StrategyGone(),
          point: pointOf(stamp),
        ),
    };

StoreReadOutcome pageOutcomeOf(
  Stamped<RemotePageSnapshot> answer, {
  required String pagePublicId,
  required store.CanRead canRead,
}) =>
    switch (answer) {
      StampedValue(value: final page, :final stamp) => switch (
            pageRead(page, canRead)) {
          RowsRead(:final value) =>
            StoreReadAnswered(value, point: pointOf(stamp)),
          RowsUnreadable(:final problem) =>
            StoreReadUnreadable(problem, point: pointOf(stamp)),
        },
      StampedError(:final error, :final stamp) => storeReadOutcomeOfError(
          ConvexFunctionException.fromTransport(error),
          gone: store.PageGone(pagePublicId),
          point: pointOf(stamp),
        ),
    };

final class LivePageAnswer {
  const LivePageAnswer(
    this.page, {
    required this.pagePublicId,
    required this.point,
  });

  final RemotePageSnapshot page;
  final String pagePublicId;
  final store.ResultPoint point;
}

({StoreReadOutcome outcome, int decoded}) livePageOutcome(
  LivePageAnswer answer, {
  required store.CanRead canRead,
  required HeldRows held,
  void Function(store.Row row)? decoded,
}) {
  var count = 0;
  final outcome = switch (pageReadOver(
    answer.page,
    canRead,
    held: held,
    decoded: (row) {
      count++;
      decoded?.call(row);
    },
  )) {
    RowsRead(:final value) => StoreReadAnswered(value, point: answer.point),
    RowsUnreadable(:final problem) =>
      StoreReadUnreadable(problem, point: answer.point),
  };
  return (outcome: outcome, decoded: count);
}

StoreReadOutcome storeReadOutcomeOfError(
  Object error, {
  required store.ArrivedBase gone,
  required store.ResultPoint? point,
}) {
  final refusal = switch (error) {
    _ when isClientUpgradeRequiredError(error) =>
      StoreReadRefusal.upgradeRequired,
    _ when isTypedConvexUnauthenticatedError(error) =>
      StoreReadRefusal.unauthenticated,
    _ when isAccountMismatchError(error) => StoreReadRefusal.accountMismatch,
    _ when isTypedConvexForbiddenError(error) => StoreReadRefusal.forbidden,
    _ => null,
  };
  if ((refusal, point) case (final refusal?, final point?)) {
    return StoreReadRefused(refusal, '$error', point: point);
  }
  if (point != null &&
      (isTypedConvexNotFoundError(error) || _isPageElsewhere(error))) {
    return StoreReadAnswered(gone, point: point);
  }
  if (error is TimeoutException) {
    return StoreReadLost(store.TransportFailure.timeout, '$error');
  }
  if (error is FormatException || error is ConvexNormalizationError) {
    return StoreReadLost(store.TransportFailure.malformedAnswer, '$error');
  }
  return StoreReadLost(store.TransportFailure.network, '$error');
}

bool _isPageElsewhere(Object error) => switch (error) {
      ConvexFunctionException(:final rawCode) ||
      ConvexClientFunctionError(:final rawCode) =>
        rawCode == ConvexErrorCode.pageStrategyMismatch.wireName,
      _ => false,
    };
