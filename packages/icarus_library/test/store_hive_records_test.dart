import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

final record = HiveRecordDigest(strategyPublicId: strategyId, digest: 'd1');

String hiveName(String strategy) => 'hive/${digestOf(strategy)}';

Future<(MemoryStorage, LibraryStore)> withStrategy({
  bool remembered = true,
}) async {
  final storage = MemoryStorage();
  final store = await openStore(MemoryEngine(storage));
  savedValue(
    await store.editLibrary([
      AddStrategy(strategyRows()),
      if (remembered) RememberHiveRecord(record),
    ]),
  );
  return (storage, store);
}

void main() {
  test(
    'a strategy and its Hive record are saved in one commit and read back at open',
    () async {
      final storage = MemoryStorage();
      final engine = MemoryEngine(storage);
      final store = await openStore(engine);
      var commits = 0;
      final counted = WrappingEngine(
        engine,
        (lease) => _CommitCounter(lease, () => commits++),
      );
      await store.close();
      final again = await openStore(counted);
      savedValue(
        await again.editLibrary([
          AddStrategy(strategyRows()),
          RememberHiveRecord(record),
        ]),
      );
      expect(commits, 1);
      expect(listOf(again).hiveRecords, {strategyId: record});
      await again.close();

      final reopened = await openStore(MemoryEngine(storage));
      expect(listOf(reopened).hiveRecords, {strategyId: record});
      expect(
        storage.contents['library']![hiveName(strategyId)],
        '{"digest":"d1","strategyPublicId":"strategy-1"}',
      );
    },
  );

  test(
    'a Hive record for a strategy the store does not hold is refused, and nothing is written',
    () async {
      final storage = MemoryStorage();
      final store = await openStore(MemoryEngine(storage));
      final result = await store.editLibrary([RememberHiveRecord(record)]);
      expect(
        result,
        isA<Refused<LibraryEdited, LibraryRefusal>>().having(
          (r) => r.reason,
          'reason',
          isA<NoSuchStrategy>(),
        ),
      );
      expect(storage.contents, isEmpty);
    },
  );

  test(
    'remembering the same digest again is nothing to save, and a new digest replaces it',
    () async {
      final (storage, store) = await withStrategy();
      expect(
        await store.editLibrary([RememberHiveRecord(record)]),
        isA<NothingToSave<LibraryEdited, LibraryRefusal>>(),
      );
      final next = HiveRecordDigest(strategyPublicId: strategyId, digest: 'd2');
      savedValue(await store.editLibrary([RememberHiveRecord(next)]));
      await store.close();
      expect(listOf(await openStore(MemoryEngine(storage))).hiveRecords, {
        strategyId: next,
      });
    },
  );

  test(
    'removing a strategy removes its Hive record in the same commit',
    () async {
      final (storage, store) = await withStrategy();
      savedValue(await store.editLibrary([const RemoveStrategy(strategyId)]));
      expect(listOf(store).hiveRecords, isEmpty);
      await store.close();
      expect(
        storage.contents['library']?.containsKey(hiveName(strategyId)) ?? false,
        isFalse,
      );
      expect(
        listOf(await openStore(MemoryEngine(storage))).hiveRecords,
        isEmpty,
      );
    },
  );

  test(
    'a removed strategy added again in a later edit can be remembered again',
    () async {
      final (storage, store) = await withStrategy();
      savedValue(await store.editLibrary([const RemoveStrategy(strategyId)]));
      savedValue(
        await store.editLibrary([
          AddStrategy(strategyRows()),
          RememberHiveRecord(record),
        ]),
      );
      await store.close();
      expect(listOf(await openStore(MemoryEngine(storage))).hiveRecords, {
        strategyId: record,
      });
    },
  );

  for (final (what, stored) in [
    ('text that is not JSON', '{'),
    ('JSON without a digest', jsonEncode({'strategyPublicId': strategyId})),
    (
      'the record of another strategy',
      jsonEncode(
        HiveRecordDigest(strategyPublicId: 'other', digest: 'd1').toJsonView(),
      ),
    ),
  ]) {
    test(
      'a Hive record holding $what is listed as unplaced, refuses a new record, and goes with its strategy',
      () async {
        final (storage, store) = await withStrategy(remembered: false);
        await store.close();
        final contents = {
          for (final MapEntry(:key, :value) in storage.contents.entries)
            key: {...value},
        };
        contents['library']![hiveName(strategyId)] = stored;
        final damaged = MemoryStorage(contents);
        final reopened = await openStore(MemoryEngine(damaged));
        final list = listOf(reopened);
        expect(list.hiveRecords, isEmpty);
        expect(list.unplaced.map((row) => row.ref), [
          StoredRowRef('library', hiveName(strategyId)),
        ]);
        expect(
          await reopened.editLibrary([RememberHiveRecord(record)]),
          isA<Refused<LibraryEdited, LibraryRefusal>>().having(
            (r) => r.reason,
            'reason',
            isA<UnplacedRowInTheWay>(),
          ),
        );
        savedValue(
          await reopened.editLibrary([const RemoveStrategy(strategyId)]),
        );
        expect(listOf(reopened).unplaced, isEmpty);
        await reopened.close();
        expect(
          damaged.contents['library']?.containsKey(hiveName(strategyId)) ??
              false,
          isFalse,
        );
      },
    );
  }

  test(
    'a stored record keeps a field this build does not know when its digest is replaced from it',
    () async {
      final (storage, store) = await withStrategy(remembered: false);
      await store.close();
      final contents = {
        for (final MapEntry(:key, :value) in storage.contents.entries)
          key: {...value},
      };
      contents['library']![hiveName(strategyId)] =
          '{"copiedBy":"a newer build","digest":"d1","strategyPublicId":"$strategyId"}';
      final stored = MemoryStorage(contents);
      final reopened = await openStore(MemoryEngine(stored));
      final held = listOf(reopened).hiveRecords[strategyId]!;
      expect(held.unknownFields['copiedBy'], 'a newer build');
      savedValue(
        await reopened.editLibrary([RememberHiveRecord(held.withDigest('d2'))]),
      );
      await reopened.close();
      expect(
        stored.contents['library']![hiveName(strategyId)],
        '{"copiedBy":"a newer build","digest":"d2","strategyPublicId":"$strategyId"}',
      );
    },
  );

  test('a folder keeps the time it was created', () async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    final created = DateTime.utc(2025, 3, 4, 5, 6, 7, 8);
    final folder = ReadableFolder(
      publicId: 'f1',
      name: 'Ascent',
      createdAt: created,
    );
    savedValue(await store.editLibrary([PutFolder(folder)]));
    await store.close();
    final folders = listOf(await openStore(MemoryEngine(storage))).folders;
    expect(folders, [folder]);
    expect((folders.single as ReadableFolder).createdAt, created);
  });
}

final class _CommitCounter extends ForwardingLease {
  _CommitCounter(super.inner, this.counted);

  final void Function() counted;

  @override
  Future<Committing> commit(List<Change> changes) {
    counted();
    return super.commit(changes);
  }
}
