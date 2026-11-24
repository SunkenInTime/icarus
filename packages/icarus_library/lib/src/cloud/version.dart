import '../json.dart';
import '../rows.dart';

final class Version {
  const Version(this.life, this.revision);

  final int life;
  final int revision;

  bool sameLife(Version other) => life == other.life;

  int _against(Version other) => life == other.life
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

Row bornIn(Row row, int life) {
  if (createdAtOf(row) != null) return row;
  JsonObject lived(JsonObject fields) =>
      jsonObject({...viewsOf(fields), 'createdAt': life});
  return switch (row) {
    LiveElement() => LiveElement(
      publicId: row.publicId,
      pagePublicId: row.pagePublicId,
      payload: row.payload,
      sortIndex: row.sortIndex,
      revision: row.revision,
      unknownFields: lived(row.unknownFields),
    ),
    DeletedElement() => DeletedElement(
      publicId: row.publicId,
      pagePublicId: row.pagePublicId,
      payload: row.payload,
      sortIndex: row.sortIndex,
      revision: row.revision,
      unknownFields: lived(row.unknownFields),
    ),
    LiveLineupGroup() => LiveLineupGroup(
      publicId: row.publicId,
      strategyPublicId: row.strategyPublicId,
      pagePublicId: row.pagePublicId,
      payload: row.payload,
      sortIndex: row.sortIndex,
      revision: row.revision,
      unknownFields: lived(row.unknownFields),
    ),
    DeletedLineupGroup() => DeletedLineupGroup(
      publicId: row.publicId,
      strategyPublicId: row.strategyPublicId,
      pagePublicId: row.pagePublicId,
      payload: row.payload,
      sortIndex: row.sortIndex,
      revision: row.revision,
      unknownFields: lived(row.unknownFields),
    ),
    LivePage() => LivePage(
      publicId: row.publicId,
      strategyPublicId: row.strategyPublicId,
      name: row.name,
      isAutoNamed: row.isAutoNamed,
      sortIndex: row.sortIndex,
      isAttack: row.isAttack,
      revision: row.revision,
      unknownFields: lived(row.unknownFields),
    ),
    ReadablePageSettings() => ReadablePageSettings(
      pagePublicId: row.pagePublicId,
      settings: row.settings,
      revision: row.revision,
      unknownFields: lived(row.unknownFields),
    ),
    _ => row,
  };
}

int? _life(JsonObject fields) => switch (fields['createdAt']) {
  final int life => life,
  final num life when life == life.roundToDouble() => life.toInt(),
  _ => null,
};
