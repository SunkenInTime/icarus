import 'dart:typed_data';

import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';

/// Image bytes waiting to upload, on a device that keeps no image files
/// (web). Keyed by asset ID. The upload job itself lives in the media
/// outbox; this holds only the bytes that job sends.
abstract class PendingMediaBytesStore {
  Map<String, Uint8List> load();
  Future<void> put(String assetId, Uint8List bytes);
  Future<void> remove(String assetId);
}

/// Browser storage (IndexedDB through Hive), so a refresh mid-upload keeps
/// the image. The box is opened at startup only where images are not files.
class HivePendingMediaBytesStore implements PendingMediaBytesStore {
  Box<Uint8List> get _box =>
      Hive.box<Uint8List>(HiveBoxNames.pendingMediaBytesBox);

  @override
  Map<String, Uint8List> load() => {
        for (final key in _box.keys)
          if (_box.get(key) case final bytes?) key.toString(): bytes,
      };

  @override
  Future<void> put(String assetId, Uint8List bytes) =>
      _box.put(assetId, bytes);

  @override
  Future<void> remove(String assetId) => _box.delete(assetId);
}

/// Keeps nothing across launches. Where images are files nothing is ever put
/// here. Tests share one instance between containers to act as a browser
/// that survives a refresh.
class MemoryPendingMediaBytesStore implements PendingMediaBytesStore {
  MemoryPendingMediaBytesStore([Map<String, Uint8List>? initialValues])
      : values = Map<String, Uint8List>.from(initialValues ?? const {});

  final Map<String, Uint8List> values;

  @override
  Map<String, Uint8List> load() => Map<String, Uint8List>.from(values);

  @override
  Future<void> put(String assetId, Uint8List bytes) async {
    values[assetId] = bytes;
  }

  @override
  Future<void> remove(String assetId) async {
    values.remove(assetId);
  }
}
