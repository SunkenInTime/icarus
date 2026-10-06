import 'dart:typed_data';

import 'vision_world_gzip.dart';

/// Desktop's zlib is native and fast; it runs in a background isolate.
Future<Uint8List> inflateWorldGzip(Uint8List compressed) async =>
    decodeWorldGzip(compressed);
