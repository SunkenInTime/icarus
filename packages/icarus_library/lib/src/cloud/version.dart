import '../json.dart';
import '../rows.dart';

const unknownLife = 0;

final class Version {
  const Version(this.life, this.revision);

  final int life;
  final int revision;

  bool sameLife(Version other) =>
      life == unknownLife || other.life == unknownLife || life == other.life;

  int _against(Version other) => sameLife(other)
      ? revision.compareTo(other.revision)
      : life.compareTo(other.life);

  bool operator >(Version other) => _against(other) > 0;

  bool operator >=(Version other) => _against(other) >= 0;

  bool operator <(Version other) => _against(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is Version && other.life == life && other.revision == revision;

  @override
  int get hashCode => Object.hash(life, revision);

  @override
  String toString() => '$revision of life $life';
}

int? createdAtOf(Row row) => switch (row) {
  ReadableStrategy(:final createdAt) => createdAt.millisecondsSinceEpoch,
  ReadablePageRow(:final unknownFields) ||
  ReadablePageSettings(:final unknownFields) ||
  ReadableElementRow(:final unknownFields) ||
  ReadableLineupGroupRow(:final unknownFields) => _life(unknownFields),
  _ => null,
};

int? _life(JsonObject fields) => switch (fields['createdAt']) {
  final int life => life,
  final num life when life == life.roundToDouble() => life.toInt(),
  _ => null,
};
