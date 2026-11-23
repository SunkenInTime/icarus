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
  const StoreReadAnswered(this.base, {this.role});

  final store.ArrivedBase base;
  final StoreReadRole? role;
}

final class StoreReadRefused extends StoreReadOutcome {
  const StoreReadRefused(this.refusal, this.why);

  final StoreReadRefusal refusal;
  final String why;
}

final class StoreReadUnreadable extends StoreReadOutcome {
  const StoreReadUnreadable(this.problem);

  final String problem;
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

StoreReads storeReadsOver(
  ConvexStrategyRepository repository, {
  required store.CanRead canRead,
}) =>
    StoreReads(
      pageList: ({required strategyPublicId, required account}) async {
        try {
          final list = await repository.readPageListAs(
            strategyPublicId,
            accountSubject: account.subject,
          );
          return switch (pageListRead(list)) {
            RowsRead(:final value) => StoreReadAnswered(
                value,
                role: StoreReadRole.of(list.header.role),
              ),
            RowsUnreadable(:final problem) => StoreReadUnreadable(problem),
          };
        } catch (error) {
          return storeReadOutcomeOfError(
            error,
            gone: const store.StrategyGone(),
          );
        }
      },
      page: ({
        required strategyPublicId,
        required pagePublicId,
        required account,
      }) async {
        try {
          final page = await repository.readPageAs(
            strategyPublicId: strategyPublicId,
            pagePublicId: pagePublicId,
            accountSubject: account.subject,
          );
          return switch (pageRead(page, canRead)) {
            RowsRead(:final value) => StoreReadAnswered(value),
            RowsUnreadable(:final problem) => StoreReadUnreadable(problem),
          };
        } catch (error) {
          return storeReadOutcomeOfError(
            error,
            gone: store.PageGone(pagePublicId),
          );
        }
      },
    );

StoreReadOutcome storeReadOutcomeOfError(
  Object error, {
  required store.ArrivedBase gone,
}) {
  if (isClientUpgradeRequiredError(error)) {
    return StoreReadRefused(StoreReadRefusal.upgradeRequired, '$error');
  }
  if (isTypedConvexUnauthenticatedError(error)) {
    return StoreReadRefused(StoreReadRefusal.unauthenticated, '$error');
  }
  if (isAccountMismatchError(error)) {
    return StoreReadRefused(StoreReadRefusal.accountMismatch, '$error');
  }
  if (isTypedConvexForbiddenError(error)) {
    return StoreReadRefused(StoreReadRefusal.forbidden, '$error');
  }
  if (isTypedConvexNotFoundError(error) || _isPageElsewhere(error)) {
    return StoreReadAnswered(gone);
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
