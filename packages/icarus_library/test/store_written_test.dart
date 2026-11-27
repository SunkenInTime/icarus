import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

void main() {
  Future<StrategyWritten> writtenAfterReopen(MemoryStorage storage) async {
    final store = await openStore(MemoryEngine(storage));
    final content = switch (await store.readStrategy(
      strategyRows().strategy.publicId,
    )) {
      Found(:final value) => value,
      final other => fail('$other'),
    };
    await store.close();
    return content.written;
  }

  test('a strategy put with the version it was written at reads it back after '
      'a reopen', () async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));

    savedValue(await store.putStrategy(strategyRows(), writtenAt: 113));
    await store.close();

    expect(
      await writtenAfterReopen(storage),
      isA<WrittenAt>().having((written) => written.version, 'version', 113),
    );
    expect(
      storage.contents.values.any((area) => area['written'] == '113'),
      isTrue,
    );
  });

  test('a strategy put without a version has none recorded', () async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));

    savedValue(await store.putStrategy(strategyRows()));
    await store.close();

    expect(await writtenAfterReopen(storage), isA<WrittenNotRecorded>());
  });

  test(
    'putting the same rows at a newer version writes only the version',
    () async {
      final storage = MemoryStorage();
      final store = await openStore(MemoryEngine(storage));
      savedValue(await store.putStrategy(strategyRows(), writtenAt: 112));

      expect(
        await store.putStrategy(strategyRows(), writtenAt: 112),
        isA<NothingToSave<LibraryEdited, LibraryRefusal>>(),
      );
      savedValue(await store.putStrategy(strategyRows(), writtenAt: 113));
      await store.close();

      expect(
        await writtenAfterReopen(storage),
        isA<WrittenAt>().having((written) => written.version, 'version', 113),
      );
    },
  );

  test('a recorded version that is not a whole number reads as unreadable, '
      'and the store opens with no foreign names', () async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    savedValue(await store.putStrategy(strategyRows(), writtenAt: 113));
    await store.close();
    final contents = storage.contents;
    final area = contents.keys.singleWhere(
      (name) => contents[name]!.containsKey('written'),
    );
    final damaged = MemoryStorage({
      ...contents,
      area: {...contents[area]!, 'written': 'one hundred'},
    });

    final opened = await LibraryStore.open(
      MemoryEngine(damaged),
      canRead: readsKnownKinds,
      clock: fixedClock,
    );
    expect((opened as StoreOpened).foreignNames, isEmpty);
    await opened.store.close();
    expect(
      await writtenAfterReopen(damaged),
      isA<WrittenUnreadable>().having(
        (written) => written.stored,
        'stored',
        'one hundred',
      ),
    );
  });

  test('a removed strategy takes its recorded version with it', () async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    savedValue(await store.putStrategy(strategyRows(), writtenAt: 113));

    savedValue(
      await store.editLibrary([
        RemoveStrategy(strategyRows().strategy.publicId),
      ]),
    );
    await store.close();

    expect(
      storage.contents.values.any((area) => area.containsKey('written')),
      isFalse,
    );
  });
}
