import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

Future<Contents> settledContents(Contents disk) async {
  final engine = MemoryEngine(disk);
  final store = await openStore(engine);
  await store.close();
  return engine.contents;
}

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = (await seededEngine()).contents;
  });

  for (final MapEntry(key: name, value: op) in everyOpType().entries) {
    test(
      'a crash at any write of $name leaves the rows before or after',
      () async {
        final cleanDisk = MemoryEngine(seeded);
        final clean = CountingEngine(cleanDisk);
        final cleanStore = await openStore(clean);
        clean.reset();
        savedValue(await cleanStore.commit(strategyId, op));
        final after = cleanDisk.contents;
        final writes = clean.keyWrites;
        expect(writes, greaterThanOrEqualTo(4));
        expect(sameContents(after, seeded), isFalse);

        var crashesSeen = 0;
        for (var allowed = 0; allowed < writes; allowed++) {
          final disk = MemoryEngine(seeded);
          final crashing = CrashingEngine(disk, afterWrites: allowed);
          final store = await openStore(crashing);
          final result = await store.commit(strategyId, op);
          expect(crashing.hasCrashed, isTrue, reason: 'crash after $allowed');
          crashesSeen++;
          final cutShort = disk.contents;
          final reopened = withoutJournal(await settledContents(cutShort));
          final isBefore = sameContents(reopened, withoutJournal(seeded));
          final isAfter = sameContents(reopened, withoutJournal(after));
          expect(
            isBefore || isAfter,
            isTrue,
            reason: 'crash after $allowed writes left rows that are neither',
          );
          switch (result) {
            case Saved():
              expect(isAfter, isTrue, reason: 'saved, then lost at $allowed');
            case NotSaved():
              expect(
                isBefore,
                isTrue,
                reason: 'not saved, yet kept at $allowed',
              );
            case SaveInDoubt():
              break;
            case NothingToSave() || Refused():
              fail('unexpected ${describeSaving(result)}');
          }
          if (cutShort.containsKey('journal')) {
            final replayWrites = CountingEngine(MemoryEngine(cutShort));
            await openStore(replayWrites);
            for (var again = 0; again < replayWrites.keyWrites; again++) {
              final second = MemoryEngine(cutShort);
              await LibraryStore.open(
                CrashingEngine(second, afterWrites: again),
                canRead: readsKnownKinds,
                clock: fixedClock,
              );
              final settled = withoutJournal(
                await settledContents(second.contents),
              );
              expect(
                sameContents(settled, withoutJournal(after)),
                isTrue,
                reason: 'a crash while finishing at $again lost the edit',
              );
            }
          }
        }
        expect(crashesSeen, writes);
      },
    );
  }

  test('a page copy writes every copied row in one saved edit', () async {
    final engine = CountingEngine(MemoryEngine(seeded));
    final store = await openStore(engine);
    engine.reset();
    final edited = savedValue(
      await store.commit(strategyId, everyOpType()['page.add copying a page']!),
    );
    expect(
      edited.writes.whereType<RowAdded>().map((write) => write.after),
      containsAll([
        isA<LiveElement>(),
        isA<UnreadableElement>(),
        isA<LiveLineupGroup>(),
        isA<PageSettingsRow>(),
      ]),
    );
    expect(engine.written.where((key) => key.$1 == 'journal'), hasLength(1));
  });
}
