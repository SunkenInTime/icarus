import '../json.dart';
import '../wire.dart';
import 'account.dart';
import 'pending.dart';
import 'queue.dart';

enum Attention {
  rejectedByServer,
  failedOnServer,
  oversized,
  changedUnseen,
  pageGone,
  serverForgotAnswer,
  strategyReplaced,
  heldPageDelete,
  waitingOnRefused,
  retiredFormat,
  retriesExhausted,
}

enum Underway { unsent, answerUnknown, sending, awaitingResult }

final class Tally {
  Tally({
    required this.standing,
    Map<Underway, int> waiting = const {},
    Map<Attention, int> attention = const {},
    this.unreadable = 0,
    this.readsOwed = 0,
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
    final counts = queueCounts(queue, now);
    return Tally(
      standing: standingOf(queue),
      waiting: counts.waiting,
      attention: counts.attention,
      readsOwed: owedReads(queue).length,
    );
  }

  static Decoded<Tally> decode(Object? json) => JsonFields.read(
    json,
    'sync tally',
    (fields) {
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

      final waiting = counts('waiting', Underway.values);
      final attention = counts('attention', Attention.values);
      final unreadable = fields.has('unreadable')
          ? fields.whole('unreadable')
          : 0;
      if (unreadable < 0) fields.reject('expected a count of unreadable');
      final readsOwed = fields.has('readsOwed') ? fields.whole('readsOwed') : 0;
      if (readsOwed < 0) fields.reject('expected a count of reads owed');
      return () => Tally(
        standing: standing!,
        waiting: waiting,
        attention: attention,
        unreadable: unreadable,
        readsOwed: readsOwed,
      );
    },
  );

  final Standing standing;
  final Map<Underway, int> waiting;
  final Map<Attention, int> attention;
  final int unreadable;
  final int readsOwed;

  int get needingYou => attention.values.fold(0, (sum, count) => sum + count);

  int get stillGoing => waiting.values.fold(0, (sum, count) => sum + count);

  int get total => stillGoing + needingYou + unreadable;

  Tally plus(Tally other) => Tally(
    standing: _worse(standing, other.standing),
    waiting: {
      for (final why in Underway.values)
        why: (waiting[why] ?? 0) + (other.waiting[why] ?? 0),
    },
    attention: {
      for (final why in Attention.values)
        why: (attention[why] ?? 0) + (other.attention[why] ?? 0),
    },
    unreadable: unreadable + other.unreadable,
    readsOwed: readsOwed + other.readsOwed,
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
    if (readsOwed > 0) 'readsOwed': readsOwed,
  };

  @override
  bool operator ==(Object other) =>
      other is Tally &&
      other.standing == standing &&
      sameMap(other.waiting, waiting) &&
      sameMap(other.attention, attention) &&
      other.unreadable == unreadable &&
      other.readsOwed == readsOwed;

  @override
  int get hashCode =>
      Object.hash(standing, hashMap(waiting), hashMap(attention), unreadable);

  @override
  String toString() => 'Tally(${toJson()})';
}

enum Network { online, offline }

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
  ownerUnreadable,
  signedOut,
  heldForAnotherAccount,
  notThisAccount,
  deletedOnServer,
  editAccessLost,
  unreadableWork,
  needsYou,
  upgradeRequired,
  offline,
  answerUnknown,
  sending,
  awaitingResult,
}

sealed class SignedIn {
  const SignedIn();
}

final class SignedInAs extends SignedIn {
  const SignedInAs(this.account);

  final Account account;

  @override
  bool operator ==(Object other) =>
      other is SignedInAs && other.account == account;

  @override
  int get hashCode => account.hashCode;

  @override
  String toString() => 'SignedInAs(${account.subject})';
}

final class SignedOut extends SignedIn {
  const SignedOut();

  @override
  bool operator ==(Object other) => other is SignedOut;

  @override
  int get hashCode => (SignedOut).hashCode;

  @override
  String toString() => 'SignedOut';
}

