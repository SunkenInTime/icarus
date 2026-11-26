import 'dart:async';

import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
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
  const StoreReadRefused(this.refusal, this.why, {this.point});

  final StoreReadRefusal refusal;
  final String why;
  final store.ResultPoint? point;
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
          return switch (await repository.readPageListStamped(
            strategyPublicId,
            accountSubject: account.subject,
          )) {
            StampedValue(value: final list, :final stamp) =>
              switch (pageListRead(list)) {
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
          return switch (await repository.readPageStamped(
            strategyPublicId: strategyPublicId,
            pagePublicId: pagePublicId,
            accountSubject: account.subject,
          )) {
            StampedValue(value: final page, :final stamp) =>
              switch (pageRead(page, canRead)) {
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
        } catch (error) {
          return storeReadOutcomeOfError(
            error,
            gone: store.PageGone(pagePublicId),
            point: null,
          );
        }
      },
    );

StoreReadOutcome storeReadOutcomeOfError(
  Object error, {
  required store.ArrivedBase gone,
  required store.ResultPoint? point,
}) {
  if (isClientUpgradeRequiredError(error)) {
    return StoreReadRefused(
      StoreReadRefusal.upgradeRequired,
      '$error',
      point: point,
    );
  }
  if (isTypedConvexUnauthenticatedError(error)) {
    return StoreReadRefused(
      StoreReadRefusal.unauthenticated,
      '$error',
      point: point,
    );
  }
  if (isAccountMismatchError(error)) {
    return StoreReadRefused(
      StoreReadRefusal.accountMismatch,
      '$error',
      point: point,
    );
  }
  if (isTypedConvexForbiddenError(error)) {
    return StoreReadRefused(
      StoreReadRefusal.forbidden,
      '$error',
      point: point,
    );
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
