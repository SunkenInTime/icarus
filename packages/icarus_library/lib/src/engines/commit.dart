import '../store/engine.dart';

sealed class Change {
  const Change(this.area);

  final String area;
}

final class ChangePut extends Change {
  const ChangePut(super.area, this.key, this.value);

  final String key;
  final String value;
}

final class ChangeDelete extends Change {
  const ChangeDelete(super.area, this.key);

  final String key;
}

final class ChangeClearArea extends Change {
  const ChangeClearArea(super.area);
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
}

final class CommitInDoubt extends Committing {
  const CommitInDoubt(this.failure);

  final StorageFailure failure;
}

StorageFailure? nameTooLong(Iterable<Change> changes, int maxKeyLength) {
  for (final change in changes) {
    final key = switch (change) {
      ChangePut(:final key) || ChangeDelete(:final key) => key,
      ChangeClearArea() => '',
    };
    if (change.area.length > maxAreaLength || key.length > maxKeyLength) {
      return KeyTooLong(change.area, key);
    }
  }
  return null;
}

StorageFailure? readTooLong(String area, String key, int maxKeyLength) =>
    area.length > maxAreaLength || key.length > maxKeyLength
    ? KeyTooLong(area, key)
    : null;

Stored<void> storedOf(Committing committing) => switch (committing) {
  CommitApplied() => done,
  CommitRefused(:final failure) ||
  CommitInDoubt(:final failure) => StorageFailed(failure),
};
