import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

Future<LibraryStore> openWith(
  MemoryStorage disk,
  DateTime Function() clock,
) async => switch (await LibraryStore.open(
  MemoryEngine(disk),
  canRead: readsKnownKinds,
  clock: clock,
)) {
  StoreOpened(:final store) => store,
  StoreNotOpened(:final problem) => fail('$problem'),
};

Future<SaveReceipt> inDoubt<S, R>(
  MemoryStorage disk,
  Failing record,
  Future<Saving<S, R>> Function(LibraryStore store) edit,
) async {
  await (await openStore(MemoryEngine(disk))).close();
  final store = await openStore(
    flaky(MemoryEngine(disk), {0: record, 1: Failing.refused}),
  );
  final result = await edit(store);
  await store.close();
  return switch (result) {
    SaveInDoubt(:final receipt) => receipt,
    final other => fail('expected doubt, got ${describeSaving(other)}'),
  };
}

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = await seededContents();
  });

  ReadableFolder folder(String name) =>
      ReadableFolder(publicId: 'f', name: name);

  test(
    'two edits of one folder in one clock tick get their own answers',
    () async {
      final disk = MemoryStorage(seeded);
      final landed = await inDoubt(
        disk,
        Failing.landed,
        (store) => store.editLibrary([PutFolder(folder('A'))]),
      );
      final lost = await inDoubt(
        disk,
        Failing.refused,
        (store) => store.editLibrary([PutFolder(folder('B'))]),
      );
      expect(landed.issuedAt, lost.issuedAt);
      expect(landed, isNot(lost));
      final reopened = await openStore(MemoryEngine(disk));
      expect(await reopened.recovered(landed), isA<EditRecovered>());
      expect(await reopened.recovered(lost), isA<EditNotRecovered>());
      expect(
        listOf(reopened).folders.single,
        isA<ReadableFolder>().having((row) => row.name, 'name', 'A'),
      );
    },
  );

  test('a retry of the same op gets an answer of its own', () async {
    final disk = MemoryStorage(seeded);
    final first = await inDoubt(
      disk,
      Failing.refused,
      (store) => store.commit(strategyId, moveJett),
    );
    final retry = await inDoubt(
      disk,
      Failing.landed,
      (store) => store.commit(strategyId, moveJett),
    );
    expect(first, isNot(retry));
    final reopened = await openStore(MemoryEngine(disk));
    expect(await reopened.recovered(first), isA<EditNotRecovered>());
    expect(await reopened.recovered(retry), isA<EditRecovered>());
  });

  test(
    'an answer outlives later reopenings, then is forgotten after its lifetime',
    () async {
      final disk = MemoryStorage(seeded);
      final receipt = await inDoubt(
        disk,
        Failing.landed,
        (store) => store.commit(strategyId, moveJett),
      );
      for (var open = 0; open < 3; open++) {
        final reopened = await openStore(MemoryEngine(disk));
        expect(await reopened.recovered(receipt), isA<EditRecovered>());
        expect(disk.contents['journal']?['edit'], isNull);
        await reopened.close();
      }
      final later = editedAt.add(
        recoveryAnswerLifetime + const Duration(days: 1),
      );
      final pruned = await openWith(disk, () => later);
      expect(await pruned.recovered(receipt), isA<RecoveryForgotten>());
      expect(disk.contents['journal'], isNull);
    },
  );

  test('a stopped store does not answer for its own receipt', () async {
    final disk = MemoryStorage(seeded);
    final store = await openStore(
      flaky(MemoryEngine(disk), {0: Failing.landed, 1: Failing.refused}),
    );
    final result = await store.commit(strategyId, moveJett);
    final receipt = (result as SaveInDoubt<Committed, CommitRefusal>).receipt;
    expect(await store.recovered(receipt), isA<RecoveryNotRead>());
  });
}
