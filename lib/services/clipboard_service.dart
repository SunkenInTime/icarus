import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:pasteboard/pasteboard.dart';

class ClipboardService {
  static const Set<String> _supportedImageExtensions = {
    'gif',
    'webp',
    'png',
    'jpg',
    'jpeg',
    'bmp',
  };

  /// Returns true if [clipboardFile] appears to be a supported image file path/URI.
  ///
  /// Checks file extension only (case-insensitive).
  static bool isSupportedImageClipboardFile(String clipboardFile) {
    final trimmed = clipboardFile.trim();
    if (trimmed.isEmpty) return false;

    // Handle both paths and URIs by just grabbing the "basename".
    final lastSlash = trimmed.lastIndexOf('/');
    final lastBackslash = trimmed.lastIndexOf('\\');
    final cutIndex =
        (lastSlash > lastBackslash ? lastSlash : lastBackslash) + 1;
    final name = cutIndex > 0 && cutIndex < trimmed.length
        ? trimmed.substring(cutIndex)
        : trimmed;

    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return false;

    final ext = name.substring(dot + 1).toLowerCase();
    return _supportedImageExtensions.contains(ext);
  }

  static Future<(Uint8List? bytes, String? name)>
      trySelectImageFromClipboard() async {
    Uint8List? selectedBytes;
    String? selectedName;

    try {
      final clipBoardImages = await Pasteboard.image;
      final clipBoardFiles = await Pasteboard.files();

      if (clipBoardImages != null) {
        selectedBytes = clipBoardImages;
        selectedName = 'Clipboard File';
        return (selectedBytes, selectedName);
      } else if (clipBoardFiles.isNotEmpty) {
        final file = clipBoardFiles.first;
        if (!isSupportedImageClipboardFile(file)) {
          return (null, null);
        }
        final bytes = await XFile(file).readAsBytes();
        selectedBytes = bytes;
        selectedName = 'Clipboard File';
        return (selectedBytes, selectedName);
      } else {
        return (null, null);
      }
    } catch (_) {
      return (null, null);
    }
  }
}
