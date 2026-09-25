import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/pending_media_bytes_store.dart';
import 'package:icarus/services/local_image_file.dart';

/// The bytes one cloud media upload sends.
sealed class MediaBytesSource {
  const MediaBytesSource();

  Future<int> length();
  Stream<List<int>> openRead();
}

/// The image file in the strategy's image folder (desktop). File access
/// stays in the native half of `local_image_file.dart`.
final class FileMediaBytes extends MediaBytesSource {
  const FileMediaBytes(this.path);
  final String path;

  @override
  Future<int> length() => localImageFileLength(path);

  @override
  Stream<List<int>> openRead() => readLocalImageFile(path);
}

/// Bytes held for an image that is not a file on this device (web).
final class MemoryMediaBytes extends MediaBytesSource {
  const MemoryMediaBytes(this.bytes);
  final Uint8List bytes;

  @override
  Future<int> length() async => bytes.length;

  @override
  Stream<List<int>> openRead() => Stream.value(bytes);
}

/// Whether this device keeps strategy images as files. Where it does not
/// (web), a picked image waits in [pendingMediaBytesProvider] until it has
/// uploaded. Override with false to exercise the web path in tests.
final imageFilesOnDeviceProvider = Provider<bool>((ref) => deviceHasImageFiles);

final pendingMediaBytesStoreProvider = Provider<PendingMediaBytesStore>(
  (ref) => ref.watch(imageFilesOnDeviceProvider)
      ? MemoryPendingMediaBytesStore()
      : HivePendingMediaBytesStore(),
);

/// The largest image a cloud strategy takes: the server's default
/// `R2_MAX_IMAGE_BYTES` (`convex/lib/r2.ts`). Checked before bytes are kept,
/// so the browser never stores an image that can never upload.
const maxCloudImageBytes = 15 * 1024 * 1024;

class MediaTooLargeException implements Exception {
  const MediaTooLargeException(this.byteSize);
  final int byteSize;

  String get userMessage => 'This image is over 15 MB. Pick a smaller one.';

  @override
  String toString() =>
      'Image is $byteSize bytes; the limit is $maxCloudImageBytes.';
}

final pendingMediaBytesProvider =
    NotifierProvider<PendingMediaBytesNotifier, Map<String, Uint8List>>(
  PendingMediaBytesNotifier.new,
);

/// Image bytes, by [pendingMediaStorageKey], for images that are not files
/// on this device and not yet painted from the cloud. The editor paints them
/// while they upload; the media upload queue sends them.
class PendingMediaBytesNotifier extends Notifier<Map<String, Uint8List>> {
  /// A draft (a lineup image picked but not saved) has no upload job, and
  /// another tab of this browser may still be editing it. Only a draft this
  /// old is taken as abandoned.
  static const abandonedAfter = Duration(days: 7);

  late PendingMediaBytesStore _store;
  // Served from the cloud URL while the upload was still attaching.
  final Set<String> _servedFromCloud = {};

  @override
  Map<String, Uint8List> build() {
    _store = ref.watch(pendingMediaBytesStoreProvider);
    _servedFromCloud.clear();
    return Map.unmodifiable({
      for (final record in _store.load())
        pendingMediaStorageKey(record.key): record.bytes,
    });
  }

  Uint8List? bytesFor(PendingMediaKey key) =>
      state[pendingMediaStorageKey(key)];

  /// Saves [bytes] before any upload job names [key], so no job ever waits
  /// on bytes that were never stored.
  Future<void> put(PendingMediaKey key, Uint8List bytes) async {
    if (bytes.length > maxCloudImageBytes) {
      throw MediaTooLargeException(bytes.length);
    }
    await _store.put(
      PendingMediaRecord(key: key, bytes: bytes, savedAt: DateTime.now()),
    );
    final storageKey = pendingMediaStorageKey(key);
    _servedFromCloud.remove(storageKey);
    state = Map.unmodifiable({...state, storageKey: bytes});
  }

  /// The upload attached, so a reload no longer needs these bytes. The
  /// editor keeps painting them until the cloud URL arrives, unless it
  /// already has.
  Future<void> markAttached(PendingMediaKey key) async {
    await _store.remove(key);
    final storageKey = pendingMediaStorageKey(key);
    if (_servedFromCloud.remove(storageKey)) _forget(storageKey);
  }

  /// The page serves [key]'s image from its cloud URL while its upload is
  /// still attaching. The bytes go when the attach lands.
  void markServedFromCloud(PendingMediaKey key) {
    final storageKey = pendingMediaStorageKey(key);
    if (state.containsKey(storageKey)) _servedFromCloud.add(storageKey);
  }

  Future<void> remove(PendingMediaKey key) async {
    await _store.remove(key);
    _forget(pendingMediaStorageKey(key));
  }

  /// Drops stored bytes that no upload job needs and that are older than
  /// [abandonedAfter], so a draft another tab is editing survives.
  Future<void> pruneAbandoned({
    required bool Function(PendingMediaKey key) hasJob,
  }) async {
    final cutoff = DateTime.now().subtract(abandonedAfter);
    for (final record in _store.load()) {
      if (hasJob(record.key) || record.savedAt.isAfter(cutoff)) continue;
      await remove(record.key);
    }
  }

  void _forget(String storageKey) {
    _servedFromCloud.remove(storageKey);
    if (!state.containsKey(storageKey)) return;
    state = Map.unmodifiable({...state}..remove(storageKey));
  }
}
