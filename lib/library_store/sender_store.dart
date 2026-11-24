import 'package:icarus/collab/collab_models.dart'
    show maxCloudBatchBytes, serializedConvexValueUtf8Bytes;
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus_library/icarus_library.dart';

final class ClaimedBatch {
  ClaimedBatch({
    required this.strategyId,
    required this.account,
    required this.attempt,
    required this.clientId,
    required List<StrategyOp> ops,
    required this.session,
    required this.strategyLife,
    this.basis,
    Map<String, int> lives = const {},
  })  : ops = List.unmodifiable(ops),
        lives = Map.unmodifiable(lives);

  final String strategyId;
  final Account account;
  final int attempt;
  final String clientId;
  final List<StrategyOp> ops;
  final int session;
  final int strategyLife;
  final int? basis;
  final Map<String, int> lives;

  List<String> get unchecked => [
        for (final op in ops)
          if (isUncheckedSend(op)) op.opId,
      ];

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
  WrittenWith(
    List<QueueEffect> effects, {
    required this.session,
    required List<String> notApplied,
  })  : effects = List.unmodifiable(effects),
        notApplied = List.unmodifiable(notApplied);

  final List<QueueEffect> effects;
  final int? session;
  final List<String> notApplied;
}

final class WriteTroubled extends Written {
  const WriteTroubled(this.trouble);

  final StoreTrouble trouble;
}

sealed class QueueRead {
  const QueueRead();
}

final class QueueFound extends QueueRead {
  const QueueFound(this.cloud);

  final CloudStrategy cloud;
}

final class QueueTroubled extends QueueRead {
  const QueueTroubled(this.trouble);

  final StoreTrouble trouble;
}

sealed class Pick {
  const Pick();
}

final class Picked extends Pick {
  Picked(this.clientId, List<String> ids) : ids = List.unmodifiable(ids);

  final String clientId;
  final List<String> ids;
}

final class NothingSendable extends Pick {
  const NothingSendable(this.why, {this.retryAt});

  final String why;
  final DateTime? retryAt;
}

sealed class ClaimResult {
  const ClaimResult();
}

final class Claimed extends ClaimResult {
  const Claimed(this.batch);

  final ClaimedBatch batch;
}

final class NotClaimed extends ClaimResult {
  const NotClaimed(this.why);

  final String why;
}

final class ClaimTroubled extends ClaimResult {
  const ClaimTroubled(this.trouble);

  final StoreTrouble trouble;
}

final class StoredStrategy {
  const StoredStrategy(this.id, this.owner, this.tally);

  final String id;
  final CloudOwner owner;
  final Tally? tally;

  Account? get ownerAccount => switch (owner) {
        OwnedBy(:final account) => account,
        OwnerUnreadable() => null,
      };

  bool get needsReading => switch (tally) {
        Tally(standing: Standing.editAccessLost) => true,
        Tally(:final waiting, :final readsOwed) =>
          readsOwed > 0 || waiting.containsKey(Underway.awaitingResult),
        null => false,
      };

  bool get hasWorkToSend {
    final known = tally;
    if (known == null) return true;
    return known.standing == Standing.good &&
        (known.waiting.containsKey(Underway.unsent) ||
            known.waiting.containsKey(Underway.answerUnknown) ||
            known.waiting.containsKey(Underway.sending));
  }
}

sealed class SenderReport {
  const SenderReport(this.strategyId);

  final String strategyId;
}

final class EventsWritten extends SenderReport {
  EventsWritten(
    super.strategyId,
    List<QueueEvent> events, {
    this.batch,
    List<QueueEffect> effects = const [],
  })  : events = List.unmodifiable(events),
        effects = List.unmodifiable(effects);

  final List<QueueEvent> events;
  final ClaimedBatch? batch;
  final List<QueueEffect> effects;
}

final class SessionOpenedFor extends SenderReport {
  const SessionOpenedFor(super.strategyId, this.session, this.stamp);

  final int session;
  final Snapshot stamp;
}

final class ReadRecorded extends SenderReport {
  const ReadRecorded(super.strategyId, this.read, this.why, {required this.at});

  final String read;
  final String why;
  final DateTime at;
}

final class EventNotApplied extends SenderReport {
  const EventNotApplied(super.strategyId, this.why);

  final String why;
}

final class BatchSentAs extends SenderReport {
  const BatchSentAs(super.strategyId, this.batch);

  final ClaimedBatch batch;
}

final class UncheckedWithoutBasis extends SenderReport {
  const UncheckedWithoutBasis(super.strategyId, this.batch);

  final ClaimedBatch batch;
}

final class WriteNotMade extends SenderReport {
  const WriteNotMade(super.strategyId, this.trouble);

  final StoreTrouble trouble;
}

const _mostOpsInABatch = 40;

