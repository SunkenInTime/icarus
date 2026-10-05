/// Thrown when the user cancels a video export.
class VideoExportCancelled implements Exception {}

/// A video export failure whose [message] can be shown to the user.
class VideoExportException implements Exception {
  VideoExportException(this.message);
  final String message;

  @override
  String toString() => 'VideoExportException: $message';
}
