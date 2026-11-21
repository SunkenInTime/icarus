import '../wire.dart';
import 'pending.dart';
import 'queue.dart';

enum Attention {
  rejectedByServer,
  failedOnServer,
  oversized,
  noLongerFits,
  incompletePageCopy,
  heldPageDelete,
  onDeletedPage,
  serverForgotAnswer,
  retiredFormat,
  retriesExhausted,
  editAccessRemoved,
}

final class Tally {
  Tally({
    this.unsent = 0,
    this.answerUnknown = 0,
    this.sending = 0,
    this.confirming = 0,
    this.upgradeRequired = 0,
    this.unreadable = 0,
    this.keptForDeletedStrategy = 0,
    Map<Attention, int> attention = const {},
  }) : attention = Map.unmodifiable({
         for (final MapEntry(:key, :value) in attention.entries)
           if (value > 0) key: value,
       });

  static final empty = Tally();

  factory Tally.of(CloudQueue queue) {
    var unsent = 0;
    var answerUnknown = 0;
    var sending = 0;
    var confirming = 0;
    var upgradeRequired = 0;
    var unreadable = 0;
    var kept = 0;
    final attention = <Attention, int>{};
    void needs(Attention reason) =>
        attention[reason] = (attention[reason] ?? 0) + 1;
    void waiting(void Function() count) => switch (queue.standing) {
      Standing.good => count(),
      Standing.upgradeRequired => upgradeRequired++,
      Standing.editAccessLost => needs(Attention.editAccessRemoved),
      Standing.deletedOnServer => kept++,
    };
    for (final entry in queue.entries) {
      switch (entry) {
        case UnreadableEntry():
          unreadable++;
        case RetiredOp():
          needs(Attention.retiredFormat);
        case PendingOp(state: Accepted()):
          confirming++;
        case PendingOp() when queue.standing == Standing.deletedOnServer:
          kept++;
        case PendingOp(state: Claimed()):
          sending++;
        case PendingOp(state: ServerRefused(refusal: RejectedByServer())):
          needs(Attention.rejectedByServer);
        case PendingOp(state: ServerRefused(refusal: FailedOnServer())):
          needs(Attention.failedOnServer);
        case PendingOp(work: CheckedDelete(verdict: HeldForUser())):
          needs(Attention.heldPageDelete);
        case PendingOp(state: Unsent(go: NeedsUser(:final reason))):
          needs(switch (reason) {
            Oversized() => Attention.oversized,
            NoLongerFits() => Attention.noLongerFits,
            IncompletePageCopy() => Attention.incompletePageCopy,
            OnDeletedPage() => Attention.onDeletedPage,
          });
        case PendingOp(
          state: Unsent(delivery: AnswerUnknown(retry: ServerForgotAnswer())),
        ):
          needs(Attention.serverForgotAnswer);
        case PendingOp(
          state: Unsent(delivery: AnswerUnknown(retry: RetriesExhausted())),
        ):
          needs(Attention.retriesExhausted);
        case PendingOp(state: Unsent(delivery: AnswerUnknown())):
          waiting(() => answerUnknown++);
        case PendingOp(state: Unsent(delivery: NeverSent())):
          waiting(() => unsent++);
      }
    }
    return Tally(
      unsent: unsent,
      answerUnknown: answerUnknown,
      sending: sending,
      confirming: confirming,
      upgradeRequired: upgradeRequired,
      unreadable: unreadable,
      keptForDeletedStrategy: kept,
      attention: attention,
    );
  }

  static Decoded<Tally> decode(Object? json) =>
      JsonFields.read(json, 'sync tally', (fields) {
        int count(String key) => fields.has(key) ? fields.whole(key) : 0;
        final attention = fields.has('attention')
            ? fields.object('attention')
            : const <String, Object?>{};
        final counts = <Attention, int>{};
        for (final MapEntry(:key, :value) in attention.entries) {
          final reason = Attention.values
              .where((reason) => reason.name == key)
              .firstOrNull;
          if (reason == null || !isSafeWhole(value) || (value! as num) < 0) {
            fields.reject('unknown attention count "$key"');
          } else {
            counts[reason] = (value as num).toInt();
          }
        }
        final values = (
          count('unsent'),
          count('answerUnknown'),
          count('sending'),
          count('confirming'),
          count('upgradeRequired'),
          count('unreadable'),
          count('keptForDeletedStrategy'),
        );
        return () => Tally(
          unsent: values.$1,
          answerUnknown: values.$2,
          sending: values.$3,
          confirming: values.$4,
          upgradeRequired: values.$5,
          unreadable: values.$6,
          keptForDeletedStrategy: values.$7,
          attention: counts,
        );
      });

  final int unsent;
  final int answerUnknown;
  final int sending;
  final int confirming;
  final int upgradeRequired;
  final int unreadable;
  final int keptForDeletedStrategy;
  final Map<Attention, int> attention;

