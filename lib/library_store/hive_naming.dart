sealed class KeptOnHive {
  const KeptOnHive();
}

final class KeyIsNotText extends KeptOnHive {
  const KeyIsNotText(this.key);

  final Object key;

  @override
  String toString() => 'its key $key is not text';
}

final class KeyIsNotItsId extends KeptOnHive {
  const KeyIsNotItsId(this.key);

  final String key;

  @override
  String toString() => 'its key $key is not its id';
}

final class IdSharedWithAnotherRecord extends KeptOnHive {
  const IdSharedWithAnotherRecord(this.records);

  final int records;

  @override
  String toString() => '$records records carry its id';
}

typedef HiveRecordName = ({Object key, String id});

typedef KeptRecord = ({Object key, String id, KeptOnHive reason});

final class BoxNames {
  BoxNames._(this.kept) : keptIds = {for (final record in kept) record.id};

  factory BoxNames.of(Iterable<HiveRecordName> records) {
    final all = records.toList();
    final carrying = <String, int>{};
    for (final record in all) {
      carrying[record.id] = (carrying[record.id] ?? 0) + 1;
    }
    return BoxNames._(List.unmodifiable([
      for (final (:key, :id) in all)
        if (_keptBecause(key, id, carrying[id]!) case final reason?)
          (key: key, id: id, reason: reason),
    ]));
  }

  static final none = BoxNames._(const []);

  static KeptOnHive? _keptBecause(Object key, String id, int carrying) =>
      switch (key) {
        String() when key != id => KeyIsNotItsId(key),
        String() when carrying > 1 => IdSharedWithAnotherRecord(carrying),
        String() => null,
        _ => KeyIsNotText(key),
      };

  final List<KeptRecord> kept;

  final Set<String> keptIds;

  bool namesById(String id) => !keptIds.contains(id);
}

final class HiveNames {
  HiveNames({required this.strategies, required this.folders});

  HiveNames.of({
    required Iterable<HiveRecordName> strategies,
    required Iterable<HiveRecordName> folders,
  })  : strategies = BoxNames.of(strategies),
        folders = BoxNames.of(folders);

  static final none =
      HiveNames(strategies: BoxNames.none, folders: BoxNames.none);

  final BoxNames strategies;
  final BoxNames folders;
}

int compareHiveKeys(Object a, Object b) => switch ((a, b)) {
      (final int a, final int b) => a.compareTo(b),
      (int(), _) => -1,
      (_, int()) => 1,
      (final String a, final String b) => a.compareTo(b),
      _ => '$a'.compareTo('$b'),
    };
