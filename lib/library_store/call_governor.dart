import 'dart:async';

import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/landed_retiring.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/stall_exits.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus_library/icarus_library.dart';

final class CannotRead {
  const CannotRead(this.why);

  final String why;

  @override
  String toString() => 'the server will not let this account read it: $why';
}

typedef ReadsUnder = ({Account? account, int? connection, int signOuts});

typedef Rung = ({int count, DateTime at, StallExit why});

typedef AccessRung = ({
  Account account,
  int signIns,
  int count,
  DateTime at,
  CannotRead? cannot,
});

typedef ReadMemory = ({
  ReadsUnder under,
  Map<String, Rung> settle,
  RetireReads retired,
});

ReadsUnder readsUnder(Snapshot snap) => (
      account: snap.account,
      connection: snap.connection,
      signOuts: snap.signOuts,
    );

ReadMemory freshReads(ReadsUnder under) => (
      under: under,
      settle: const {},
      retired: const {},
    );

extension ReadMemoryChanges on ReadMemory {
  ReadMemory climbed(String read, DateTime at, StallExit why) => (
        under: under,
        settle: {
          ...settle,
          read: (count: (settle[read]?.count ?? 0) + 1, at: at, why: why),
        },
        retired: retired,
      );

  ReadMemory keeping(bool Function(String read, Rung rung) keep) => (
        under: under,
        settle: {
          for (final MapEntry(:key, :value) in settle.entries)
            if (keep(key, value)) key: value,
        },
        retired: retired,
      );

  ReadMemory withRetired(RetireReads retired) =>
      (under: under, settle: settle, retired: retired);
}

sealed class ReadOf {
  const ReadOf();
}

final class ReadOfList extends ReadOf {
  const ReadOfList();

  @override
  bool operator ==(Object other) => other is ReadOfList;

  @override
  int get hashCode => (ReadOfList).hashCode;

  @override
  String toString() => 'the page list';
}

final class ReadOfPage extends ReadOf {
  const ReadOfPage(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is ReadOfPage && other.page == page;

  @override
  int get hashCode => Object.hash(ReadOfPage, page);

  @override
  String toString() => 'page $page';
}

sealed class ReadWhen {
  const ReadWhen();
}

final class ReadFrom extends ReadWhen {
  const ReadFrom(this.at, this.why);

  final DateTime? at;
  final StallExit? why;
}

final class ReadStopped extends ReadWhen {
  const ReadStopped(this.why);

  final StallExit why;
}

typedef HeldResult = ({
  StoreReadOutcome outcome,
  DateTime started,
  ReadsUnder under,
  ({int? requestedAt, int session})? read,
});

sealed class Issued {
  const Issued();
}

final class NotYet extends Issued {
  const NotYet(this.at, this.why);

  final DateTime? at;
  final StallExit? why;
}

final class Answered extends Issued {
  const Answered(this.outcome, {required this.started});

  final StoreReadOutcome outcome;
  final DateTime started;
}

final class CallGovernor {
  CallGovernor({
    required StoreReads reads,
    required SenderTiming timing,
    required StoreBatchSend send,
    required DateTime Function() clock,
    required String? Function() editorShows,
  })  : _reads = reads,
        _send = send,
        _timing = timing,
        _clock = clock,
        _editorShows = editorShows;

  final StoreReads _reads;
  final StoreBatchSend _send;
  final String? Function() _editorShows;
  final SenderTiming _timing;
  final DateTime Function() _clock;

  final _issuedAt = <(String, ReadOf), DateTime>{};
  final _memory = <String, ReadMemory>{};
  final _access = <String, AccessRung>{};
  final _held = <(String, ReadOf), HeldResult>{};
  final _fresh = <(String, ReadOf)>{};
  final _kept = <(String, Object), QueueEvent>{};
  final _sentAt = <String, DateTime>{};
  String? _opened;
  var issued = 0;
  var batches = 0;

  ReadMemory memory(String id, ReadsUnder under) => switch (_memory[id]) {
        final kept? when kept.under == under => kept,
        _ => freshReads(under),
      };

  ReadMemory bind(String id, ReadsUnder under) =>
      _memory[id] = memory(id, under);

  void remember(String id, ReadMemory memory) => _memory[id] = memory;

  void keepRungs(String id, ReadsUnder under, Set<String> still) {
    final kept = memory(id, under);
    if (kept.settle.keys.any((read) => !still.contains(read))) {
      _memory[id] = kept.keeping((read, _) => still.contains(read));
    }
  }

  void under(ReadsUnder under) {
    _memory.removeWhere((_, memory) => memory.under != under);
    _held.removeWhere((_, held) => held.under != under);
  }

  void keepOnly(bool Function(String id) keep) {
    _memory.removeWhere((id, _) => !keep(id));
    _held.removeWhere((key, _) => !keep(key.$1));
    _fresh.removeWhere((key) => !keep(key.$1));
    _kept.removeWhere((key, _) => !keep(key.$1));
    final now = _clock();
    _issuedAt.removeWhere((_, at) => !at.add(_timing.readFloor).isAfter(now));
  }

  AccessRung? access(String id, Snapshot snap) => switch (_access[id]) {
        final rung?
            when rung.account == snap.account && rung.signIns == snap.signIns =>
          rung,
        _ => null,
      };

