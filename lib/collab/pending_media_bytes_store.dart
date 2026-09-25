import 'dart:typed_data';

import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';

/// Whose image bytes these are: the same account and asset scope as the
/// media outbox, plus the strategy, so one account's cleanup never touches
/// another account's source.
typedef PendingMediaKey = ({
  String accountId,
  String strategyPublicId,
  String assetPublicId,
});

String pendingMediaStorageKey(PendingMediaKey key) => [
      key.accountId,
      key.strategyPublicId,
      key.assetPublicId,
    ].map(Uri.encodeComponent).join('|');

const pendingMediaRecordVersion = 1;

/// Image bytes waiting to upload, on a device that keeps no image files
/// (web). [savedAt] tells an abandoned draft from one another tab is still
/// editing.
class PendingMediaRecord {
  const PendingMediaRecord({
    required this.key,
    required this.bytes,
    required this.savedAt,
  });

  final PendingMediaKey key;
  final Uint8List bytes;
  final DateTime savedAt;
}

/// The upload job lives in the media outbox; this holds only the bytes it
/// sends.
abstract class PendingMediaBytesStore {
  /// Every readable record. Unreadable ones stay stored and are never
  /// pruned.
  List<PendingMediaRecord> load();
  Future<void> put(PendingMediaRecord record);
  Future<void> remove(PendingMediaKey key);
}

/// Browser storage (IndexedDB through Hive), so a refresh mid-upload keeps
/// the image. The box is opened at startup only where images are not files.
class HivePendingMediaBytesStore implements PendingMediaBytesStore {
  Box<dynamic> get _box =>
      Hive.box<dynamic>(HiveBoxNames.pendingMediaBytesBox);

  @override
  List<PendingMediaRecord> load() => [
        for (final entry in _box.toMap().entries)
          if (_recordFromJson(entry.value) case final record?
              when pendingMediaStorageKey(record.key) == '${entry.key}')
            record,
      ];

  @override
  Future<void> put(PendingMediaRecord record) =>
      _box.put(pendingMediaStorageKey(record.key), _recordToJson(record));

  @override
  Future<void> remove(PendingMediaKey key) =>
      _box.delete(pendingMediaStorageKey(key));
}

/// Keeps nothing across launches. Where images are files nothing is ever put
/// here. Tests share one instance between containers to act as a browser
/// that survives a refresh.
class MemoryPendingMediaBytesStore implements PendingMediaBytesStore {
  MemoryPendingMediaBytesStore([Iterable<PendingMediaRecord> records = const []])
      : values = {
          for (final record in records)
            pendingMediaStorageKey(record.key): record,
        };

  final Map<String, PendingMediaRecord> values;

  @override
  List<PendingMediaRecord> load() => values.values.toList();

  @override
  Future<void> put(PendingMediaRecord record) async {
    values[pendingMediaStorageKey(record.key)] = record;
  }

  @override
  Future<void> remove(PendingMediaKey key) async {
    values.remove(pendingMediaStorageKey(key));
  }
}

Map<String, dynamic> _recordToJson(PendingMediaRecord record) => {
      'version': pendingMediaRecordVersion,
      'accountId': record.key.accountId,
      'strategyPublicId': record.key.strategyPublicId,
      'assetPublicId': record.key.assetPublicId,
      'savedAt': record.savedAt.toUtc().toIso8601String(),
      'bytes': record.bytes,
    };

PendingMediaRecord? _recordFromJson(Object? value) {
  if (value is! Map) return null;
  final accountId = value['accountId'];
  final strategyPublicId = value['strategyPublicId'];
  final assetPublicId = value['assetPublicId'];
  final savedAt = DateTime.tryParse('${value['savedAt']}');
  final bytes = value['bytes'];
  if (value['version'] != pendingMediaRecordVersion ||
      accountId is! String ||
      strategyPublicId is! String ||
      assetPublicId is! String ||
      savedAt == null ||
      bytes is! Uint8List) {
    return null;
  }
  return PendingMediaRecord(
    key: (
      accountId: accountId,
      strategyPublicId: strategyPublicId,
      assetPublicId: assetPublicId,
    ),
    bytes: bytes,
    savedAt: savedAt.toLocal(),
  );
}
