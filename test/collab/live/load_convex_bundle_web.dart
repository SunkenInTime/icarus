import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

Future<void> loadConvexBundle(String url) {
  final loaded = Completer<void>();
  final document = globalContext['document']! as JSObject;
  final script =
      document.callMethod<JSObject>('createElement'.toJS, 'script'.toJS);
  script['src'] = url.toJS;
  script['onload'] = ((JSAny? _) => loaded.complete()).toJS;
  script['onerror'] = ((JSAny? _) =>
      loaded.completeError(StateError('$url did not load'))).toJS;
  (document['head']! as JSObject)
      .callMethod<JSAny?>('appendChild'.toJS, script);
  return loaded.future;
}
