import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

/// What the browser pasted: the first picture on the clipboard, if any.
typedef BrowserPaste = ({Uint8List? picture});

@JS('window')
external _Window get _window;

extension type _Window._(JSObject _) implements JSObject {
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type _ClipboardEvent._(JSObject _) implements JSObject {
  external _DataTransfer? get clipboardData;
}

extension type _DataTransfer._(JSObject _) implements JSObject {
  external _FileList get files;
}

extension type _FileList._(JSObject _) implements JSObject {
  external int get length;
  external _File? item(int index);
}

extension type _File._(JSObject _) implements JSObject {
  external String get type;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

/// How long after a key press a browser's paste event can take to come: it
/// waits for the browser to prepare the picture, about 100 ms for a 1080p one.
const _eventWait = Duration(seconds: 1);

/// The paste event of the key press being handled, or null when none comes:
/// the key was rebound to something the browser doesn't take for a paste.
///
/// The event needs no clipboard permission, where reading the clipboard
/// prompts, and on some browsers prompts every time. It only comes while the
/// key press is left unhandled.
Future<BrowserPaste?> nextBrowserPaste() {
  final result = Completer<BrowserPaste?>();
  late final JSFunction listener;
  late final Timer timeout;
  void stopWaiting() {
    timeout.cancel();
    _window.removeEventListener('paste', listener);
  }

  void onPaste(_ClipboardEvent event) {
    stopWaiting();
    // The event's clipboard empties when the event ends, so the file is
    // taken now. Its bytes can follow.
    final file = _firstPicture(event.clipboardData);
    if (file == null) {
      result.complete((picture: null));
      return;
    }
    file.arrayBuffer().toDart.then(
          (bytes) => result.complete((picture: bytes.toDart.asUint8List())),
          onError: result.completeError,
        );
  }

  listener = onPaste.toJS;
  timeout = Timer(_eventWait, () {
    stopWaiting();
    result.complete(null);
  });
  _window.addEventListener('paste', listener);
  return result.future;
}

_File? _firstPicture(_DataTransfer? clipboard) {
  if (clipboard == null) return null;
  final files = clipboard.files;
  for (var i = 0; i < files.length; i++) {
    final file = files.item(i);
    if (file != null && file.type.startsWith('image/')) return file;
  }
  return null;
}
