/// The app keeps a strategy's images on disk as
/// `<strategy id>/images/<image id><extension>`. Those ids and extensions
/// also arrive from outside: in imported .ica files and from the cloud. One
/// that could name a path somewhere else (a separator, a drive, "..") or a
/// file that isn't an image would let whoever made it write files anywhere
/// on this computer, so it is never used as a name.
library;

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

/// `<id><extension>` when that is a safe image file name, else null.
String? imageFileName(String id, String? extension) {
  if (!isSafeFileNameId(id)) return null;
  if (extension == null ||
      !imageFileExtensions.contains(extension.toLowerCase())) {
    return null;
  }
  return '$id$extension';
}

/// Thrown instead of building a path from an id or extension that
/// [imageFileName] or [isSafeFileNameId] refuses.
class UnsafeImageFileNameException implements Exception {
  const UnsafeImageFileNameException(this.name);

  final String name;

  @override
  String toString() => "Can't save an image as $name";
}
