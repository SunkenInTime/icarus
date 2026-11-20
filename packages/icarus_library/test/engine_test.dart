@TestOn('vm')
library;

import 'dart:io';

import 'package:icarus_library/hive_storage.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

T done<T>(Stored<T> stored) => switch (stored) {
  Done(:final value) => value,
  StorageFailed(:final failure) => fail('storage failed: $failure'),
};

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-store-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  final engines =
      <String, Future<(StorageEngine, Future<void> Function())> Function()>{
        'memory': () async => (MemoryEngine(), () async {}),
        'hive': () async {
          final engine = HiveEngine(directory.path);
          return (engine as StorageEngine, engine.close);
        },
      };

  for (final MapEntry(key: name, value: make) in engines.entries) {
    group('The $name engine', () {
      test(
        'reads what it wrote, by area, and lists keys by prefix in order',
        () async {
          final (engine, close) = await make();
          done(
            await engine.write('a', {
              'page/2': 'two',
              'page/1': 'one',
              'other': 'x',
            }),
          );
          done(await engine.write('b', {'page/1': 'elsewhere'}));
          expect(done(await engine.read('a', 'page/1')), 'one');
          expect(done(await engine.read('a', 'missing')), isNull);
          expect(done(await engine.keys('a', 'page/')), ['page/1', 'page/2']);
          done(await engine.delete('a', ['page/1']));
          expect(done(await engine.keys('a', '')), ['other', 'page/2']);
          expect(done(await engine.read('b', 'page/1')), 'elsewhere');
          await close();
        },
      );
    });
  }

  test('the hive engine keeps what it wrote across a close', () async {
    final first = HiveEngine(directory.path);
    done(await first.write('strategy/x', {'strategy': '{"a":1}'}));
    await first.close();
    final second = HiveEngine(directory.path);
    expect(done(await second.read('strategy/x', 'strategy')), '{"a":1}');
    await second.close();
  });

  test('the hive engine refuses a key Hive cannot hold', () async {
    final engine = HiveEngine(directory.path);
    final key = 'k' * 256;
    expect(
      await engine.write('library', {key: 'v'}),
      isA<StorageFailed<void>>().having(
        (failed) => failed.failure,
        'failure',
        isA<KeyTooLong>(),
      ),
    );
    await engine.close();
  });

  test('the store saves and reopens on hive files', () async {
    final engine = HiveEngine(directory.path);
    final store = await openStore(engine);
    savedValue(
      await store.editLibrary([
        AddStrategy(
          sampleStrategy(),
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ]),
    );
    final moved = savedValue(
      await store.commit(
        strategyId,
        everyOpType()['element.patch to another page']!,
      ),
    );
    await store.close();
    await engine.close();

    final reopenedEngine = HiveEngine(directory.path);
    final reopened = await openStore(reopenedEngine);
    expect(reopened.library.strategies.single, moved.summary);
    final pageB = pageOf(await reopened.readPage(strategyId, 'page-b'));
    expect(pageB.elements, contains(moved.writes.single.after));
    await reopenedEngine.close();
  });

  test(
    'an edit cut short after its record is finished on hive files',
    () async {
      final engine = HiveEngine(directory.path);
      final store = await openStore(engine);
      savedValue(
        await store.editLibrary([
          AddStrategy(
            sampleStrategy(),
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        ]),
      );
      await engine.close();

      final cut = HiveEngine(directory.path);
      final crashing = await openStore(CrashingEngine(cut, afterWrites: 1));
      final copy = savedValue(
        await crashing.commit(
          strategyId,
          everyOpType()['page.add copying a page']!,
        ),
      );
      expect(done(await cut.read('journal', 'edit')), isNotNull);
      await cut.close();

      final reopenedEngine = HiveEngine(directory.path);
      final reopened = await openStore(reopenedEngine);
      expect(done(await reopenedEngine.read('journal', 'edit')), isNull);
      expect(reopened.library.strategies.single, copy.summary);
      final copied = pageOf(await reopened.readPage(strategyId, 'page-copy'));
      expect(copied.elements, hasLength(3));
      expect(copied.lineupGroups, hasLength(1));
      await reopenedEngine.close();
    },
  );

  test('a second hive engine on another directory is refused', () async {
    final other = await Directory.systemTemp.createTemp('icarus-store-other-');
    final first = HiveEngine(directory.path);
    done(await first.write('library', {'a': 'b'}));
    final second = HiveEngine(other.path);
    expect(await second.read('library', 'a'), isA<StorageFailed<String?>>());
    await first.close();
    expect(done(await second.read('library', 'a')), isNull);
    await second.close();
    await other.delete(recursive: true);
  });

  test('a box that failed to open is opened again on the next call', () async {
    final blocker = Directory('${directory.path}/icarus_store_library.hive');
    await blocker.create();
    final engine = HiveEngine(directory.path);
    expect(await engine.read('library', 'a'), isA<StorageFailed<String?>>());
    await blocker.delete();
    expect(done(await engine.read('library', 'a')), isNull);
    await engine.close();
  });

  test('a second hive engine on the same directory is refused', () async {
    final first = HiveEngine(directory.path);
    done(await first.write('library', {'a': 'b'}));
    final second = HiveEngine(directory.path);
    expect(await second.read('library', 'a'), isA<StorageFailed<String?>>());
    await first.close();
    expect(done(await second.read('library', 'a')), 'b');
    await second.close();
  });
}
