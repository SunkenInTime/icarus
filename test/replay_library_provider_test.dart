import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/replay/replay_decoder.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory support;
  late Directory demos;
  late ProviderContainer container;

  /// Reads the header these tests write: `{"id": ..., "at": ...}`.
  Future<ReplayProbe> probe(String path) async {
    try {
      final json = jsonDecode(await File(path).readAsString()) as Map;
      return ReplayProbe(
        matchId: json['id'] as String,
        mapPath: '/Game/Maps/Ascent/Ascent',
        build: '++Ares-Core+release-13.00',
        durationMs: 1000,
        supported: true,
        decoderVersion: 'test',
        agentIds: const [],
        recordedAt: DateTime.parse(json['at'] as String),
      );
    } on FormatException {
      throw const ReplayDecodeException('notAReplay', 'Not a replay.');
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('icarus-replay-library');
    support = await Directory(p.join(root.path, 'support')).create();
    demos = await Directory(p.join(root.path, 'VALORANT', 'Saved', 'Demos'))
        .create(recursive: true);
    container = ProviderContainer(overrides: [
      replayFilesProvider.overrideWithValue(ReplayFiles(
        supportDirectory: () async => support,
        valorantDemosPath: demos.path,
      )),
      replayProbeProvider.overrideWithValue(probe),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await root.delete(recursive: true);
  });

  /// A replay of [matchId] played at [playedAt], whose file was last written
  /// at [fileTime].
  Future<File> writeReplay(
    Directory directory,
    String name, {
    required String matchId,
    required String playedAt,
    DateTime? fileTime,
  }) async {
    final file = File(p.join(directory.path, name));
    await file.writeAsString(jsonEncode({'id': matchId, 'at': playedAt}));
    if (fileTime != null) await file.setLastModified(fileTime);
    return file;
  }

  test('lists newest match first, whatever the file times say', () async {
    // Downloaded in the opposite order to when they were played.
    await writeReplay(demos, 'a.vrf',
        matchId: 'a',
        playedAt: '2026-07-08T12:00:00Z',
        fileTime: DateTime(2026, 7, 9));
    await writeReplay(demos, 'b.vrf',
        matchId: 'b',
        playedAt: '2026-06-30T12:00:00Z',
        fileTime: DateTime(2026, 7, 10));
    await writeReplay(demos, 'c.vrf',
        matchId: 'c',
        playedAt: '2026-07-05T12:00:00Z',
        fileTime: DateTime(2026, 7, 11));

    final listings = await container.read(replayLibraryProvider.future);
    expect(listings.map((listing) => listing.matchId), ['a', 'c', 'b']);
  });

  test('add copies new matches only and says what happened to each file',
      () async {
    final valorant = await writeReplay(demos, 'kept.vrf',
        matchId: 'kept', playedAt: '2026-07-01T00:00:00Z');
    final outside = await Directory(p.join(root.path, 'downloads')).create();
    final renamedCopy = await writeReplay(outside, 'my scrim.vrf',
        matchId: 'kept', playedAt: '2026-07-01T00:00:00Z');
    final fresh = await writeReplay(outside, 'new.vrf',
        matchId: 'new', playedAt: '2026-07-02T00:00:00Z');
    final notReplay = File(p.join(outside.path, 'broken.vrf'));
    await notReplay.writeAsString('not a header');
    final notVrf = File(p.join(outside.path, 'notes.txt'));
    await notVrf.writeAsString('{}');
    await container.read(replayLibraryProvider.future);

    final result = await container.read(replayLibraryProvider.notifier).add(
      [renamedCopy.path, fresh.path, notReplay.path, notVrf.path, fresh.path],
    );

    final kept = await (await ReplayFiles(
      supportDirectory: () async => support,
      valorantDemosPath: demos.path,
    ).icarusReplaysDirectory())
        .list()
        .map((entity) => p.basename(entity.path))
        .toList();
    expect(kept, ['new.vrf']);
    expect(result.added, [p.join(support.path, 'replays', 'new.vrf')]);
    expect(result.alreadyListed, [valorant.path]);
    expect(result.unreadable, [notReplay.path, notVrf.path]);
    expect(result.failed, isEmpty);

    final listings = container.read(replayLibraryProvider).requireValue;
    expect(listings.map((listing) => listing.file.path), [
      ...result.added,
      valorant.path,
    ]);
  });
}