SyncState syncStateOf(
  CloudOwner owner,
  Tally tally, {
  required Network network,
  required SignedIn signedIn,
}) {
  final face = switch ((owner, signedIn)) {
    (OwnerUnreadable(), _) => Face.ownerUnreadable,
    (_, SignedOut()) => Face.signedOut,
    (OwnedBy(account: final whose), SignedInAs(:final account))
        when whose != account =>
      tally.standing == Standing.held
          ? Face.heldForAnotherAccount
          : Face.notThisAccount,
    _ => _ownFace(tally, network),
  };
  return face == null ? const AllSaved() : Outstanding(face, tally);
}

Face? _ownFace(Tally tally, Network network) => switch (tally) {
  Tally(standing: Standing.deletedOnServer) => Face.deletedOnServer,
  Tally(standing: Standing.editAccessLost) => Face.editAccessLost,
  Tally(standing: Standing.held) => Face.unreadableWork,
  Tally(unreadable: > 0) => Face.unreadableWork,
  Tally(needingYou: > 0) => Face.needsYou,
  Tally(total: 0) => null,
  Tally(standing: Standing.upgradeRequired) => Face.upgradeRequired,
  _ when network == Network.offline => Face.offline,
  Tally(:final waiting) when waiting.containsKey(Underway.answerUnknown) =>
    Face.answerUnknown,
  Tally(:final waiting)
      when waiting.containsKey(Underway.unsent) ||
          waiting.containsKey(Underway.sending) =>
    Face.sending,
  _ => Face.awaitingResult,
};

typedef OwnedTally = ({CloudOwner owner, Tally tally});

sealed class AccountSync {
  AccountSync({
    required Map<Account, Tally> others,
    required this.ownerUnreadable,
  }) : others = Map.unmodifiable(others);

  final Map<Account, Tally> others;
  final Tally ownerUnreadable;
}

final class SignedInSync extends AccountSync {
  SignedInSync({
    required this.account,
    required this.mine,
    required super.others,
    required super.ownerUnreadable,
  });

  final Account account;
  final SyncState mine;

  @override
  String toString() =>
      'SignedInSync(${account.subject}, mine: $mine, others: $others, '
      'ownerUnreadable: $ownerUnreadable)';
}

final class SignedOutSync extends AccountSync {
  SignedOutSync({required super.others, required super.ownerUnreadable});

  @override
  String toString() =>
      'SignedOutSync(others: $others, ownerUnreadable: $ownerUnreadable)';
}

AccountSync accountSyncState(
  Iterable<OwnedTally> strategies, {
  required Network network,
  required SignedIn signedIn,
}) {
  final signedInAs = switch (signedIn) {
    SignedInAs(:final account) => account,
    SignedOut() => null,
  };
  var mine = Tally.empty;
  var ownerUnreadable = Tally.empty;
  final others = <Account, Tally>{};
  for (final (:owner, :tally) in strategies) {
    switch (owner) {
      case OwnedBy(:final account) when account == signedInAs:
        mine = mine.plus(tally);
      case OwnedBy(:final account) when tally.total > 0:
        others[account] = (others[account] ?? Tally.empty).plus(tally);
      case OwnedBy():
        break;
      case OwnerUnreadable():
        ownerUnreadable = ownerUnreadable.plus(tally);
    }
  }
  return switch (signedInAs) {
    final account? => SignedInSync(
      account: account,
      mine: syncStateOf(
        OwnedBy(account),
        mine,
        network: network,
        signedIn: signedIn,
      ),
      others: others,
      ownerUnreadable: ownerUnreadable,
    ),
    null => SignedOutSync(others: others, ownerUnreadable: ownerUnreadable),
  };
}

final class QueueLook {
  QueueLook(this.queue, this.now)
    : views = entryViews(queue, now),
      tally = Tally.of(queue, now);

  final CloudQueue queue;
  final DateTime now;
  final Map<String, EntryView> views;
  final Tally tally;
}

QueueLook look(CloudQueue queue, DateTime now) =>
    QueueLook(recordExpiries(queue, now), now);
