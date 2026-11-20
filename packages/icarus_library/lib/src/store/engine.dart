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

final class EngineClosed extends StorageFailure {
  const EngineClosed();

  @override
  String toString() => 'EngineClosed()';
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

  Future<Committing> commit(List<Change> changes);

  Future<Releasing> release();
}

typedef StoredEntry = ({String key, String value});

sealed class Change {
  const Change(this.area);

  final String area;
}

final class Put extends Change {
  const Put(super.area, this.key, this.value);

  final String key;
  final String value;
}

final class Delete extends Change {
  const Delete(super.area, this.key);

  final String key;
}

final class ClearArea extends Change {
  const ClearArea(super.area);
}

sealed class Committing {
  const Committing();
}

final class CommitApplied extends Committing {
  const CommitApplied();
}

final class CommitRefused extends Committing {
  const CommitRefused(this.failure);

  final StorageFailure failure;

  @override
  String toString() => 'CommitRefused($failure)';
}

final class CommitUnknown extends Committing {
  const CommitUnknown(this.failure);

  final StorageFailure failure;

  @override
  String toString() => 'CommitUnknown($failure)';
}

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

const nameAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789-./_';

bool isName(String name) =>
    name.codeUnits.every((unit) => nameAlphabet.codeUnits.contains(unit));

const done = Done<void>(null);
