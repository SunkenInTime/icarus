import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

Future<(LibraryStore, Counts, MemoryStorage)> _countedOn(
  Contents contents,
) async {
  final storage = MemoryStorage(contents);
  final (engine, counts) = counting(MemoryEngine(storage));
  final store = await openStore(engine);
  counts.reset();
  return (store, counts, storage);
}

Contents _withDamagedRows(Contents contents) {
  final damaged = editable(contents);
  damaged[sampleArea]![elementName('page-a', 'jett')] = '{not json';
  damaged[sampleArea]![pageName('page-orphan')] = '{"also": "not a page"}';
  return damaged;
}

Map<String, String> _otherRows(Contents contents) => {
  for (final MapEntry(:key, :value) in contents[sampleArea]!.entries)
    if (key != 'strategy') key: value,
};

StrategySummary _listed(LibraryStore store, String id) =>
    listOf(store).strategies.singleWhere((summary) => summary.publicId == id);

void main() {
  test('moving or renaming a strategy kept here reads its header and the '
      'names of its rows, and none of its pages, settings or items', () async {
    final (store, counts, _) = await _countedOn(await seededClean());

    savedValue(
      await store.editLibrary([
        PutFolder(ReadableFolder(publicId: 'folder', name: 'Folder')),
      ]),
    );
    counts.reset();
    savedValue(
      await store.editLibrary([const MoveStrategy(strategyId, 'folder')]),
    );
    savedValue(
      await store.editLibrary([const RenameStrategy(strategyId, 'Renamed')]),
    );

    expect(counts.reads, [(sampleArea, 'strategy'), (sampleArea, 'strategy')]);
    expect(counts.entryListings, isEmpty);
    expect(counts.keyListings, [(sampleArea, ''), (sampleArea, '')]);
    expect(_listed(store, strategyId).name, 'Renamed');
    expect(_listed(store, strategyId).folderPublicId, 'folder');
    await store.close();
  });

  test(
    'a rename and a move of a strategy with unreadable rows change its header '
    'and summary, and leave every other row byte for byte as it was',
    () async {
      final damaged = _withDamagedRows(await seededClean());
      final (store, _, storage) = await _countedOn(damaged);
      savedValue(
        await store.editLibrary([
          PutFolder(ReadableFolder(publicId: 'folder', name: 'Folder')),
        ]),
      );

      savedValue(
        await store.editLibrary([const RenameStrategy(strategyId, 'Renamed')]),
      );
      savedValue(
        await store.editLibrary([const MoveStrategy(strategyId, 'folder')]),
      );
      await store.close();

      expect(_otherRows(storage.contents), _otherRows(damaged));
      final reopened = await openOn(storage.contents);
      expect(_listed(reopened, strategyId).name, 'Renamed');
      expect(_listed(reopened, strategyId).folderPublicId, 'folder');
      await reopened.close();
    },
  );

  test(
    'a move and a rename in one edit keep both, with one revision more',
    () async {
      final (store, _, storage) = await _countedOn(await seededClean());
      savedValue(
        await store.editLibrary([
          PutFolder(ReadableFolder(publicId: 'folder', name: 'Folder')),
        ]),
      );
      final before = _listed(store, strategyId);

      savedValue(
        await store.editLibrary([
          const MoveStrategy(strategyId, 'folder'),
          const RenameStrategy(strategyId, 'Renamed'),
        ]),
      );
      await store.close();

      final reopened = await openOn(storage.contents);
      final header = headerOf(
        strategyOf(await reopened.readStrategy(strategyId)),
      );
      expect(header.name, 'Renamed');
      expect(header.folderPublicId, 'folder');
      expect(header.revision, strategyRow(publicId: strategyId).revision + 1);
      expect(_listed(reopened, strategyId).name, isNot(before.name));
      await reopened.close();
    },
  );

  test('renaming a strategy back to its stored name in the same edit writes '
      'nothing', () async {
    final (store, counts, _) = await _countedOn(await seededClean());
    final name = _listed(store, strategyId).name;

    expect(
      await store.editLibrary([
        const RenameStrategy(strategyId, 'Renamed'),
        RenameStrategy(strategyId, name),
      ]),
      isA<NothingToSave<LibraryEdited, LibraryRefusal>>(),
    );
    expect(counts.written, isEmpty);
    await store.close();
  });

  test('a strategy whose header cannot be read is refused a rename and a move, '
      'with nothing written and the strategy still listed, and a remove takes '
      'it out whole', () async {
    final damaged = editable(await seededClean());
    damaged[sampleArea]!['strategy'] = '{not json';
    final (store, counts, storage) = await _countedOn(damaged);
    final listed = _listed(store, strategyId);

    for (final change in [
      const RenameStrategy(strategyId, 'Renamed'),
      const MoveStrategy(strategyId, null),
    ]) {
      expect(
        await store.editLibrary([change]),
        isA<Refused<LibraryEdited, LibraryRefusal>>(),
        reason: '$change',
      );
    }

    expect(counts.written, isEmpty);
    expect(counts.deleted, isEmpty);
    expect(_listed(store, strategyId), listed);

    savedValue(await store.editLibrary([const RemoveStrategy(strategyId)]));
    await store.close();
    expect(storage.contents[sampleArea] ?? const {}, isEmpty);
  });

  test('removing a strategy that is not in the store is refused as no such '
      'strategy, and removing one with rows but no header is refused with a '
      'reference that removes it', () async {
    final noHeader = editable(await seededClean());
    noHeader[sampleArea]!.remove('strategy');
    final (store, counts, storage) = await _countedOn(noHeader);

    expect(
      await store.editLibrary([const RemoveStrategy('never-there')]),
      isA<Refused<LibraryEdited, LibraryRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<NoSuchStrategy>(),
      ),
    );
    final refusal = switch (await store.editLibrary([
      const RemoveStrategy(strategyId),
    ])) {
      Refused(reason: final StrategyNotReadable refusal) => refusal,
      final other => fail('$other'),
    };
    expect(counts.deleted, isEmpty);

    savedValue(
      await store.editLibrary([RemoveUnreadableStrategy(refusal.ref)]),
    );
    await store.close();
    expect(storage.contents[sampleArea] ?? const {}, isEmpty);
  });

  test('a strategy with no summary is renamed from a summary rebuilt from its '
      'rows, the one header change that reads them', () async {
    final noSummary = editable(await seededClean());
    noSummary['library']!.remove(summaryName(strategyId));
    final (store, counts, storage) = await _countedOn(noSummary);

    savedValue(
      await store.editLibrary([const RenameStrategy(strategyId, 'Renamed')]),
    );

    expect(counts.entryListings, isNotEmpty);
    await store.close();
    final reopened = await openOn(storage.contents);
    expect(_listed(reopened, strategyId).name, 'Renamed');
    await reopened.close();
  });

  test('the written versions are read for every strategy asked, newer, missing '
      'and malformed alike', () async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    savedValue(
      await store.editLibrary([
        AddStrategy(
          sampleStrategy(id: 'current', prefix: 'current-'),
          writtenAt: 40,
        ),
        AddStrategy(
          sampleStrategy(id: 'newer', prefix: 'newer-'),
          writtenAt: 99,
        ),
        AddStrategy(sampleStrategy(id: 'unrecorded', prefix: 'unrecorded-')),
        AddStrategy(
          sampleStrategy(id: 'malformed', prefix: 'malformed-'),
          writtenAt: 40,
        ),
      ]),
    );
    await store.close();
    final contents = editable(storage.contents);
    contents[strategyArea('malformed')]!['written'] = 'forty';
    final reopened = await openOn(contents);

    final written = switch (await reopened.writtenOf([
      'current',
      'newer',
      'unrecorded',
      'malformed',
    ])) {
      Done(:final value) => value,
      StorageFailed(:final failure) => fail('$failure'),
    };

    expect(
      written['current'],
      isA<WrittenAt>().having((w) => w.version, 'version', 40),
    );
    expect(
      written['newer'],
      isA<WrittenAt>().having((w) => w.version, 'version', 99),
    );
    expect(written['unrecorded'], isA<WrittenNotRecorded>());
    expect(written['malformed'], isA<WrittenUnreadable>());
    await reopened.close();
  });
}
