import 'dart:convert';
import 'dart:typed_data';

/// Decode the offline ICVW v1 container into shared typed-array views.
/// Large coordinate/index arrays never pass through JSON or boxed Dart lists.
/// Delta values are restored in place, so the caller must not reuse the input.
Map<String, dynamic> decodeVisionWorldBinary(Uint8List input) {
  final bytes =
      input.offsetInBytes % 4 == 0 ? input : Uint8List.fromList(input);
  const magic = [73, 67, 86, 87, 1, 0, 0, 0];
  if (bytes.length < 12) {
    throw const FormatException('Invalid world binary magic or version.');
  }
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) {
      throw const FormatException('Invalid world binary magic or version.');
    }
  }
  final view = ByteData.sublistView(bytes);
  final headerSize = view.getUint32(8, Endian.little);
  final dataStart = (12 + headerSize + 3) & ~3;
  if (headerSize == 0 || dataStart > bytes.length) {
    throw const FormatException('Truncated world binary header.');
  }
  final decoded = jsonDecode(
      utf8.decode(Uint8List.sublistView(bytes, 12, 12 + headerSize)));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Invalid world binary header object.');
  }
  final descriptors = decoded.remove('binaryArrays');
  if (descriptors is! Map<String, dynamic> || descriptors.length != 3) {
    throw const FormatException('Invalid world binary array directory.');
  }
  var expectedOffset = 0;
  Int32List array(String name) {
    final entry = descriptors[name];
    if (entry is! Map<String, dynamic>) {
      throw FormatException('Missing world binary $name array.');
    }
    final offset = entry['byteOffset'], count = entry['elementCount'];
    if (offset is! int ||
        count is! int ||
        count < 0 ||
        offset != expectedOffset ||
        dataStart + offset + count * 4 > bytes.length) {
      throw FormatException('Invalid world binary $name array bounds.');
    }
    expectedOffset += count * 4;
    if (Endian.host == Endian.little) {
      return Int32List.view(
          bytes.buffer, bytes.offsetInBytes + dataStart + offset, count);
    }
    return Int32List.fromList([
      for (var i = 0; i < count; i++)
        view.getInt32(dataStart + offset + i * 4, Endian.little)
    ]);
  }

  final vertices = array('vertices');
  final edges = array('edges');
  decoded['vertices'] = vertices;
  decoded['edges'] = edges;
  final edgeIds = array('layerEdges');
  if (dataStart + expectedOffset != bytes.length) {
    throw const FormatException('Unexpected trailing world binary data.');
  }
  final layers = decoded['layers'];
  if (layers is! List)
    throw const FormatException('Missing world binary layers.');
  var expectedEdgeOffset = 0;
  for (final layer in layers) {
    if (layer is! Map<String, dynamic> || layer.containsKey('edges')) {
      throw const FormatException('Invalid world binary layer descriptor.');
    }
    final offset = layer.remove('edgeOffset'),
        count = layer.remove('edgeCount');
    if (offset is! int ||
        count is! int ||
        count < 0 ||
        offset != expectedEdgeOffset ||
        offset + count > edgeIds.length) {
      throw const FormatException('Invalid world binary layer edge bounds.');
    }
    expectedEdgeOffset += count;
    layer['edges'] = Int32List.sublistView(edgeIds, offset, offset + count);
  }
  if (expectedEdgeOffset != edgeIds.length) {
    throw const FormatException('Unclaimed world binary layer edges.');
  }
  final encoding = decoded.remove('encoding');
  if (encoding != null && encoding != 'delta-int32-v1') {
    throw const FormatException('Unsupported world binary encoding.');
  }
  if (encoding == 'delta-int32-v1') {
    void restore(Int32List values, {int stride = 1}) {
      for (var channel = 0; channel < stride; channel++) {
        var previous = 0;
        for (var i = channel; i < values.length; i += stride) {
          final next = previous + values[i];
          if (next < -2147483648 || next > 2147483647) {
            throw const FormatException('World binary delta overflow.');
          }
          values[i] = next;
          previous = next;
        }
      }
    }

    restore(vertices, stride: 2);
    restore(edges);
    for (final layer in layers) {
      restore(layer['edges'] as Int32List);
    }
  }
  return decoded;
}
