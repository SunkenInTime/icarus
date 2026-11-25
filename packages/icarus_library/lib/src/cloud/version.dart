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
  _ => null,
};

Version? versionOfRow(Row row) => switch (revisionOfRow(row)) {
  final revision? => Version(revision, life: createdAtOf(row)),
  null => null,
};
