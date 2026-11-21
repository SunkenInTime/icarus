import '../json.dart';
import '../wire.dart';
import 'pending.dart';
import 'queue.dart';

enum Attention {
  rejectedByServer,
  failedOnServer,
  oversized,
  changedUnseen,
  serverForgotAnswer,
  onDeletedPage,
  heldPageDelete,
  incompletePageCopy,
  waitingOnRefused,
  retiredFormat,
  retriesExhausted,
}

enum Waiting {
  unsent,
  answerUnknown,
  sending,
  confirming,
  awaitingBase,
  reissue,
}

final class Tally {
  Tally({
    required this.standing,
    Map<Waiting, int> waiting = const {},
    Map<Attention, int> attention = const {},
    this.unreadable = 0,
  }) : waiting = Map.unmodifiable({
         for (final MapEntry(:key, :value) in waiting.entries)
           if (value > 0) key: value,
       }),
       attention = Map.unmodifiable({
         for (final MapEntry(:key, :value) in attention.entries)
           if (value > 0) key: value,
       });

  static final empty = Tally(standing: Standing.good);

  factory Tally.of(CloudQueue queue, DateTime now) {
    final views = entryViews(queue, now);
    final waiting = <Waiting, int>{};
    final attention = <Attention, int>{};
    var unreadable = 0;
    void wait(Waiting why) => waiting[why] = (waiting[why] ?? 0) + 1;
    void needs(Attention why) => attention[why] = (attention[why] ?? 0) + 1;
    for (final entry in queue.entries) {
      switch (entry) {
        case UnreadableEntry():
          unreadable++;
        case RetiredOp():
          needs(Attention.retiredFormat);
        case PendingOp():
          final view = views[entry.id]!;
          switch ((view.state, view.go)) {
            case (Accepted(), _):
              wait(Waiting.confirming);
            case (Claimed(), _):
              wait(Waiting.sending);
            case (_, NeedsFreshId()):
              wait(Waiting.reissue);
            case (ServerRefused(refusal: RejectedByServer()), _):
              needs(Attention.rejectedByServer);
            case (ServerRefused(refusal: FailedOnServer()), _):
              needs(Attention.failedOnServer);
            case (_, NeedsUser(:final reason)):
              needs(switch (reason) {
                Oversized() => Attention.oversized,
                ChangedUnseen() => Attention.changedUnseen,
                ServerForgotAnswer() => Attention.serverForgotAnswer,
                OnDeletedPage() => Attention.onDeletedPage,
                DeleteHeld() => Attention.heldPageDelete,
                IncompleteCopy() => Attention.incompletePageCopy,
              });
            case (AnswerUnknown(backoff: RetriesExhausted()), _):
              needs(Attention.retriesExhausted);
            case (_, Free())
                when view.holds.any(
                  (hold) =>
                      hold is BehindEntry &&
                      switch (views[hold.opId]) {
                        EntryView(state: ServerRefused()) ||
                        EntryView(go: NeedsUser()) => true,
                        _ => false,
                      },
                ):
              needs(Attention.waitingOnRefused);
            case (_, Free())
                when view.holds.any((hold) => hold is AwaitingBase):
              wait(Waiting.awaitingBase);
            case (AnswerUnknown(), Free()):
              wait(Waiting.answerUnknown);
            case (NeverSent(), Free()):
              wait(Waiting.unsent);
          }
      }
    }
    return Tally(
      standing: standingOf(queue),
      waiting: waiting,
      attention: attention,
      unreadable: unreadable,
    );
  }

