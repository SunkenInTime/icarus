import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/browser_paste.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';

/// A picture read from the clipboard.
class ClipboardImage {
  ClipboardImage(this.bytes, {required this.name, Future<Uint8List>? saved})
      : saved = saved ?? pngOfBitmap(bytes);

  /// The clipboard's own bytes, ready to show straight away.
  final Uint8List bytes;

  /// The bytes to save: see [pngOfBitmap]. Show [bytes] rather than swap to
  /// these, or the picture flashes when they arrive.
  final Future<Uint8List> saved;

  final String name;
}

/// The same picture as a PNG when [bytes] are a bitmap, and [bytes] themselves
/// otherwise, or when they can't be made smaller. Never throws: the picture
/// matters more than its size.
///
/// Windows hands clipboard pictures over as raw bitmaps, 8.3 MB for a 1080p
/// screenshot and too large for a cloud strategy at 4K. The engine reads the
/// bitmap, so the PNG holds exactly what the bitmap draws as: a 32-bit
/// bitmap's fourth channel is usually padding, and the decoder knows when it
/// is. Its own PNG encoder would be simpler, but on a GPU image it keeps an
/// alpha channel an opaque picture doesn't need, and 4K screenshots are close
/// enough to the cloud limit for that to matter.
Future<Uint8List> pngOfBitmap(Uint8List bytes) async {
  if (bytes.length < 2 || bytes[0] != 0x42 || bytes[1] != 0x4D) return bytes;
  try {
    final png = await _encodePng(bytes).timeout(const Duration(seconds: 15));
    return png.length < bytes.length ? png : bytes;
  } catch (error, stackTrace) {
    AppErrorReporter.reportError(
      'Could not make a PNG of a pasted bitmap: $error',
      error: error,
      stackTrace: stackTrace,
      source: 'clipboard_service.png_of_bitmap',
      promptUser: false,
    );
    return bytes;
  }
}

Future<Uint8List> _encodePng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final image = frame.image;
  try {
    final pixels = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    return await compute(
      _pngOfPixels,
      (
        width: image.width,
        height: image.height,
        rgba: pixels!.buffer.asUint8List(),
      ),
    );
  } finally {
    image.dispose();
  }
}

Uint8List _pngOfPixels(({int width, int height, Uint8List rgba}) picture) {
  final rgba = picture.rgba;
  var opaque = true;
  for (var i = 3; opaque && i < rgba.length; i += 4) {
    opaque = rgba[i] == 255;
  }
  var pixels = rgba;
  if (opaque) {
    pixels = Uint8List(rgba.length ~/ 4 * 3);
    for (var from = 0, to = 0; from < rgba.length; from += 4, to += 3) {
      pixels[to] = rgba[from];
      pixels[to + 1] = rgba[from + 1];
      pixels[to + 2] = rgba[from + 2];
    }
  }
  // Of PNG's single filters, average came out smallest on game screenshots.
  return img.PngEncoder(filter: img.PngFilter.average).encode(
    img.Image.fromBytes(
      width: picture.width,
      height: picture.height,
      bytes: pixels.buffer,
      numChannels: opaque ? 3 : 4,
    ),
  );
}

/// Another program kept the clipboard open for as long as we waited. Nothing
/// is known about what's on it.
class ClipboardBusyException implements Exception {}

class ClipboardService {
  static const _name = 'Clipboard File';

  /// What to tell someone when the clipboard stayed busy.
  static const busyMessage =
      'Another program is using the clipboard. Try again in a moment.';

  /// Programs open the clipboard for a moment whenever it changes: clipboard
  /// managers, screen sharing, Deskflow. Windows then refuses everyone else.
  static const _busyWait = Duration(seconds: 2);
  static const _busyRetry = Duration(milliseconds: 100);

  /// A clipboard refused by Windows is a [PlatformException], from Flutter's
  /// clipboard and the pasteboard plugin alike.
  static Future<T> _whenFree<T>(Future<T> Function() use) async {
    final waited = Stopwatch()..start();
    while (true) {
      try {
        return await use();
      } on PlatformException {
        if (waited.elapsed >= _busyWait) throw ClipboardBusyException();
        await Future<void>.delayed(_busyRetry);
      }
    }
  }

  /// The clear in progress, if any: a paste right after a copy waits for it,
  /// or it could find the picture the copy replaced.
  static Future<void> _cleared = Future.value();

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

  /// The picture the paste shortcut was just pressed for, if there is one.
  /// A browser hands it to the page with the key press, without asking for
  /// permission. Everywhere else, and for a key the browser doesn't take for
  /// a paste, it's read from the clipboard.
  static Future<ClipboardImage?> readPastedImage() async {
    final browserPaste = nextBrowserPaste();
    await _cleared;
    final paste = await browserPaste;
    if (paste == null) return trySelectImageFromClipboard();
    final picture = paste.picture;
    return picture == null ? null : ClipboardImage(picture, name: _name);
  }

  /// Empties the system clipboard. It never throws: what's left behind only
  /// matters to a later paste.
  static Future<void> clear() => _cleared = _clear();

  static Future<void> _clear() async {
    try {
      await _whenFree(
        () => Clipboard.setData(const ClipboardData(text: '')),
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Could not clear the clipboard: $error',
        error: error,
        stackTrace: stackTrace,
        source: 'clipboard_service.clear',
        promptUser: false,
      );
    }
  }

  /// The picture on the clipboard, or a copied picture file, or null when
  /// there is neither. Throws [ClipboardBusyException] when it can't tell.
  static Future<ClipboardImage?> trySelectImageFromClipboard() async {
    try {
      final image = await _whenFree(() => Pasteboard.image);
      if (image != null) return ClipboardImage(image, name: _name);

      final files = await _whenFree(Pasteboard.files);
      if (files.isEmpty) return null;
      final file = files.first;
      if (!isSupportedImageClipboardFile(file)) return null;
      final bytes = await XFile(file).readAsBytes();
      return ClipboardImage(bytes, name: _name);
    } on ClipboardBusyException {
      rethrow;
    } catch (_) {
      return null;
    }
  }
}
