import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'vision_world_gzip.dart';

@JS('DecompressionStream')
extension type _DecompressionStream._(JSObject _) implements JSObject {
  external factory _DecompressionStream(String format);
}

extension type _ReadableStream._(JSObject _) implements JSObject {
  external _ReadableStream pipeThrough(JSObject transform);
}

@JS('Response')
extension type _Response._(JSObject _) implements JSObject {
  external factory _Response(JSAny body);
  external _ReadableStream get body;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

/// The browser's gzip checks what [decodeWorldGzip] checks: it rejects a
/// wrong CRC-32 or length, a stream that ends before its footer, and bytes
/// after it. The length is compared again here so a short read cannot pass.
Future<Uint8List> inflateWorldGzip(Uint8List compressed) async {
  // Firefox before 113 and Safari before 16.4 lack it; they keep the slow path.
  if (!globalContext.has('DecompressionStream')) {
    return decodeWorldGzip(compressed);
  }
  checkWorldGzipHeader(compressed);
  final Uint8List decoded;
  try {
    final inflated = _Response(compressed.toJS)
        .body
        .pipeThrough(_DecompressionStream('gzip'));
    decoded =
        (await _Response(inflated).arrayBuffer().toDart).toDart.asUint8List();
  } on Object {
    throw const FormatException('Invalid world gzip checksum or length.');
  }
  final footer = ByteData.sublistView(compressed, compressed.length - 8);
  if (footer.getUint32(4, Endian.little) != decoded.length) {
    throw const FormatException('Invalid world gzip checksum or length.');
  }
  return decoded;
}
