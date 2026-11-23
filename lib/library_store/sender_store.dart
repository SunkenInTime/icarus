import 'package:icarus/collab/collab_models.dart'
    show maxCloudBatchBytes, serializedConvexValueUtf8Bytes;
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus_library/icarus_library.dart';

typedef SessionMark = ({int connection, int authChanges, Account account});

final class ClaimedBatch {
  ClaimedBatch({
    required this.strategyId,
    required this.attempt,
    required this.clientId,
    required this.session,
    required List<StrategyOp> ops,
  }) : ops = List.unmodifiable(ops);

  final String strategyId;
  final int attempt;
  final String clientId;
  final SessionMark session;
  final List<StrategyOp> ops;

  Account get account => session.account;

  @override
  String toString() =>
      'attempt $attempt of $strategyId: ${ops.map((op) => op.opId).join(', ')}';
}

sealed class StoreTrouble {
  const StoreTrouble(this.why);

  final String why;
}

final class NotWrittenNow extends StoreTrouble {
  const NotWrittenNow(super.why);
}

final class StrategyHeld extends StoreTrouble {
  const StrategyHeld(super.why);
}

final class StoreShut extends StoreTrouble {
  const StoreShut(super.why);
}

sealed class Written {
  const Written();
}

final class WrittenWith extends Written {
  WrittenWith(List<QueueEffect> effects, {required this.session})
      : effects = List.unmodifiable(effects);

  final List<QueueEffect> effects;
  final int? session;
}

final class WriteTroubled extends Written {
  const WriteTroubled(this.trouble);

  final StoreTrouble trouble;
}

sealed class ClaimResult {
  const ClaimResult();
}

final class Claimed extends ClaimResult {
  const Claimed(this.batch);

  final ClaimedBatch batch;
}

final class NothingNow extends ClaimResult {
  const NothingNow(this.why, {this.retryAt});

  final String why;
  final DateTime? retryAt;
}

final class ClaimTroubled extends ClaimResult {
  const ClaimTroubled(this.trouble);

  final StoreTrouble trouble;
}

final class StoredStrategy {
  const StoredStrategy(this.summary, this.owner, this.tally);

  final StrategySummary summary;
  final CloudOwner owner;
  final Tally? tally;

  String get id => summary.publicId;
}

sealed class SenderReport {
  const SenderReport(this.strategyId);

  final String strategyId;
}

final class EventsWritten extends SenderReport {
  EventsWritten(super.strategyId, List<QueueEvent> events, {this.batch})
      : events = List.unmodifiable(events);

  final List<QueueEvent> events;
  final ClaimedBatch? batch;
}

final class EventNotApplied extends SenderReport {
  const EventNotApplied(super.strategyId, this.why);

  final String why;
}

final class WriteNotMade extends SenderReport {
  const WriteNotMade(super.strategyId, this.trouble);

  final StoreTrouble trouble;
}

const _mostOpsInABatch = 40;

final class SenderStore {
  SenderStore(this.store, {required this.clientId});

  final LibraryStore store;
  final String clientId;
  final reports = <SenderReport>[];

  StoreShut? get shut => switch (store.library) {
        LibraryShut(:final failure) =>
          StoreShut(storageFailureWords(failure, StoreStep.read)),
        LibraryOpen() => null,
      };

  List<StoredStrategy> strategies() => switch (store.library) {
        LibraryOpen(:final list) => [
            for (final summary in list.strategies)
              if (summary.sync case KeptInCloud(:final owner, :final tally))
                StoredStrategy(summary, owner, tally)
              else if (summary.sync case CloudUnverified(:final owner))
                StoredStrategy(summary, owner, null),
          ],
        LibraryShut() => const [],
      };

