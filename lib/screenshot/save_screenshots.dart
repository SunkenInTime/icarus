import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:icarus/screenshot/page_screenshot.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:path/path.dart' as p;

/// The file a page's screenshot is saved as: the strategy, then the page's
/// number and name, so a folder of them sorts in page order.
String pageScreenshotFileName(String strategyName, PageScreenshot shot) =>
    '${sanitizeStrategyFileName(strategyName)} - '
    '${shot.number.toString().padLeft(2, '0')} '
    '${sanitizeStrategyFileName(shot.name)}.png';

/// Writes [shots] into [folder], each under [pageScreenshotFileName]. A
/// name already taken gets " (2)", " (3)"…, so nothing there is replaced:
/// each name is claimed by creating the file exclusively, which fails if
/// anything else got there first. Returns the paths written.
Future<List<String>> writeScreenshotsToFolder(
  String folder,
  String strategyName,
  List<PageScreenshot> shots,
) async {
  final written = <String>[];
  for (final shot in shots) {
    final name = pageScreenshotFileName(strategyName, shot);
    final stem = p.basenameWithoutExtension(name);
    var file = File(p.join(folder, name));
    for (var copy = 2; !await _claim(file); copy++) {
      file = File(p.join(folder, '$stem ($copy).png'));
    }
    await file.writeAsBytes(shot.png, flush: true);
    written.add(file.path);
  }
  return written;
}

/// Creates [file] if no file is there yet; false when one already is.
Future<bool> _claim(File file) async {
  try {
    await file.create(exclusive: true);
    return true;
  } on PathExistsException {
    return false;
  }
}

/// [shots] as one .zip, for a browser to download in one go.
Uint8List zipScreenshots(String strategyName, List<PageScreenshot> shots) {
  final archive = Archive();
  for (final shot in shots) {
    archive.addFile(
      ArchiveFile.bytes(pageScreenshotFileName(strategyName, shot), shot.png),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}
