import '../store/engine.dart';

StorageFailure? refusedName(List<Change> changes, int maxKeyLength) {
  for (final change in changes) {
    final key = switch (change) {
      Put(:final key) || Delete(:final key) => key,
      ClearArea() => null,
    };
    if (!isArea(change.area) || (key != null && !isName(key))) {
      return NameNotAllowed(change.area, key ?? '');
    }
    if (key != null && key.length > maxKeyLength) {
      return KeyTooLong(change.area, key);
    }
  }
  return null;
}

bool pastLimit(String area, String key, int maxKeyLength) =>
    area.length > maxAreaLength || key.length > maxKeyLength;