  bool accessStopped(String id, Snapshot snap) => switch (access(id, snap)) {
        (:final count, at: _, cannot: _, account: _, signIns: _) =>
          _editorShows() != id && _timing.accessAfter(count) == null,
        null => false,
      };

  void climbAccess(String id, Snapshot snap, CannotRead? cannot) {
    final kept = access(id, snap);
    _access[id] = (
      account: snap.account!,
      signIns: snap.signIns,
      count: (kept?.count ?? 0) + 1,
      at: _clock(),
      cannot: cannot,
    );
  }

  void accessConfirmed(String id) => _access.remove(id);

  void newEvidence(String id, [Set<ReadOf>? about]) {
    if (about == null || about.contains(const ReadOfList())) {
      _access.remove(id);
    }
    if (_memory[id] case final kept? when kept.settle.isNotEmpty) {
      _memory[id] = kept.keeping(
        (read, rung) =>
            about != null && !about.any((subject) => '$subject' == read),
      );
    }
  }

  void userOpened(String? id) {
    if (id == _opened) return;
    _opened = id;
    if (id != null) _access.remove(id);
  }

  Set<ReadOf> owedFresh(String id) => {
        for (final (owner, read) in _fresh)
          if (owner == id) read,
      };

  void keep(String id, Object subject, QueueEvent write) =>
      _kept[(id, subject)] = write;

  Map<Object, QueueEvent> kept(String id) => {
        for (final MapEntry(key: (owner, subject), :value) in _kept.entries)
          if (owner == id) subject: value,
      };

  Set<String> get keeping => {for (final (id, _) in _kept.keys) id};

  void keptWritten(String id, Object subject) => _kept.remove((id, subject));

  ReadWhen readAt(String id, ReadOf read, Snapshot snap) {
    final access = this.access(id, snap);
    final accessRow =
        access?.cannot == null ? StallExit.viewerOnly : StallExit.forbidden;
    if (accessStopped(id, snap)) return ReadStopped(accessRow);
    DateTime? at;
    StallExit? why;
    void notBefore(DateTime time, StallExit? row) {
      if (at == null || time.isAfter(at!)) {
        at = time;
        why = row;
      }
    }

    if (_issuedAt[(id, read)] case final last?) {
      notBefore(last.add(_timing.readFloor), null);
    }
    if (memory(id, readsUnder(snap)).settle['$read']
        case (:final count, :final at, :final why)) {
      notBefore(at.add(_timing.settleAfter(count)), why);
    }
    if (access
        case (:final count, :final at, cannot: _, account: _, signIns: _)) {
      notBefore(
        at.add(_timing.accessAfter(count) ?? _timing.readAgainAfter),
        accessRow,
      );
    }
    return ReadFrom(at, why);
  }

  HeldResult? heldFor(String id, ReadOf read, ReadsUnder under) =>
      switch (_held[(id, read)]) {
        final held? when held.under == under => held,
        _ => null,
      };

  void hold(String id, ReadOf read, HeldResult held) =>
      _held[(id, read)] = held;

  void written(String id, ReadOf read, {bool late = false}) {
    _held.remove((id, read));
    if (late) {
      _fresh.add((id, read));
    } else {
      _fresh.remove((id, read));
    }
  }

  DateTime? sendAt(String id) => switch (_sentAt[id]) {
        final last? when last.add(_timing.sendFloor).isAfter(_clock()) =>
          last.add(_timing.sendFloor),
        _ => null,
      };

  Future<StoreBatchOutcome>? send(ClaimedBatch batch) {
    if (sendAt(batch.strategyId) != null) return null;
    _sentAt[batch.strategyId] = _clock();
    batches++;
    return _send(
      strategyPublicId: batch.strategyId,
      clientId: batch.clientId,
      ops: batch.ops,
      lives: batch.lives,
      strategyLife: batch.strategyLife,
      account: batch.account,
      serverTime: ServerTimeAsked(basis: batch.basis),
    );
  }

  Future<Issued> issue(
    String id,
    Account account,
    ReadOf read,
    Snapshot snap,
  ) async {
    final now = _clock();
    switch (readAt(id, read, snap)) {
      case ReadStopped(:final why):
        return NotYet(null, why);
      case ReadFrom(:final at?, :final why) when at.isAfter(now):
        return NotYet(at, why);
      case ReadFrom():
        break;
    }
    _issuedAt[(id, read)] = now;
    issued++;
    try {
      final outcome = await Future<StoreReadOutcome>.sync(
        () => switch (read) {
          ReadOfList() =>
            _reads.pageList(strategyPublicId: id, account: account),
          ReadOfPage(:final page) => _reads.page(
              strategyPublicId: id,
              pagePublicId: page,
              account: account,
            ),
        },
      ).then((outcome) => outcome).timeout(
            _timing.giveUpAfter,
            onTimeout: () => StoreReadLost(
              TransportFailure.timeout,
              'no answer within ${_timing.giveUpAfter.inSeconds} s',
            ),
          );
      return Answered(outcome, started: now);
    } catch (error) {
      return Answered(
        StoreReadLost(TransportFailure.network, 'the read threw: $error'),
        started: now,
      );
    }
  }
}
