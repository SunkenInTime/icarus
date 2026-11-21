import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

final class Utf8Lease extends ForwardingLease {
  Utf8Lease(super.inner);

  @override
  Future<Committing> commit(List<Change> changes) => super.commit([
    for (final change in changes)
      switch (change) {
        Put(:final area, :final key, :final value) => Put(
          area,
          key,
          utf8.decode(utf8.encode(value), allowMalformed: true),
        ),
        final other => other,
      },
  ]);
}

StorageEngine throughUtf8(MemoryStorage disk) =>
    WrappingEngine(MemoryEngine(disk), Utf8Lease.new);

const ids = [
  '﻿jett',
  '﻿',
  '\uD800',
  '�',
  'a\uDC00b',
  '😀',
  '%',
  '%73trategy-1',
  '/',
  'a/b',
  '',
  ' ',
  '\u0000',
  'Säge',
  'UPPER-lower_~.',
  '..',
];

const lineupRefuses = {''};

final longIds = ['x' * 100, 'x' * 300];

Future<int> revisionOf(LibraryStore store, String id) async =>
    headerOf(strategyOf(await store.readStrategy(id))).revision;

Future<LibraryStore> reopened(MemoryStorage disk) =>
    openStore(throughUtf8(disk));

void main() {
  late Contents seeded;

  setUpAll(() async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
    await store.close();
    seeded = storage.contents;
  });

  for (final (index, id) in [...ids, ...longIds].indexed) {
    test('id $index ${id.codeUnits.take(8).toList()} is saved as every kind '
        'of row and comes back the same', () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(throughUtf8(disk));
      savedValue(
        await store.commit(
          strategyId,
          ElementAddOp(
            opId: 'add-element',
            elementPublicId: id,
            pagePublicId: 'page-a',
            payload: agent(id).payload,
            sortIndex: 9,
          ),
        ),
      );
      final grouping = await store.commit(
        strategyId,
        LineupGroupAddOp(
          opId: 'add-group',
          lineupPublicId: id,
          pagePublicId: 'page-b',
          payload: lineupPayload(id),
          sortIndex: 0,
        ),
      );
      final grouped = !lineupRefuses.contains(id);
      if (grouped) {
        savedValue(grouping);
      } else {
        expect(
          grouping,
          isA<Refused<Committed, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<OpRefusal>().having(
              (reason) => reason.refusal,
              'refusal',
              const Failed(FailureCode.invalidLineupPayloadData),
            ),
          ),
        );
      }
      savedValue(
        await store.commit(
          strategyId,
          PageAddOp(
            opId: 'add-page',
            pagePublicId: id,
            sortIndex: 3,
            expectedStrategyRevision: await revisionOf(store, strategyId),
            settings: defaultSettings,
          ),
        ),
      );
      savedValue(
        await store.editLibrary([
          PutFolder(ReadableFolder(publicId: id, name: 'folder')),
          AddStrategy(sampleStrategy(id: id, prefix: 'other-')),
        ]),
      );
      await store.close();

      final again = await reopened(disk);
      expect(listOf(again).folders.map((row) => row.publicId), [id]);
      expect(
        listOf(again).strategies.map((row) => row.publicId),
        unorderedEquals([strategyId, id]),
      );
      expect(headerOf(strategyOf(await again.readStrategy(id))).publicId, id);
      final content = strategyOf(await again.readStrategy(strategyId));
      expect(content.pages.map((row) => row.publicId), contains(id));
      final pageA = pageOf(await again.readPage(strategyId, 'page-a'));
      expect(elementOn(pageA, id), isA<LiveElement>());
      final pageB = pageOf(await again.readPage(strategyId, 'page-b'));
      expect(
        pageB.lineupGroups.map((row) => row.publicId).contains(id),
        grouped,
      );
      expect(
        [...pageA.elements, ...pageB.elements].whereType<UnreadableElement>(),
        isEmpty,
      );
      expect(pageB.lineupGroups.whereType<UnreadableLineupGroup>(), isEmpty);
    });
  }

  test('a lone surrogate and the replacement character are two ids', () async {
    final disk = MemoryStorage(seeded);
    final store = await openStore(throughUtf8(disk));
    for (final (index, id) in ['\uD800', '�'].indexed) {
      savedValue(
        await store.commit(
          strategyId,
          PageAddOp(
            opId: 'add-page-$index',
            pagePublicId: id,
            sortIndex: 3 + index,
            expectedStrategyRevision: await revisionOf(store, strategyId),
            settings: defaultSettings,
          ),
        ),
      );
      savedValue(
        await store.commit(
          strategyId,
          ElementAddOp(
            opId: 'add-element-$index',
            elementPublicId: id,
            pagePublicId: id,
            payload: agent(id).payload,
            sortIndex: 0,
          ),
        ),
      );
    }
    savedValue(
      await store.editLibrary([
        AddStrategy(sampleStrategy(id: '\uD800', prefix: 'a-')),
        AddStrategy(sampleStrategy(id: '�', prefix: 'b-')),
      ]),
    );
    await store.close();

    final again = await reopened(disk);
    expect(
      listOf(again).strategies.map((row) => row.publicId),
      unorderedEquals([strategyId, '\uD800', '�']),
    );
    final pages = strategyOf(await again.readStrategy(strategyId)).pages;
    expect(pages.map((row) => row.publicId), containsAll(['\uD800', '�']));
    for (final id in ['\uD800', '�']) {
      final page = pageOf(await again.readPage(strategyId, id));
      expect(page.elements.map((row) => row.publicId), [id]);
    }
  });
}
