import 'dart:convert';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

const _second = 'strategy-2';
const _third = 'strategy-3';

ReadableFolder _folder(String id, {String? parent}) =>
    ReadableFolder(publicId: id, name: id, parentFolderPublicId: parent);

final _pool = <LibraryChange>[
  PutFolder(_folder('f1')),
  PutFolder(_folder('f2')),
  PutFolder(_folder('f2', parent: 'f1')),
  const RemoveFolder('f1'),
  const RemoveFolder('f2'),
  for (final id in [strategyId, _second, _third]) ...[
    MoveStrategy(id, null),
    MoveStrategy(id, 'f1'),
    MoveStrategy(id, 'f2'),
    RenameStrategy(id, 'Renamed'),
    RenameStrategy(id, strategyRow(publicId: id).name),
    RemoveStrategy(id),
  ],
  AddStrategy(sampleStrategy(id: _third, prefix: 'three-')),
];

String _describe(LibraryChange change) => switch (change) {
  PutFolder(:final folder) =>
    'put ${folder.publicId} under ${folder.parentFolderPublicId}',
  RemoveFolder(:final folderPublicId) => 'remove folder $folderPublicId',
  MoveStrategy(:final strategyPublicId, :final folderPublicId) =>
    'move $strategyPublicId to $folderPublicId',
  RenameStrategy(:final strategyPublicId, :final name) =>
    'rename $strategyPublicId to $name',
  RemoveStrategy(:final strategyPublicId) => 'remove $strategyPublicId',
  AddStrategy(:final rows) => 'add ${rows.strategy.publicId}',
  RemoveUnreadableStrategy(:final ref) => 'remove unreadable ${ref.area}',
};

Contents _copied(Contents contents) => {
  for (final MapEntry(:key, :value) in contents.entries) key: {...value},
};

Map<String, Map<String, Object?>> _withoutClock(Contents contents) => {
  for (final MapEntry(key: area, value: names) in contents.entries)
    if (names.isNotEmpty)
      area: {
        for (final MapEntry(:key, :value) in names.entries)
          key: switch (jsonDecode(value)) {
            final Map<String, Object?> row
                when key == 'strategy' || key.startsWith('summary/') =>
              {...row}
                ..remove('revision')
                ..remove('updatedAt'),
            final other => other,
          },
      },
};

bool _readdsRemoved(List<LibraryChange> changes) {
  final removed = <String>{};
  for (final change in changes) {
    switch (change) {
      case RemoveStrategy(:final strategyPublicId):
        removed.add(strategyPublicId);
      case AddStrategy(:final rows)
          when removed.contains(rows.strategy.publicId):
        return true;
      case _:
        break;
    }
  }
  return false;
}

void main() {
  late Contents base;

  setUpAll(() async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    savedValue(
      await store.editLibrary([
        PutFolder(_folder('f1')),
        AddStrategy(sampleStrategy()),
        AddStrategy(sampleStrategy(id: _second, prefix: 'two-')),
        MoveStrategy(_second, 'f1'),
      ]),
    );
    await store.close();
    base = storage.contents;
  });

  test(
    'a library edit of several steps saves what the same steps save one edit at a time, or refuses and saves nothing',
    () async {
      final random = Random(671);
      final outcomes = <String>{};
      for (var round = 0; round < 400; round++) {
        final changes = [
          for (var i = 0; i < 1 + random.nextInt(4); i++)
            _pool[random.nextInt(_pool.length)],
        ];
        final where = changes.map(_describe).join(', ');
        final batchDisk = MemoryStorage(_copied(base));
        final batchStore = await openStore(MemoryEngine(batchDisk));
        final batch = await batchStore.editLibrary(changes);
        await batchStore.close();
        final oneDisk = MemoryStorage(_copied(base));
        final oneStore = await openStore(MemoryEngine(oneDisk));
        final steps = [
          for (final change in changes) await oneStore.editLibrary([change]),
        ];
        await oneStore.close();
        outcomes.add(switch (batch) {
          Saved() => 'saved',
          NothingToSave() => 'nothing to save',
          Refused() => 'refused',
          NotSaved() || SaveInDoubt() => 'not saved',
        });
        switch (batch) {
          case Saved() || NothingToSave():
            expect(
              steps.whereType<Refused<LibraryEdited, LibraryRefusal>>(),
              isEmpty,
              reason: '$where: saved together, refused alone',
            );
            expect(
              _withoutClock(batchDisk.contents),
              _withoutClock(oneDisk.contents),
              reason: where,
            );
            final reopened = await openStore(MemoryEngine(batchDisk));
            for (final summary in listOf(reopened).strategies) {
              expect(
                await reopened.rebuildSummary(summary.publicId),
                isA<NothingToSave<StrategySummary, CommitRefusal>>(),
                reason: '$where: the summary of ${summary.publicId}',
              );
            }
            await reopened.close();
          case Refused():
            expect(
              sameContents(batchDisk.contents, base),
              isTrue,
              reason: where,
            );
            expect(
              steps.any((step) => step is Refused) || _readdsRemoved(changes),
              isTrue,
              reason: '$where: refused together, saved alone',
            );
          case NotSaved() || SaveInDoubt():
            fail('$where: $batch');
        }
      }
      expect(outcomes, {'saved', 'nothing to save', 'refused'});
    },
  );

  test(
    'a move after a removal of the same strategy in one edit is refused, and nothing is saved',
    () async {
      final disk = MemoryStorage(_copied(base));
      final store = await openStore(MemoryEngine(disk));
      expect(
        await store.editLibrary([
          PutFolder(_folder('f2')),
          const RemoveStrategy(strategyId),
          const MoveStrategy(strategyId, 'f2'),
        ]),
        isA<Refused<LibraryEdited, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<NoSuchStrategy>(),
        ),
      );
      expect(sameContents(disk.contents, base), isTrue);
    },
  );
}