  static Decoded<Tally> decode(Object? json) =>
      JsonFields.read(json, 'sync tally', (fields) {
        final standing = Standing.values.asNameMap()[fields.json['standing']];
        if (standing == null) fields.reject('expected a standing');
        Map<T, int> counts<T extends Enum>(String key, List<T> values) {
          final found = <T, int>{};
          final raw = fields.has(key) ? fields.object(key) : JsonObject.empty;
          for (final MapEntry(:key, :value) in raw.entries) {
            final name = values.asNameMap()[key];
            if (name == null || !isSafeWhole(value) || (value! as num) <= 0) {
              fields.reject('expected a positive count for "$key"');
            } else {
              found[name] = (value as num).toInt();
            }
          }
          return found;
        }

        final waiting = counts('waiting', Waiting.values);
        final attention = counts('attention', Attention.values);
        final unreadable = fields.has('unreadable')
            ? fields.whole('unreadable')
            : 0;
        if (unreadable < 0) fields.reject('expected a count of unreadable');
        return () => Tally(
          standing: standing!,
          waiting: waiting,
          attention: attention,
          unreadable: unreadable,
        );
      });

  final Standing standing;
  final Map<Waiting, int> waiting;
  final Map<Attention, int> attention;
  final int unreadable;

  int get needingYou => attention.values.fold(0, (sum, count) => sum + count);

  int get stillGoing => waiting.values.fold(0, (sum, count) => sum + count);

  int get total => stillGoing + needingYou + unreadable;

  Tally plus(Tally other) => Tally(
    standing: _worse(standing, other.standing),
    waiting: {
      for (final why in Waiting.values)
        why: (waiting[why] ?? 0) + (other.waiting[why] ?? 0),
    },
    attention: {
      for (final why in Attention.values)
        why: (attention[why] ?? 0) + (other.attention[why] ?? 0),
    },
    unreadable: unreadable + other.unreadable,
  );

  static Standing _worse(Standing a, Standing b) => a.index >= b.index ? a : b;

  Map<String, Object?> toJson() => {
    'standing': standing.name,
    if (waiting.isNotEmpty)
      'waiting': {
        for (final MapEntry(:key, :value) in waiting.entries) key.name: value,
      },
    if (attention.isNotEmpty)
      'attention': {
        for (final MapEntry(:key, :value) in attention.entries) key.name: value,
      },
    if (unreadable > 0) 'unreadable': unreadable,
  };

  @override
  bool operator ==(Object other) =>
      other is Tally &&
      other.standing == standing &&
      sameMap(other.waiting, waiting) &&
      sameMap(other.attention, attention) &&
      other.unreadable == unreadable;

  @override
  int get hashCode =>
      Object.hash(standing, hashMap(waiting), hashMap(attention), unreadable);

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
  String toString() => 'AllSaved';
}

final class Outstanding extends SyncState {
  const Outstanding(this.face, this.tally);

  final Face face;
  final Tally tally;

  @override
  String toString() => 'Outstanding(${face.name}, $tally)';
}

enum Face {
  deletedOnServer,
  editAccessLost,
  unreadableWork,
  needsYou,
  upgradeRequired,
  offline,
  notThisAccount,
  answerUnknown,
  sending,
  confirming,
}

SyncState syncStateOf(
  Tally tally, {
  required Network network,
  required SignedIn signedIn,
}) {
  final face = switch (tally) {
    Tally(standing: Standing.deletedOnServer) => Face.deletedOnServer,
    Tally(standing: Standing.editAccessLost) => Face.editAccessLost,
    Tally(unreadable: > 0) => Face.unreadableWork,
    Tally(needingYou: > 0) => Face.needsYou,
    Tally(total: 0) => null,
    Tally(standing: Standing.upgradeRequired) => Face.upgradeRequired,
    _ when network == Network.offline => Face.offline,
    _ when signedIn == SignedIn.notThisAccount => Face.notThisAccount,
    Tally(:final waiting) when waiting.containsKey(Waiting.answerUnknown) =>
      Face.answerUnknown,
    Tally(:final waiting)
        when waiting.containsKey(Waiting.unsent) ||
            waiting.containsKey(Waiting.sending) ||
            waiting.containsKey(Waiting.reissue) =>
      Face.sending,
    _ => Face.confirming,
  };
  return face == null ? const AllSaved() : Outstanding(face, tally);
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
