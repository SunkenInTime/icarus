import 'dart:io';

import 'package:path/path.dart' as path;

Future<String?> writeVisionBoundaryEditsAsset(String contents) async {
  var directory = Directory.current.absolute;
  for (var depth = 0; depth < 7; depth += 1) {
    final pubspec = File(path.join(directory.path, 'pubspec.yaml'));
    final mapsDirectory = Directory(
      path.join(directory.path, 'assets', 'maps'),
    );
    if (await pubspec.exists() && await mapsDirectory.exists()) {
      final target = File(
        path.join(mapsDirectory.path, 'vision_boundary_edits.json'),
      );
      await target.writeAsString(contents, flush: true);
      return target.absolute.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}
