/// Thrown when the user cancels a video export.
class VideoExportCancelled implements Exception {}

/// Thrown when a capture was asked to print a page's captions and they can't
/// all be placed; nothing is cut, so the page isn't saved. [page] is its
/// 1-based number, when the capture knows it.
class CaptionsDontFit implements Exception {
  const CaptionsDontFit([this.page]);

  final int? page;

  String get userMessage => captionsDontFitMessage(page);
}

String captionsDontFitMessage(int? page) =>
    "Captions on ${page == null ? 'this page' : 'page $page'} don't fit. "
    'Shorten them, or turn off Include captions.';

/// A video export failure whose [message] can be shown to the user.
class VideoExportException implements Exception {
  VideoExportException(this.message);
  final String message;

  @override
  String toString() => 'VideoExportException: $message';
}