base class SenderStore {
  SenderStore(this.store, {this.keepsAllReports = false});

  static const reportsKept = 1000;

  final LibraryStore store;
  final bool keepsAllReports;
  final reports = <SenderReport>[];
  var reportsDropped = 0;

  void report(SenderReport report) {
    reports.add(report);
    if (!keepsAllReports && reports.length > reportsKept) {
      reports.removeAt(0);
      reportsDropped++;
    }
  }

  StoreShut? get shut {
    if (store.library case LibraryShut(:final failure)) {
      return StoreShut(storageFailureWords(failure, StoreStep.read));
    }
    if (store.isClosing) return const StoreShut('the store is closing');
    return null;
  }

  List<StoredStrategy> strategies() => switch (store.library) {
        LibraryOpen(:final list) => [
            for (final summary in list.strategies)
              if (summary.sync case KeptInCloud(:final owner, :final tally))
                StoredStrategy(summary.publicId, owner, tally)
              else if (summary.sync case CloudUnverified(:final owner))
                StoredStrategy(summary.publicId, owner, null),
          ],
        LibraryShut() => const [],
      };

  int readStartsNow() => store.readStartsNow();

  Future<Reading<StrategyContent>> readStrategy(String strategyId) =>
      store.readStrategy(strategyId);

  Future<QueueRead> read(String strategyId) async {
    final Reading<StrategyContent> reading;
    try {
      reading = await readStrategy(strategyId);
    } catch (error) {
      return QueueTroubled(StoreShut('the store threw: $error'));
    }
    return switch (reading) {
      Found(value: StrategyContent(sync: final CloudStrategy cloud)) =>
        QueueFound(cloud),
      Found() || NotFound() => const QueueTroubled(
          StrategyHeld('the store holds no cloud queue for it'),
        ),
      InUnreadableStrategy() => const QueueTroubled(
          StrategyHeld('the store lists it as unreadable'),
        ),
      NotRead(:final failure) =>
        QueueTroubled(_failed(failure, StoreStep.read)),
    };
  }

  Future<Written> write(
    Account owner,
    String strategyId,
    List<QueueEvent> events, {
    ClaimedBatch? batch,
    bool readSession = false,
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
        final notApplied = <String>[];
        for (final outcome in value.outcomes) {
          switch (outcome) {
            case ReportApplied(effects: final applied):
              effects.addAll(applied);
            case ReportNotApplicable(:final why):
              notApplied.add('$why');
              report(EventNotApplied(strategyId, '$why'));
            case EditsGoThroughCommit():
              notApplied.add('an edit goes through commit');
          }
        }
        report(
          EventsWritten(strategyId, events, batch: batch, effects: effects),
        );
        return _writtenWith(strategyId, effects, notApplied, readSession);
      case NothingToSave():
        return _writtenWith(strategyId, const [], const [], readSession);
      case Refused(:final reason):
        return _troubled(
          strategyId,
          StrategyHeld('the store refused it: $reason'),
        );
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
    report(WriteNotMade(strategyId, trouble));
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

  Future<Written> _writtenWith(
    String strategyId,
    List<QueueEffect> effects,
    List<String> notApplied,
    bool readSession,
  ) async {
    if (!readSession) {
      return WrittenWith(effects, session: null, notApplied: notApplied);
    }
    final Reading<StrategyContent> reading;
    try {
      reading = await readStrategy(strategyId);
    } catch (error) {
      return _troubled(strategyId, StoreShut('the store threw: $error'));
    }
    return WrittenWith(
      effects,
      session: switch (reading) {
        Found(value: StrategyContent(sync: CloudStrategy(:final queue))) =>
          queue.session.number,
        _ => null,
      },
      notApplied: notApplied,
    );
  }

  Future<Written> add(
    Account owner,
    String strategyId,
    HeaderRead header,
  ) async {
    final Saving<StrategySummary, LibraryRefusal> result;
    try {
      result = await store.addCloudStrategy(owner, header, const []);
    } catch (error) {
      return _troubled(strategyId, StoreShut('the store threw: $error'));
    }
    switch (result) {
      case Saved() || NothingToSave():
        return _writtenWith(strategyId, const [], const [], true);
      case Refused(:final reason):
        return _troubled(
          strategyId,
          StrategyHeld('the store refused it: $reason'),
        );
      case NotSaved(:final failure):
        return _troubled(strategyId, _failed(failure, StoreStep.refusedSave));
      case SaveInDoubt(:final failure):
        return _troubled(
          strategyId,
          StoreShut(storageFailureWords(failure, StoreStep.saveInDoubt)),
        );
    }
  }

  Future<ClaimResult> claim(
    Account owner,
    String strategyId,
    Picked picked,
    DateTime at, {
    required Duration Function() elapsed,
    required int session,
  }) async {
    final events = [
      BatchClaimed(
        clientId: picked.clientId,
        opIds: picked.ids,
        at: at,
        elapsed: elapsed,
      ),
    ];
    switch (await write(owner, strategyId, events)) {
      case WrittenWith(:final effects, :final notApplied):
        for (final effect in effects) {
          if (effect
              case SendBatch(
                :final attempt,
                :final clientId,
                :final ops,
                :final basis,
                :final lives,
                :final strategyLife,
              )) {
            return Claimed(
              ClaimedBatch(
                strategyId: strategyId,
                account: owner,
                attempt: attempt,
                clientId: clientId,
                ops: ops,
                session: session,
                basis: basis,
                lives: lives,
                strategyLife: strategyLife,
              ),
            );
          }
        }
        return NotClaimed(
          notApplied.isEmpty
              ? 'the queue claimed nothing to send'
              : notApplied.join('; '),
        );
      case WriteTroubled(:final trouble):
        return ClaimTroubled(trouble);
    }
  }
}

List<int> openAttempts(CloudStrategy cloud) => [
      for (final attempt in cloud.queue.attempts.values)
        if (attempt.outcome is AttemptOpen) attempt.number,
    ];

Pick pick(CloudStrategy cloud, String newClientId) {
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
      _ => newClientId,
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
  if (client != null) return Picked(client, ids);
  return NothingSendable(
    awaiting > 0
        ? '$awaiting ops wait for a result from the server, which the '
            'sender reads next'
        : 'nothing in its queue may be sent now',
    retryAt: retryAt,
  );
}
