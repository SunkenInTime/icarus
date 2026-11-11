import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:icarus/l10n/l10n.dart';
import 'package:path/path.dart' as p;

/// [path], ending in [extension] (with its dot) however the user cased it.
String withFileExtension(String path, String extension) =>
    path.toLowerCase().endsWith(extension) ? path : '$path$extension';

/// Asks where to save an export named [fileName], and returns a path that
/// ends in [fileName]'s extension, or null when the user cancels.
///
/// Windows' save dialog returns exactly what was typed: rename the file and
/// the extension goes with it, and a file without one neither imports nor
/// opens. The dialog only asked about replacing the name it returned, so a
/// corrected name that is already taken goes back to it to ask.
Future<String?> chooseExportPath(
  AppLocalizations l10n,
  String fileName,
) async {
  final extension = p.extension(fileName);
  var suggestedName = fileName;
  String? directory;
  while (true) {
    final chosen = await FilePicker.platform.saveFile(
      type: FileType.custom,
      dialogTitle: l10n.importExportSaveDialogTitle,
      fileName: suggestedName,
      initialDirectory: directory,
      allowedExtensions: [extension.substring(1)],
    );
    if (chosen == null) return null;
    final path = withFileExtension(chosen, extension);
    if (path == chosen || !File(path).existsSync()) return path;
    suggestedName = p.basename(path);
    directory = p.dirname(path);
  }
}

/// Saves [bytes] as an export named [fileName]: desktop asks where (see
/// [chooseExportPath]), the browser downloads them.
Future<void> saveExportBytes(
  AppLocalizations l10n,
  String fileName,
  Uint8List bytes,
) async {
  if (kIsWeb) {
    await FilePicker.platform.saveFile(
      type: FileType.custom,
      fileName: fileName,
      allowedExtensions: [p.extension(fileName).substring(1)],
      bytes: bytes,
    );
    return;
  }
  final path = await chooseExportPath(l10n, fileName);
  if (path != null) await File(path).writeAsBytes(bytes);
}
