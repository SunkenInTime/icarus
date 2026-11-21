import 'dart:convert';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

sealed class Expected {
  const Expected();
}

final class Files extends Expected {
  const Files();
}

final class Loops extends Expected {
  const Loops(this.folders);

  final Set<String> folders;
}

final class Dangles extends Expected {
  const Dangles(this.missing);

  final String missing;
}

Expected oracle(String start, Map<String, String?> parents) {
  final seen = <String>[];
  String? at = start;
  while (at != null) {
    if (seen.contains(at)) return Loops(seen.sublist(seen.indexOf(at)).toSet());
    seen.add(at);
    if (!parents.containsKey(at)) return Dangles(at);
    at = parents[at];
  }
  return const Files();
}

void expectAnswer<S, R>(Saving<S, R> result, Expected expected, String where) {
  switch (expected) {
    case Files():
      expect(result, isA<Saved<S, R>>(), reason: where);
    case Loops(:final folders):
      expect(
        result,
        isA<Refused<S, R>>().having(
          (refused) => refused.reason,
          'reason',
          isA<FolderLoop>().having(
            (loop) => loop.folders.toSet(),
            'folders',
            folders,
          ),
        ),
        reason: where,
      );
    case Dangles(:final missing):
      expect(
        result,
        isA<Refused<S, R>>().having(
          (refused) => refused.reason,
          'reason',
          isA<NoSuchFolder>().having(
            (reason) => reason.folderPublicId,
            'folder',
            missing,
          ),
        ),
        reason: where,
      );
  }
}

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = await seededContents();
  });

  test(
    'every walk over stored parents ends, whatever the parents are',
    () async {
      final random = Random(629);
      for (var round = 0; round < 40; round++) {
        final ids = [for (var i = 0; i < 6; i++) 'f$i'];
        final parents = {
          for (final id in ids)
            id: switch (random.nextInt(4)) {
              0 => null,
              1 => 'gone',
              _ => ids[random.nextInt(ids.length)],
            },
        };
        final folders = {
          for (final MapEntry(key: id, value: parent) in parents.entries)
            folderName(id): jsonEncode({
              'publicId': id,
              'name': id,
              'parentFolderPublicId': ?parent,
            }),
        };
        final contents = {
          ...seeded,
          'library': {...seeded['library']!, ...folders},
        };
        for (final id in ids) {
          final store = await openOn(contents);
          expect(listOf(store).folders, hasLength(ids.length));
          final where = 'round $round, under $id, parents $parents';
          expectAnswer(
            await store
                .editLibrary([
                  PutFolder(
                    ReadableFolder(
                      publicId: 'new',
                      name: 'new',
                      parentFolderPublicId: id,
                    ),
                  ),
                ])
                .timeout(const Duration(seconds: 2)),
            oracle(id, parents),
            where,
          );
          expectAnswer(
            await store
                .editLibrary([MoveStrategy(strategyId, id)])
                .timeout(const Duration(seconds: 2)),
            oracle(id, parents),
            where,
          );
        }
      }
    },
  );

  test('a folder cannot be filed under itself through a chain', () async {
    final store = await openOn(seeded);
    savedValue(
      await store.editLibrary([
        PutFolder(ReadableFolder(publicId: 'a', name: 'a')),
        PutFolder(
          ReadableFolder(publicId: 'b', name: 'b', parentFolderPublicId: 'a'),
        ),
      ]),
    );
    expect(
      await store.editLibrary([
        PutFolder(
          ReadableFolder(publicId: 'a', name: 'a', parentFolderPublicId: 'b'),
        ),
      ]),
      isA<Refused<LibraryEdited, LibraryRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<FolderInsideItself>(),
      ),
    );
  });

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
