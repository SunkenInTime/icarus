import '../store/engine.dart';

StorageFailure? putPastLimit(List<Change> changes, int maxKeyLength) {
  for (final change in changes) {
    if (change case Put(
      :final area,
      :final key,
    ) when area.length > maxAreaLength || key.length > maxKeyLength) {
      return KeyTooLong(area, key);
    }
  }
  return null;
}

bool pastLimit(String area, String key, int maxKeyLength) =>
    area.length > maxAreaLength || key.length > maxKeyLength;
