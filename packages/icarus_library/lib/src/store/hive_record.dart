import '../json.dart';
import '../wire.dart';

final class HiveRecordDigest {
  HiveRecordDigest({
    required this.strategyPublicId,
    required this.digest,
    this.unknownFields = JsonObject.empty,
  });

  static const _known = {'strategyPublicId', 'digest'};

  final String strategyPublicId;
  final String digest;
  final JsonObject unknownFields;

  HiveRecordDigest withDigest(String digest) => HiveRecordDigest(
    strategyPublicId: strategyPublicId,
    digest: digest,
    unknownFields: unknownFields,
  );

  Map<String, Object?> toJsonView() => {
    ...viewsOf(unknownFields),
    'strategyPublicId': strategyPublicId,
    'digest': digest,
  };

  static Decoded<HiveRecordDigest> decode(Object? json) =>
      JsonFields.read(json, 'Hive record digest', (fields) {
        final strategyPublicId = fields.string('strategyPublicId');
        final digest = fields.string('digest');
        final unknown = fields.rest(_known);
        return () => HiveRecordDigest(
          strategyPublicId: strategyPublicId,
          digest: digest,
          unknownFields: unknown,
        );
      });

  @override
  bool operator ==(Object other) =>
      other is HiveRecordDigest && sameJson(other.toJsonView(), toJsonView());

  @override
  int get hashCode => canonicalJson(toJsonView()).hashCode;

  @override
  String toString() => 'HiveRecordDigest($strategyPublicId, $digest)';
}
