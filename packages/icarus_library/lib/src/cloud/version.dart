import '../json.dart';
import '../rows.dart';
import '../wire.dart' show isSafeWhole;
import 'op_facts.dart';

final class Version {
  const Version(this._revision, {int? life}) : _life = life;

  final int _revision;
  final int? _life;

  int get revisionOnTheWire => _revision;

  int? get lifeOnTheWire => _life;

  bool _livesDiffer(Version other) =>
      _life != null && other._life != null && _life != other._life;

  int _against(Version other) => _livesDiffer(other)
      ? _life!.compareTo(other._life!)
      : _revision.compareTo(other._revision);

  bool operator >(Version other) => _against(other) > 0;

  bool operator >=(Version other) => _against(other) >= 0;

  bool operator <(Version other) => _against(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is Version && other._revision == _revision && other._life == _life;

  @override
  int get hashCode => Object.hash(_revision, _life);

  @override
  String toString() =>
      _life == null ? '$_revision' : '$_revision of life $_life';
}

int? createdAtOf(Row row) => switch (row) {
  ReadableStrategy(:final createdAt) => createdAt.millisecondsSinceEpoch,
  ReadablePageRow(:final unknownFields) ||
  ReadablePageSettings(:final unknownFields) ||
  ReadableElementRow(:final unknownFields) ||
  ReadableLineupGroupRow(:final unknownFields) => switch (viewsOf(
    unknownFields,
  )['createdAt']) {
    final num life when isSafeWhole(life) => life.toInt(),
    _ => null,
  },
  _ => switch (row.toJsonView()) {
    final JsonObject stored => _lifeIn(viewsOf(stored)),
    final Map<String, Object?> stored => _lifeIn(stored),
    _ => null,
  },
};

int? _lifeIn(Map<String, Object?> fields) => switch (fields['createdAt']) {
  final num life when isSafeWhole(life) => life.toInt(),
  _ => null,
};

Version? versionOfRow(Row row) => switch (revisionOfRow(row)) {
  final revision? => Version(revision, life: createdAtOf(row)),
  null => null,
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
