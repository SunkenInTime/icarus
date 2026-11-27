import 'package:icarus_library/icarus_library.dart';

final class SlowedEngine implements StorageEngine {
  SlowedEngine(this._inner);

  static var commitDelay = Duration.zero;
  static var waitedMicros = 0;

  final StorageEngine _inner;

  @override
  Future<Leasing> lease() async => switch (await _inner.lease()) {
        Leased(:final lease) => Leased(_SlowedLease(lease)),
        final other => other,
      };
}

final class _SlowedLease implements StorageLease {
  _SlowedLease(this._inner);

  final StorageLease _inner;

  Future<T> _waited<T>(Future<T> asked) async {
    final clock = Stopwatch()..start();
    try {
      return await asked;
    } finally {
      SlowedEngine.waitedMicros += clock.elapsedMicroseconds;
    }
  }

  @override
  int get maxKeyLength => _inner.maxKeyLength;

  @override
  LeaseStatus get status => _inner.status;

  @override
  Future<KeyRead> read(String area, String key) =>
      _waited(_inner.read(area, key));

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      _waited(_inner.keys(area, prefix));

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _waited(_inner.entries(area, prefix));

  @override
  Future<Stored<List<String>>> areas(String prefix) => _inner.areas(prefix);

  @override
  Future<Committing> commit(List<Change> changes) async {
    final delay = SlowedEngine.commitDelay;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return _waited(_inner.commit(changes));
  }

  @override
  Future<Releasing> release() => _inner.release();
}
