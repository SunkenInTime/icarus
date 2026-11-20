sealed class Stored<T> {
  const Stored();
}

final class Done<T> extends Stored<T> {
  const Done(this.value);

  final T value;
}

final class StorageFailed<T> extends Stored<T> {
  const StorageFailed(this.failure);

  final StorageFailure failure;
}

sealed class StorageFailure {
  const StorageFailure();
}

final class DeviceFailure extends StorageFailure {
  const DeviceFailure(this.message);

  final String message;

  @override
  String toString() => 'DeviceFailure($message)';
}

final class KeyTooLong extends StorageFailure {
  const KeyTooLong(this.area, this.key);

  final String area;
  final String key;

  @override
  String toString() => 'KeyTooLong($area, $key)';
}

final class LeaseEnded extends StorageFailure {
  const LeaseEnded();

  @override
  String toString() => 'LeaseEnded()';
}

final class StoreStopped extends StorageFailure {
  const StoreStopped(this.cause);

  final StorageFailure cause;

  @override
  String toString() => 'StoreStopped($cause)';
}

final class StoreClosed extends StorageFailure {
  const StoreClosed();

  @override
  String toString() => 'StoreClosed()';
}

abstract interface class StorageEngine {
  Future<Leasing> lease();
}

sealed class Leasing {
  const Leasing();
}

final class Leased extends Leasing {
  const Leased(this.lease);

  final StorageLease lease;
}

final class HeldByAnotherWriter extends Leasing {
  const HeldByAnotherWriter();
}

final class LeaseFailed extends Leasing {
  const LeaseFailed(this.failure);

  final StorageFailure failure;
}

abstract interface class StorageLease {
  int get maxKeyLength;

  LeaseStatus get status;

  Future<KeyRead> read(String area, String key);

  Future<Stored<List<String>>> keys(String area, String prefix);

  Future<Stored<List<StoredEntry>>> entries(String area, String prefix);

  Future<Stored<void>> write(String area, Map<String, String> values);

  Future<Stored<void>> delete(String area, Iterable<String> keys);

  Future<Releasing> release();
}

typedef StoredEntry = ({String key, String value});

sealed class KeyRead {
  const KeyRead();
}

final class KeyHeld extends KeyRead {
  const KeyHeld(this.value);

  final String value;
}

final class KeyMissing extends KeyRead {
  const KeyMissing();
}

final class KeyNotRead extends KeyRead {
  const KeyNotRead(this.failure);

  final StorageFailure failure;
}

sealed class LeaseStatus {
  const LeaseStatus();
}

final class Holding extends LeaseStatus {
  const Holding();
}

final class Ended extends LeaseStatus {
  const Ended();
}

sealed class Releasing {
  const Releasing();
}

final class Released extends Releasing {
  const Released();
}

final class ReleaseFailed extends Releasing {
  const ReleaseFailed(this.failure);

  final StorageFailure failure;
}

const maxAreaLength = 64;

const done = Done<void>(null);
