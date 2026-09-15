import 'dart:collection';
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';

/// Owned, immutable compressed bytes matching the offline bundle's hashes.
/// Verification runs once on the loader isolate. A cached block can then be
/// inflated again without repeating a Dart CRC scan on the rendering thread.
final class VerifiedWorldChunks extends UnmodifiableMapView<String, Uint8List> {
  VerifiedWorldChunks._(super.source);

  static Future<VerifiedWorldChunks> verify(
      Map<String, dynamic> manifest, Map<String, Uint8List> chunks) async {
    final descriptors = manifest['chunks'];
    if (descriptors is! List || descriptors.isEmpty) {
      throw const FormatException('Missing world chunk hashes.');
    }
    final owned = <String, Uint8List>{};
    for (final descriptor in descriptors) {
      final name =
          descriptor is Map<String, dynamic> ? descriptor['asset'] : null;
      final expected =
          descriptor is Map<String, dynamic> ? descriptor['sha256'] : null;
      if (name is! String ||
          owned.containsKey(name) ||
          !chunks.containsKey(name) ||
          expected is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expected)) {
        throw const FormatException('Invalid world chunk hash descriptor.');
      }
      final bytes = Uint8List.fromList(chunks[name]!);
      final actual = (await Sha256().hash(bytes))
          .bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (actual != expected.toLowerCase()) {
        throw FormatException('World chunk checksum mismatch: $name.');
      }
      owned[name] = bytes.asUnmodifiableView();
    }
    if (owned.length != chunks.length) {
      throw const FormatException('Unexpected world chunk payload.');
    }
    return VerifiedWorldChunks._(owned);
  }
}
