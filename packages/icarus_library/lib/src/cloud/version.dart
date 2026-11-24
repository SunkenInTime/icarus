import '../json.dart';
import '../rows.dart';
import 'pending.dart';

final class Version {
  const Version(this._life, this._revision);

  final int _life;
  final int _revision;

  int get lifeOnTheWire => _life;

  int get revisionOnTheWire => _revision;

  bool sameLife(Version other) => _life == other._life;

  bool bornBefore(Version other) => _life < other._life;

  bool bornAfter(int life) => _life > life;

  bool isAt(RowLife life, int revision) =>
      revision == _revision && life.matches(_life);

  int _against(Version other) => _life == other._life
      ? _revision.compareTo(other._revision)
      : _life.compareTo(other._life);

  bool operator >(Version other) => _against(other) > 0;

  bool operator >=(Version other) => _against(other) >= 0;

  bool operator <(Version other) => _against(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is Version && other._life == _life && other._revision == _revision;

  @override
  int get hashCode => Object.hash(_life, _revision);

  @override
  String toString() => '$_revision of life $_life';
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
