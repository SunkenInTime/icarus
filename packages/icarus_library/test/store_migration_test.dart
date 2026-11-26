import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';

void main() {
  final startedAt = DateTime.utc(2026, 11, 26, 9, 30, 0, 0, 123);
  final finishedAt = DateTime.utc(2026, 11, 26, 9, 31, 0, 0, 456);

  Future<Migration> afterReopen(MemoryStorage storage) async {
    final store = await openStore(MemoryEngine(storage));
    final migration = store.migration;
    await store.close();
    return migration;
  }

  test('a store with no migration record has not started one', () async {
    final storage = MemoryStorage();

    expect(await afterReopen(storage), isA<MigrationNotStarted>());
  });

  test('a copying record is read back as copying, with its start', () async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));

    savedValue(await store.recordMigration(MigrationCopying(startedAt)));
    expect(store.migration, isA<MigrationCopying>());
    await store.close();

    expect(
      await afterReopen(storage),
      isA<MigrationCopying>().having(
        (copying) => copying.startedAt,
        'startedAt',
        startedAt,
      ),
    );
  });

  test('a finished record is read back with what it left behind, and replaces '
      'the copying record', () async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    savedValue(await store.recordMigration(MigrationCopying(startedAt)));

    savedValue(
      await store.recordMigration(
        MigrationFinished(
          startedAt: startedAt,
          finishedAt: finishedAt,
          strategies: const [LeftBehind('s-1', 'Split "B"', 'an unknown map')],
          folders: const [LeftBehind('f-1', 'Retakes', 'its parent is gone')],
        ),
      ),
    );
    await store.close();

    final read = await afterReopen(storage) as MigrationFinished;
    expect(read.startedAt, startedAt);
    expect(read.finishedAt, finishedAt);
    expect(
      [
        for (final left in read.strategies)
          [left.publicId, left.name, left.reason],
      ],
      [
        ['s-1', 'Split "B"', 'an unknown map'],
      ],
    );
    expect(
      [
        for (final left in read.folders)
          [left.publicId, left.name, left.reason],
      ],
      [
        ['f-1', 'Retakes', 'its parent is gone'],
      ],
    );
    expect(
      storage.contents['library']!.keys.where((key) => key == 'migration'),
      hasLength(1),
    );
  });

  test('a record this build cannot read is unreadable, not missing', () async {
    final storage = MemoryStorage({
      'library': {'migration': '{"state": "half done"}'},
    });

    expect(await afterReopen(storage), isA<MigrationUnreadable>());
  });

  test(
    'a store holding the migration record opens with no foreign names',
    () async {
      final storage = MemoryStorage();
      final store = await openStore(MemoryEngine(storage));
      savedValue(await store.recordMigration(MigrationCopying(startedAt)));
      await store.close();

      final opened = await LibraryStore.open(
        MemoryEngine(storage),
        canRead: readsKnownKinds,
        clock: fixedClock,
      );

      expect(opened, isA<StoreOpened>());
      expect((opened as StoreOpened).foreignNames, isEmpty);
      await opened.store.close();
    },
  );
}
