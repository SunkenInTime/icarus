import '../wire.dart';

final class HiveRecordDigest {
  const HiveRecordDigest({
    required this.strategyPublicId,
    required this.digest,
  });

  final String strategyPublicId;
  final String digest;

  Map<String, Object?> toJson() => {
    'strategyPublicId': strategyPublicId,
    'digest': digest,
  };

  static Decoded<HiveRecordDigest> decode(Object? json) => JsonFields.read(
    json,
    'Hive record digest',
    (fields) {
      final strategyPublicId = fields.string('strategyPublicId');
      final digest = fields.string('digest');
      return () =>
          HiveRecordDigest(strategyPublicId: strategyPublicId, digest: digest);
    },
  );

  @override
  bool operator ==(Object other) =>
      other is HiveRecordDigest &&
      other.strategyPublicId == strategyPublicId &&
      other.digest == digest;

  @override
  int get hashCode => Object.hash(strategyPublicId, digest);

  @override
  String toString() => 'HiveRecordDigest($strategyPublicId, $digest)';
}