  int get needingYou => attention.values.fold(0, (sum, count) => sum + count);

  int get waiting =>
      unsent + answerUnknown + sending + confirming + upgradeRequired;

  int get total => waiting + needingYou + unreadable + keptForDeletedStrategy;

  Tally plus(Tally other) => Tally(
    unsent: unsent + other.unsent,
    answerUnknown: answerUnknown + other.answerUnknown,
    sending: sending + other.sending,
    confirming: confirming + other.confirming,
    upgradeRequired: upgradeRequired + other.upgradeRequired,
    unreadable: unreadable + other.unreadable,
    keptForDeletedStrategy:
        keptForDeletedStrategy + other.keptForDeletedStrategy,
    attention: {
      for (final reason in Attention.values)
        reason: (attention[reason] ?? 0) + (other.attention[reason] ?? 0),
    },
  );

  Map<String, Object?> toJson() => {
    if (unsent > 0) 'unsent': unsent,
    if (answerUnknown > 0) 'answerUnknown': answerUnknown,
    if (sending > 0) 'sending': sending,
    if (confirming > 0) 'confirming': confirming,
    if (upgradeRequired > 0) 'upgradeRequired': upgradeRequired,
    if (unreadable > 0) 'unreadable': unreadable,
    if (keptForDeletedStrategy > 0)
      'keptForDeletedStrategy': keptForDeletedStrategy,
    if (attention.isNotEmpty)
      'attention': {
        for (final MapEntry(:key, :value) in attention.entries) key.name: value,
      },
  };

  @override
  bool operator ==(Object other) =>
      other is Tally &&
      other.unsent == unsent &&
      other.answerUnknown == answerUnknown &&
      other.sending == sending &&
      other.confirming == confirming &&
      other.upgradeRequired == upgradeRequired &&
      other.unreadable == unreadable &&
      other.keptForDeletedStrategy == keptForDeletedStrategy &&
      other.attention.length == attention.length &&
      attention.entries.every(
        (entry) => other.attention[entry.key] == entry.value,
      );

  @override
  int get hashCode => Object.hash(
    unsent,
    answerUnknown,
    sending,
    confirming,
    upgradeRequired,
    unreadable,
    keptForDeletedStrategy,
    Object.hashAllUnordered(
      attention.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  @override
  String toString() => 'Tally(${toJson()})';
}

enum Network { online, offline }

enum SignedIn { thisAccount, notThisAccount }

sealed class SyncState {
  const SyncState();
}

final class AllSaved extends SyncState {
  const AllSaved();

  @override
  bool operator ==(Object other) => other is AllSaved;

  @override
  int get hashCode => (AllSaved).hashCode;

  @override
  String toString() => 'AllSaved';
}

sealed class Outstanding extends SyncState {
  const Outstanding(this.tally);

  final Tally tally;
}

final class KeptForDeletedStrategy extends Outstanding {
  const KeptForDeletedStrategy(super.tally);

  @override
  String toString() => 'KeptForDeletedStrategy($tally)';
}

final class UnreadableWork extends Outstanding {
  const UnreadableWork(super.tally);

  @override
  String toString() => 'UnreadableWork($tally)';
}

final class NeedsYou extends Outstanding {
  const NeedsYou(super.tally);

  @override
  String toString() => 'NeedsYou($tally)';
}

final class Waiting extends Outstanding {
  const Waiting(this.why, super.tally);

  final WaitingWhy why;

  @override
  String toString() => 'Waiting(${why.name}, $tally)';
}

enum WaitingWhy {
  offline,
  notThisAccount,
  upgradeRequired,
  answerUnknown,
  sending,
  confirming,
}

SyncState syncStateOf(
  Tally tally, {
  required Network network,
  required SignedIn signedIn,
}) {
  if (tally.total == 0) return const AllSaved();
  if (tally.keptForDeletedStrategy > 0) return KeptForDeletedStrategy(tally);
  if (tally.unreadable > 0) return UnreadableWork(tally);
  if (tally.needingYou > 0) return NeedsYou(tally);
  return Waiting(switch ((network, signedIn)) {
    (Network.offline, _) => WaitingWhy.offline,
    (_, SignedIn.notThisAccount) => WaitingWhy.notThisAccount,
    _ when tally.upgradeRequired > 0 => WaitingWhy.upgradeRequired,
    _ when tally.answerUnknown > 0 => WaitingWhy.answerUnknown,
    _ when tally.unsent + tally.sending > 0 => WaitingWhy.sending,
    _ => WaitingWhy.confirming,
  }, tally);
}

SyncState accountSyncState(
  Iterable<Tally> strategies, {
  required Network network,
  required SignedIn signedIn,
}) => syncStateOf(
  strategies.fold(Tally.empty, (sum, tally) => sum.plus(tally)),
  network: network,
  signedIn: signedIn,
);
