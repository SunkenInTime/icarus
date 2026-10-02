import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory support;
  late Directory demos;
  late ReplayFiles files;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('icarus-replay-files');
    support = await Directory(p.join(root.path, 'support')).create();
    demos = await Directory(p.join(root.path, 'VALORANT', 'Saved', 'Demos'))
        .create(recursive: true);
    files = ReplayFiles(
      supportDirectory: () async => support,
      valorantDemosPath: demos.path,
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
}
