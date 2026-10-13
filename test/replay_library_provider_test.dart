import 'dart:async';
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

  /// Holds the first read of a file named `slow.vrf` until completed.
  late Completer<void> slowGate;
  var slowReads = 0;

  /// Holds every read of [heldPath] until completed.
  String? heldPath;
  late Completer<void> held;

  /// Reads the header these tests write: `{"id": ..., "at": ...}`.
  Future<ReplayProbe> probe(String path) async {
    if (p.basename(path) == 'slow.vrf' && slowReads++ == 0) {
      await slowGate.future;
    }
    if (path == heldPath) await held.future;
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
    slowGate = Completer()..complete();
    slowReads = 0;
    heldPath = null;
    root = await Directory.systemTemp.createTemp('icarus-replay-library');
    support = await Directory(p.join(root.path, 'support')).create();
    demos = await Directory(p.join(root.path, 'VALORANT', 'Saved', 'Demos'))
        .create(recursive: true);
    container = ProviderContainer(overrides: [
      replayFilesProvider.overrideWithValue(ReplayFiles(
        supportDirectory: () async => support,
        valorantDemosPath: demos.path,
        recycle: (path) => File(path).delete(),
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
    expect(
      await File(result.added.single).readAsString(),
      await fresh.readAsString(),
    );
    expect(result.alreadyListed, [valorant.path]);
    expect(result.unreadable, [notReplay.path, notVrf.path]);
    expect(result.failed, isEmpty);

    final listings = container.read(replayLibraryProvider).requireValue;
    expect(listings.map((listing) => listing.file.path), [
      ...result.added,
      valorant.path,
    ]);
  });

  test('add names copies after their match, so same-named files both stay',
      () async {
    final first = await Directory(p.join(root.path, 'first')).create();
    final second = await Directory(p.join(root.path, 'second')).create();
    final a = await writeReplay(first, 'scrim.vrf',
        matchId: 'match-a', playedAt: '2026-07-01T00:00:00Z');
    final b = await writeReplay(second, 'scrim.vrf',
        matchId: 'match-b', playedAt: '2026-07-02T00:00:00Z');
    final library = container.read(replayLibraryProvider.notifier);
    await container.read(replayLibraryProvider.future);

    // Started together: the second waits for the first, then finds its
    // match already there.
    final copyOfA = File(p.join(second.path, 'a again.vrf'));
    await a.copy(copyOfA.path);
    final results = await Future.wait([
      library.add([a.path]),
      library.add([copyOfA.path, b.path]),
    ]);

    final replays = p.join(support.path, 'replays');
    expect(results[0].added, [p.join(replays, 'match-a.vrf')]);
    expect(results[1].alreadyListed, [p.join(replays, 'match-a.vrf')]);
    expect(results[1].added, [p.join(replays, 'match-b.vrf')]);
    expect(await File(p.join(replays, 'match-a.vrf')).readAsString(),
        await a.readAsString());
    expect(await File(p.join(replays, 'match-b.vrf')).readAsString(),
        await b.readAsString());
  });

  test('a readable replay replaces an unreadable file of its match', () async {
    final replays = await Directory(p.join(support.path, 'replays')).create();
    final outside = await Directory(p.join(root.path, 'downloads')).create();
    final good = await writeReplay(outside, 'match-a.vrf',
        matchId: 'match-a', playedAt: '2026-07-01T00:00:00Z');
    // Damaged, and the same size, so size alone can't tell them apart.
    await File(p.join(replays.path, 'match-a.vrf'))
        .writeAsString('x' * await good.length());

    final result =
        await container.read(replayLibraryProvider.notifier).add([good.path]);

    expect(result.added, [p.join(replays.path, 'match-a.vrf')]);
    expect(await File(result.added.single).readAsString(),
        await good.readAsString());
  });

  test('a slow first listing never hides a replay added meanwhile', () async {
    slowGate = Completer();
    await writeReplay(demos, 'slow.vrf',
        matchId: 'slow', playedAt: '2026-07-01T00:00:00Z');
    final outside = await Directory(p.join(root.path, 'downloads')).create();
    final fresh = await writeReplay(outside, 'fresh.vrf',
        matchId: 'fresh', playedAt: '2026-07-02T00:00:00Z');

    // The tab opens and its first listing stalls on a header read.
    container.listen(replayLibraryProvider, (_, __) {});
    while (slowReads == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final result =
        await container.read(replayLibraryProvider.notifier).add([fresh.path]);
    slowGate.complete();
    await container.read(replayLibraryProvider.future);
    await pumpEventQueue();

    final listings = container.read(replayLibraryProvider).requireValue;
    expect(listings.map((listing) => listing.file.path),
        contains(result.added.single));
  });

  test('remove waits for an add in progress and spares the file it wrote',
      () async {
    final replays = await Directory(p.join(support.path, 'replays')).create();
    final damaged = File(p.join(replays.path, 'match-a.vrf'));
    await damaged.writeAsString('partial');
    final shown = (await container.read(replayLibraryProvider.future)).single;
    expect(shown.probe, isNull);

    // A good copy is being added while the Remove dialog for the damaged
    // one is open.
    final outside = await Directory(p.join(root.path, 'downloads')).create();
    final good = await writeReplay(outside, 'good.vrf',
        matchId: 'match-a', playedAt: '2026-07-01T00:00:00Z');
    heldPath = good.path;
    held = Completer();
    final library = container.read(replayLibraryProvider.notifier);
    final adding = library.add([good.path]);
    await pumpEventQueue();
    var removed = false;
    final removing = library.remove(shown.file).whenComplete(() {
      removed = true;
    });
    removing.ignore();
    await pumpEventQueue();
    expect(removed, isFalse);
    expect(await damaged.readAsString(), 'partial');

    held.complete();
    expect((await adding).added, [damaged.path]);
    await expectLater(
      removing,
      throwsA(isA<ReplayRemoveRefused>()
          .having((e) => e.reason, 'reason', ReplayRemoveRefusal.fileChanged)),
    );
    expect(await damaged.readAsString(), await good.readAsString());
  });
}
