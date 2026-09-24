import 'dart:js_interop';

@JS('history')
external _History get _history;

extension type _History._(JSObject _) implements JSObject {
  external JSAny? get state;
  external void replaceState(JSAny? data, String unused, String url);
}

/// Replaces the address bar URL without navigating or adding a history entry.
/// Keeps the current history state, which Flutter's router owns.
void replaceBrowserUrl(Uri url) {
  _history.replaceState(_history.state, '', url.toString());
}
