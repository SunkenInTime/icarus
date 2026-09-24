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

final pendingMediaBytesProvider =
    NotifierProvider<PendingMediaBytesNotifier, Map<String, Uint8List>>(
  PendingMediaBytesNotifier.new,
);

/// Image bytes by asset ID for images that are not files on this device and
/// not yet painted from the cloud. The editor paints them while they upload;
/// the media upload queue sends them.
class PendingMediaBytesNotifier extends Notifier<Map<String, Uint8List>> {
  late PendingMediaBytesStore _store;
  final Set<String> _restoredIds = {};

  @override
  Map<String, Uint8List> build() {
    _store = ref.watch(pendingMediaBytesStoreProvider);
    final loaded = _store.load();
    _restoredIds
      ..clear()
      ..addAll(loaded.keys);
    return Map.unmodifiable(loaded);
  }

  /// Saves [bytes] before any upload job names [assetId], so no job ever
  /// waits on bytes that were never stored.
  Future<void> put(String assetId, Uint8List bytes) async {
    await _store.put(assetId, bytes);
    _restoredIds.remove(assetId);
    state = Map.unmodifiable({...state, assetId: bytes});
  }

  /// The cloud has the image, so a reload no longer needs these bytes. The
  /// editor keeps painting them until the cloud URL arrives.
  Future<void> markUploaded(String assetId) => _store.remove(assetId);

  Future<void> remove(String assetId) async {
    await _store.remove(assetId);
    _restoredIds.remove(assetId);
    if (!state.containsKey(assetId)) return;
    state = Map.unmodifiable({...state}..remove(assetId));
  }

  /// Drops bytes left by an earlier session that no upload job needs: an
  /// image picked for a lineup that was never saved, or a placement whose
  /// job was never written.
  Future<void> pruneRestored({required Set<String> keep}) async {
    for (final assetId in _restoredIds.difference(keep).toList()) {
      await remove(assetId);
    }
  }
}
