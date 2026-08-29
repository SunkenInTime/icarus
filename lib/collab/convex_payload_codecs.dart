import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

export 'package:icarus/collab/collab_models.dart' show CloudPayload;

final class ConvexPayload {
  const ConvexPayload(this.tag);

  final String tag;
}

abstract interface class ConvexPayloadCodec<T> {
  const ConvexPayloadCodec();

  ConvexValue encode(T value);

  T decode(ConvexValue value);
}

CloudPayload _decodePayload(ConvexValue value, String expectedTag) {
  if (value is! ConvexObject) {
    throw FormatException('Expected $expectedTag payload object');
  }
  final decoded = value.toDart();
  if (decoded['kind'] != expectedTag) {
    throw FormatException(
      'Expected payload kind $expectedTag, received ${decoded['kind']}',
    );
  }
  if (decoded['payloadVersion'] is! num || decoded['data'] is! Map) {
    throw FormatException('Invalid $expectedTag payload envelope');
  }
  return Map<String, dynamic>.from(
    canonicalCloudJsonValue(decoded) as Map,
  );
}

ConvexValue _encodePayload(CloudPayload value, String expectedTag) {
  if (value['kind'] != expectedTag) {
    throw FormatException(
      'Expected payload kind $expectedTag, received ${value['kind']}',
    );
  }
  return ConvexValue.fromDart(canonicalCloudJsonValue(value));
}

@ConvexPayload('agent')
final class AgentConvexCodec implements ConvexPayloadCodec<CloudPayload> {
  const AgentConvexCodec();

  @override
  CloudPayload decode(ConvexValue value) => _decodePayload(value, 'agent');

  @override
  ConvexValue encode(CloudPayload value) => _encodePayload(value, 'agent');
}

@ConvexPayload('ability')
final class AbilityConvexCodec implements ConvexPayloadCodec<CloudPayload> {
  const AbilityConvexCodec();

  @override
  CloudPayload decode(ConvexValue value) => _decodePayload(value, 'ability');

  @override
  ConvexValue encode(CloudPayload value) => _encodePayload(value, 'ability');
}

@ConvexPayload('drawing')
final class DrawingConvexCodec implements ConvexPayloadCodec<CloudPayload> {
  const DrawingConvexCodec();

  @override
  CloudPayload decode(ConvexValue value) => _decodePayload(value, 'drawing');

  @override
  ConvexValue encode(CloudPayload value) => _encodePayload(value, 'drawing');
}

@ConvexPayload('text')
final class TextConvexCodec implements ConvexPayloadCodec<CloudPayload> {
  const TextConvexCodec();

  @override
  CloudPayload decode(ConvexValue value) => _decodePayload(value, 'text');

  @override
  ConvexValue encode(CloudPayload value) => _encodePayload(value, 'text');
}

@ConvexPayload('image')
final class ImageConvexCodec implements ConvexPayloadCodec<CloudPayload> {
  const ImageConvexCodec();

  @override
  CloudPayload decode(ConvexValue value) => _decodePayload(value, 'image');

  @override
  ConvexValue encode(CloudPayload value) => _encodePayload(value, 'image');
}

@ConvexPayload('utility')
final class UtilityConvexCodec implements ConvexPayloadCodec<CloudPayload> {
  const UtilityConvexCodec();

  @override
  CloudPayload decode(ConvexValue value) => _decodePayload(value, 'utility');

  @override
  ConvexValue encode(CloudPayload value) => _encodePayload(value, 'utility');
}

@ConvexPayload('lineupGroup')
final class LineupGroupConvexCodec implements ConvexPayloadCodec<CloudPayload> {
  const LineupGroupConvexCodec();

  @override
  CloudPayload decode(ConvexValue value) =>
      _decodePayload(value, 'lineupGroup');

  @override
  ConvexValue encode(CloudPayload value) =>
      _encodePayload(value, 'lineupGroup');
}