  Future<Written> write(
    Account owner,
    String strategyId,
    List<QueueEvent> events, {
    ClaimedBatch? batch,
  }) async {
    final RecordResult result;
    try {
      result = await store.record(owner, strategyId, events);
    } catch (error) {
      return _troubled(strategyId, StoreShut('the store threw: $error'));
    }
    switch (result) {
      case Saved(:final value):
        final effects = <QueueEffect>[];
        for (final outcome in value.outcomes) {
          switch (outcome) {
            case ReportApplied(effects: final applied):
              effects.addAll(applied);
            case ReportNotApplicable(:final why):
              reports.add(EventNotApplied(strategyId, '$why'));
            case EditsGoThroughCommit():
              break;
          }
        }
        reports.add(EventsWritten(strategyId, events, batch: batch));
        return WrittenWith(effects, session: await _session(strategyId));
      case NothingToSave():
        return WrittenWith(const [], session: await _session(strategyId));
      case Refused(:final reason):
        return _troubled(
            strategyId, StrategyHeld('the store refused it: $reason'));
      case NotSaved(:final failure):
        return _troubled(strategyId, _failed(failure, StoreStep.refusedSave));
      case SaveInDoubt(:final failure):
        return _troubled(
          strategyId,
          StoreShut(storageFailureWords(failure, StoreStep.saveInDoubt)),
        );
    }
  }

  WriteTroubled _troubled(String strategyId, StoreTrouble trouble) {
    reports.add(WriteNotMade(strategyId, trouble));
    return WriteTroubled(shut ?? trouble);
  }

  StoreTrouble _failed(StorageFailure failure, StoreStep step) {
    final words = storageFailureWords(failure, step);
    return switch (failure) {
      StoreClosed() ||
      EngineClosed() ||
      LeaseEnded() ||
      StoreStopped() =>
        StoreShut(words),
      _ => shut ?? NotWrittenNow(words),
    };
  }

  Future<int?> _session(String strategyId) async =>
      switch (await store.readStrategy(strategyId)) {
        Found(value: StrategyContent(sync: CloudStrategy(:final queue))) =>
          queue.session.number,
        _ => null,
      };

  Future<ClaimResult> claim(
    String strategyId,
    SessionMark session,
    DateTime now,
  ) async {
    final CloudStrategy cloud;
    switch (await store.readStrategy(strategyId)) {
      case Found(value: StrategyContent(sync: final CloudStrategy sync)):
        cloud = sync;
      case Found() || NotFound():
        return const NothingNow('the store holds no cloud queue for it');
      case InUnreadableStrategy():
        return const ClaimTroubled(
          StrategyHeld('the store lists it as unreadable'),
        );
      case NotRead(:final failure):
        return ClaimTroubled(_failed(failure, StoreStep.read));
    }
    final ids = <String>[];
    String? client;
    var bytes = 0;
    var awaiting = 0;
    DateTime? retryAt;
    for (final entry in cloud.queue.entries) {
      final view = cloud.views[entry.id];
      if (view == null) continue;
      for (final hold in view.holds) {
        switch (hold) {
          case UntilRetryTime(:final at):
            if (retryAt == null || at.isBefore(retryAt)) retryAt = at;
          case AwaitingResult():
            awaiting++;
          case BehindEntry():
            break;
        }
      }
      if (!view.sendable || entry is! PendingOp) continue;
      final owned = switch (view.state) {
        Unanswered(:final clientId) => clientId,
        _ => clientId,
      };
      if (client != null && owned != client) continue;
      final size = serializedConvexValueUtf8Bytes(entry.op.toJson());
      if (ids.isNotEmpty &&
          (ids.length >= _mostOpsInABatch ||
              bytes + size > maxCloudBatchBytes ~/ 2)) {
        break;
      }
      client = owned;
      bytes += size;
      ids.add(entry.id);
    }
    if (ids.isEmpty) {
      return NothingNow(
        awaiting > 0
            ? '$awaiting ops wait for a result from the server, which nothing '
                'reads while the editor does not show this strategy'
            : 'nothing in its queue may be sent now',
        retryAt: retryAt,
      );
    }
    final claim = [BatchClaimed(clientId: client!, opIds: ids, at: now)];
    switch (await write(session.account, strategyId, claim)) {
      case WrittenWith(:final effects):
        for (final effect in effects) {
          if (effect
              case SendBatch(:final attempt, :final clientId, :final ops)) {
            return Claimed(
              ClaimedBatch(
                strategyId: strategyId,
                attempt: attempt,
                clientId: clientId,
                session: session,
                ops: ops,
              ),
            );
          }
        }
        return const NothingNow('the queue claimed nothing to send');
      case WriteTroubled(:final trouble):
        return ClaimTroubled(trouble);
    }
  }
}
