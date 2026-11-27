import 'dart:async';

import 'package:icarus_library/icarus_library.dart';

final class CommitGate {
  Completer<void>? _held;
  var failNext = false;
  var doubtNext = false;
  var commits = 0;
  var reads = 0;
  var ended = false;
  int? endAfter;

  bool get isHeld => _held != null;

  void hold() => _held ??= Completer<void>();

  void release() {
    _held?.complete();
    _held = null;
  }

  var _waiting = 0;

  Future<void> releaseOne() async {
    while (_waiting == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final held = _held;
    _held = Completer<void>();
    held?.complete();
  }
}

final class GatedEngine implements StorageEngine {
  GatedEngine(this.inner, this.gate);

  final StorageEngine inner;
  final CommitGate gate;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
        Leased(:final lease) => Leased(_GatedLease(lease, gate)),
        final other => other,
      };
}

final class _GatedLease implements StorageLease {
  _GatedLease(this.inner, this.gate);

  final StorageLease inner;
  final CommitGate gate;

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  LeaseStatus get status => gate.ended ? const Ended() : inner.status;

  @override
  Future<KeyRead> read(String area, String key) {
    gate.reads++;
    return gate.ended
        ? Future.value(const KeyNotRead(LeaseEnded()))
        : inner.read(area, key);
  }

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) {
    gate.reads++;
    return gate.ended
        ? Future.value(const StorageFailed(LeaseEnded()))
        : inner.keys(area, prefix);
  }

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) {
    gate.reads++;
    return gate.ended
        ? Future.value(const StorageFailed(LeaseEnded()))
        : inner.entries(area, prefix);
  }

  @override
  Future<Stored<List<String>>> areas(String prefix) => gate.ended
      ? Future.value(const StorageFailed(LeaseEnded()))
      : inner.areas(prefix);

  @override
  Future<Committing> commit(List<Change> changes) async {
    gate.commits++;
    if (gate.endAfter case final last? when gate.commits > last) {
      gate.ended = true;
    }
    if (gate._held case final held?) {
      gate._waiting++;
      await held.future;
      gate._waiting--;
    }
    if (gate.ended) return const CommitRefused(LeaseEnded());
    if (gate.failNext) {
      gate.failNext = false;
      return const CommitRefused(DeviceFailure('the disk is full'));
    }
    if (gate.doubtNext) {
      gate.doubtNext = false;
      await inner.commit(changes);
      return const CommitUnknown(DeviceFailure('the disk stopped answering'));
    }
    return inner.commit(changes);
  }

  @override
  Future<Releasing> release() => inner.release();
}
