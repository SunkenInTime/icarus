import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/replay/recycle_bin.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory support;
  late Directory demos;
  late ReplayFiles files;

  /// Where removed replays go, standing in for the Recycle Bin.
  late Directory bin;
  late Future<void> Function(String path) recycle;
  Future<void> moveToBin(String path) async {
    await File(path).rename(p.join(bin.path, p.basename(path)));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('icarus-replay-files');
    support = await Directory(p.join(root.path, 'support')).create();
    demos = await Directory(p.join(root.path, 'VALORANT', 'Saved', 'Demos'))
        .create(recursive: true);
    bin = await Directory(p.join(root.path, 'bin')).create();
    recycle = moveToBin;
    files = ReplayFiles(
      supportDirectory: () async => support,
      valorantDemosPath: demos.path,
      recycle: (path) => recycle(path),
    );
  });

  tearDown(() => root.delete(recursive: true));

  Future<File> writeReplay(Directory directory, String matchId) =>
      File(p.join(directory.path, '$matchId.vrf')).writeAsBytes([1, 2, 3]);

  test('lists replays from both folders once, preferring the kept copy',
      () async {
    await writeReplay(demos, 'a');
    await writeReplay(demos, 'b');
    await File(p.join(demos.path, 'notes.txt')).writeAsString('x');
    final kept = await files.import(p.join(demos.path, 'b.vrf'));

    final listed = await files.list();
    expect(listed.map((file) => file.matchId).toSet(), {'a', 'b'});
    final b = listed.firstWhere((file) => file.matchId == 'b');
    expect(b.source, ReplaySource.icarus);
    expect(b.path, kept.path);
    expect(
      listed.firstWhere((file) => file.matchId == 'a').source,
      ReplaySource.valorant,
    );
  });

  test('import leaves no partial file and is idempotent', () async {
    final source = await writeReplay(root, 'c');
    final first = await files.import(source.path);
    final second = await files.import(source.path);
    expect(second.path, first.path);
    final names = (await (await files.icarusReplaysDirectory()).list().toList())
        .map((entity) => p.basename(entity.path));
    expect(names, ['c.vrf']);
  });

  test('importing a different file of the same name replaces the copy',
      () async {
    final first = await writeReplay(root, 'e');
    await files.import(first.path);
    final other = await Directory(p.join(root.path, 'other')).create();
    final second = File(p.join(other.path, 'e.vrf'));
    await second.writeAsBytes([9, 9, 9, 9, 9]);
    final kept = await files.import(second.path);
    expect(await File(kept.path).readAsBytes(), [9, 9, 9, 9, 9]);
  });

  test('cache is keyed by file and decoder version, and replaces old ones',
      () async {
    await writeReplay(demos, 'd');
    final file = (await files.list()).single;
    expect(await files.readCache(file, 'v1'), isNull);

    await files.writeCache(file, 'v1', Uint8List.fromList([1]));
    expect(await files.readCache(file, 'v1'), [1]);
    expect(await files.readCache(file, 'v2'), isNull);

    await files.writeCache(file, 'v2', Uint8List.fromList([2]));
    expect(await files.readCache(file, 'v1'), isNull);
    expect(await files.readCache(file, 'v2'), [2]);
  });

  test('local subjects come from Valorant config folder names', () async {
    final config = p.join(root.path, 'VALORANT', 'Saved', 'Config');
    await Directory(
      p.join(config, '5B6BD243-D9A3-549D-B84E-2B7D0428C290-na'),
    ).create(recursive: true);
    await Directory(p.join(config, 'WindowsClient')).create();
    await Directory(p.join(config, 'Dara-PC-Duo-2A2FF0E0-na')).create();
    expect(await files.localSubjects(), {
      '5b6bd243-d9a3-549d-b84e-2b7d0428c290',
    });
  });

  test('remove deletes the kept copy and its cache, never the Valorant file',
      () async {
    final original = await writeReplay(demos, 'f');
    final kept = await files.import(original.path);
    // Windows copies keep the file's time, so the copy shares its cache key.
    final time = DateTime(2026, 7, 10, 3, 35, 52);
    await original.setLastModified(time);
    await File(kept.path).setLastModified(time);
    final listed = (await files.list()).single;
    expect(listed.path, kept.path);
    expect(listed.valorantHasCopy, isTrue);
    await files.writeCache(listed, 'v1', Uint8List.fromList([1]));

    final valorantOnly = (await ReplayFiles(
      supportDirectory: () async =>
          Directory(p.join(root.path, 'elsewhere')).create(),
      valorantDemosPath: demos.path,
    ).list())
        .single;
    await expectLater(
      files.remove(valorantOnly),
      throwsA(isA<ReplayRemoveRefused>().having(
          (e) => e.reason, 'reason', ReplayRemoveRefusal.outsideIcarus)),
    );
    expect(await original.exists(), isTrue);

    await files.remove(listed);
    expect(await File(kept.path).exists(), isFalse);
    expect(await File(p.join(bin.path, 'f.vrf')).exists(), isTrue);
    expect(await original.exists(), isTrue);
    final after = (await files.list()).single;
    expect(after.source, ReplaySource.valorant);
    expect(after.valorantHasCopy, isFalse);
    // Same file, same cache: Valorant's copy still uses it.
    expect(after.cacheKey, listed.cacheKey);
    expect(await files.readCache(after, 'v1'), [1]);

    final elsewhere = await writeReplay(root, 'g');
    final onlyKept = await files.import(elsewhere.path);
    await files.writeCache(onlyKept, 'v1', Uint8List.fromList([2]));
    await files.remove(onlyKept);
    expect(await File(onlyKept.path).exists(), isFalse);
    expect(await files.readCache(onlyKept, 'v1'), isNull);
  });

  Matcher refusedFor(ReplayRemoveRefusal reason) => throwsA(
      isA<ReplayRemoveRefused>().having((e) => e.reason, 'reason', reason));

  test("remove refuses when a folder leads into Valorant's folder", () async {
    final valorantFile = await writeReplay(demos, 'x');

    // Icarus's replays folder is a link (a junction on Windows) to
    // Valorant's folder: its files look kept but are Valorant's.
    final linkedSupport = await Directory(p.join(root.path, 'linked')).create();
    await Link(p.join(linkedSupport.path, 'replays')).create(demos.path);
    final linked = ReplayFiles(
      supportDirectory: () async => linkedSupport,
      valorantDemosPath: demos.path,
    );
    final looksKept = (await linked.list()).single;
    expect(looksKept.source, ReplaySource.icarus);
    await expectLater(
      linked.remove(looksKept),
      refusedFor(ReplayRemoveRefusal.outsideIcarus),
    );
    expect(await valorantFile.exists(), isTrue);

    // The cache folder leads into Valorant's folder.
    final cacheSupport = await Directory(p.join(root.path, 'cache')).create();
    await Link(p.join(cacheSupport.path, 'replay_cache')).create(demos.path);
    final cacheLinked = ReplayFiles(
      supportDirectory: () async => cacheSupport,
      valorantDemosPath: demos.path,
    );
    final kept = await cacheLinked.import((await writeReplay(root, 'y')).path);
    await expectLater(
      cacheLinked.remove(kept),
      refusedFor(ReplayRemoveRefusal.outsideIcarus),
    );
    expect(await File(kept.path).exists(), isTrue);
    expect(await valorantFile.exists(), isTrue);
  });

  test('remove deletes nothing once what the user was told stops being true',
      () async {
    final original = await writeReplay(demos, 'h');
    await files.import(original.path);
    final shown = (await files.list()).single;
    expect(shown.valorantHasCopy, isTrue);

    // Valorant clears its folder while the dialog says it still has a copy.
    await original.delete();
    Object? refused;
    try {
      await files.remove(shown);
    } catch (error) {
      refused = error;
    }
    expect(refused, isA<ReplayRemoveRefused>());
    final again = refused! as ReplayRemoveRefused;
    expect(again.reason, ReplayRemoveRefusal.valorantCopyChanged);
    expect(await File(shown.path).exists(), isTrue);
    expect(again.current!.valorantHasCopy, isFalse);

    // The file itself is replaced while the dialog is open.
    await File(shown.path).writeAsBytes([7, 7, 7, 7, 7, 7]);
    await expectLater(
      files.remove(again.current!),
      refusedFor(ReplayRemoveRefusal.fileChanged),
    );
    expect(await File(shown.path).readAsBytes(), [7, 7, 7, 7, 7, 7]);

    final current = (await files.list()).single;
    await files.remove(current);
    expect(await File(shown.path).exists(), isFalse);
  });

  test('remove deletes only its own cache, not one whose key it starts',
      () async {
    final a = await files.import((await writeReplay(root, 'a')).path);
    final longer =
        await files.import((await writeReplay(root, '${a.cacheKey}-x')).path);
    expect(longer.cacheKey.startsWith('${a.cacheKey}-'), isTrue);
    await files.writeCache(a, 'v1', Uint8List.fromList([1]));
    await files.writeCache(longer, 'v1', Uint8List.fromList([2]));

    await files.remove(a);
    expect(await files.readCache(a, 'v1'), isNull);
    expect(await files.readCache(longer, 'v1'), [2]);
  });

  test(
      'a replay that can\'t go to the Recycle Bin stays, and so does its cache',
      () async {
    final kept = await files.import((await writeReplay(root, 'r')).path);
    await files.writeCache(kept, 'v1', Uint8List.fromList([1]));
    recycle = (path) async => throw RecycleBinUnavailable(path);

    await expectLater(
      files.remove(kept),
      throwsA(isA<RecycleBinUnavailable>()
          .having((e) => e.deleted, 'deleted', isFalse)),
    );
    expect(await File(kept.path).exists(), isTrue);
    expect(await files.readCache(kept, 'v1'), [1]);
  });

  test('a replay Windows deleted instead of recycling is reported as deleted',
      () async {
    final kept = await files.import((await writeReplay(root, 's')).path);
    await files.writeCache(kept, 'v1', Uint8List.fromList([1]));
    recycle = (path) async {
      await File(path).delete();
      throw RecycleBinUnavailable(path);
    };

    await expectLater(
      files.remove(kept),
      throwsA(isA<RecycleBinUnavailable>()
          .having((e) => e.deleted, 'deleted', isTrue)),
    );
    expect(await files.readCache(kept, 'v1'), [1]);
  });

  test('a link in Valorant\'s folder back to the kept file is not a copy',
      () async {
    final kept = await files.import((await writeReplay(root, 'l')).path);
    final link = Link(p.join(demos.path, 'l.vrf'));
    try {
      await link.create(kept.path);
    } on FileSystemException {
      markTestSkipped('This machine may not create file links.');
      return;
    }
    final listed = (await files.list()).single;
    expect(listed.path, kept.path);
    expect(listed.valorantHasCopy, isFalse);

    await files.remove(listed);
    expect(await File(p.join(bin.path, 'l.vrf')).exists(), isTrue);
  });
}
