import 'dart:typed_data';

/// What the browser pasted: the first picture on the clipboard, if any.
typedef BrowserPaste = ({Uint8List? picture});

/// Only a browser sends paste events.
Future<BrowserPaste?> nextBrowserPaste() async => null;
