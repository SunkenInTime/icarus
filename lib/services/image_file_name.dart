/// The app keeps a strategy's files on disk under
/// `<app support>/<strategy id>/`, its images as `images/<id><extension>`.
/// Those ids and extensions also arrive from outside: in imported .ica files
/// and from the cloud. One that could name a path somewhere else (a
/// separator, a drive, "..") or a file that isn't an image would let whoever
/// made it write or delete files elsewhere on this computer, so it is never
/// used as a name.
library;

import 'package:path/path.dart' as path;

/// The extensions the app saves images under. Compared without case: the
/// lineup picker keeps the extension as the file was named.
const imageFileExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

/// Whether [id] can name a file or folder of its own: the same rule the
/// server keeps (convex/lib/fileNameIds.ts). Characters Windows refuses in a
/// name are refused, and so is a trailing dot or space, which Windows drops.
/// Every id the app makes is a UUID or a copy id built from one, and passes.
bool isSafeFileNameId(String id) =>
    id.isNotEmpty &&
    id.length <= 200 &&
    id != '.' &&
    id != '..' &&
    !id.endsWith('.') &&
    !id.endsWith(' ') &&
    !RegExp(r'[\\/:<>"|?*\x00-\x1f\x7f]').hasMatch(id);

/// `<id><extension>` when that is a safe image file name, else null. Cloud
/// images from before extensions were recorded have none; their file is the
/// bare id, which then must not carry an extension of its own.
String? imageFileName(String id, String? extension) {
  if (!isSafeFileNameId(id) || extension == null) return null;
  if (extension.isEmpty) return id.contains('.') ? null : id;
  if (!imageFileExtensions.contains(extension.toLowerCase())) return null;
  return '$id$extension';
}

/// `<root>/<strategyId>`, the folder a strategy keeps its files in.
/// Throws [UnsafeFileNameException] when [strategyId] can't name a folder
/// of its own.
String strategyFolderPath(String root, String strategyId) {
  if (!isSafeFileNameId(strategyId)) {
    throw UnsafeFileNameException(strategyId);
  }
  return path.join(root, strategyId);
}

/// Thrown instead of building a path from an id or extension the rules
/// above refuse.
class UnsafeFileNameException implements Exception {
  const UnsafeFileNameException(this.name);

  final String name;

  @override
  String toString() => "Can't use $name as a file name";
}
