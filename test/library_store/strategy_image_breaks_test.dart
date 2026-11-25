import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_store/canvas_units.dart' show cloneStrategy;
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/library_store/stored_strategy.dart';

import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'gated_engine.dart';
import 'unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _Breaks {
  var armed = false;
  var count = 0;
  int? at;
  Future<void> Function()? then;

  Future<void> breathe() async {
    if (!armed) return;
    count += 1;
    if (count == at) await then!();
  }
}

Future<void> _still() async {}

Future<void> _until(bool Function() done) async {
  for (var turn = 0; turn < 1000 && !done(); turn++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(done(), isTrue);
}

Future<void> _moveAgent(ProviderContainer c, int index) async {
  final agent = c.read(agentProvider)[index];
  c
      .read(agentProvider.notifier)
      .updatePosition(agent.position + const Offset(9, 7), agent.id);
}

Future<void> _save(ProviderContainer c, String id) =>
    c.read(strategyProvider.notifier).forceSaveNow(id);

StrategyData _stored(String id) => const LocalLibrary().storedStrategy(id)!;

Future<StrategyData> _inStore(LibraryStore store, String id) async =>
    switch (await readStoredRows(store, id)) {
      StoredRowsRead(:final rows) => switch (strategyFromRows(rows)) {
          StrategyDataMade(:final strategy) => strategy,
          final other => fail('the store\'s rows make $other'),
        },
      StoredRowsNot(:final stored) => fail('the store holds $stored'),
    };

bool _same(StrategyData a, StrategyData b) => strategyDifferences(a, b).isEmpty;

final _closedWithTheApp = isA<MirrorStopped>()
    .having((phase) => phase.stop, 'stop', isA<MirrorClosedWithTheApp>());

final class _Published {
  _Published(StoreMirror mirror, LibraryStore store, String id) {
    _listening = mirror.updates.listen((wrote) {
      if (!wrote.strategies.contains(id)) return;
      verdicts.add(mirror.strategiesReadingBackDifferently[id]);
      _versions.add(_inStore(store, id));
    });
  }

  late final StreamSubscription<MirrorWrote> _listening;
  final verdicts = <String?>[];
  final _versions = <Future<StrategyData>>[];

  Future<List<StrategyData>> stop() async {
    await _listening.cancel();
    return Future.wait(_versions);
  }
}

StrategyData _generated(String id) => StrategyMigrator.migrateToCurrentVersion(
      generatedStrategy(Optionals.set).copyWith(
        id: id,
        pages: [
          generatedPage(
            id: '$id-p0',
            sortIndex: 0,
            optionals: Optionals.set,
            isAttack: true,
          ),
        ],
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late Directory hiveDirectory;
  setUpAll(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    appProviderContainer = container;
  });
  setUp(() async {
    hiveDirectory = await openUnitHive();
    for (final id in ['folder-1', 'folder-2']) {
      await Hive.box<Folder>(HiveBoxNames.foldersBox).put(
        id,
        Folder(name: id, id: id, dateCreated: DateTime.utc(2026, 1, 1)),
      );
    }
  });
  tearDown(() async => Hive.close());

  var opened = 0;
  Future<(UnitHarness, String, _Breaks)> open({CommitGate? gate}) async {
    opened += 1;
    final id = 'breaks-$opened';
    final breaks = _Breaks();
    final h = await openInEditor(
      container,
      _generated(id),
      betweenSteps: breaks.breathe,
      journaled: false,
      engine: gate == null ? null : (memory) => GatedEngine(memory, gate),
    );
    return (h, id, breaks);
  }

  Future<int> breaksInASave() async {
    final (h, id, breaks) = await open();
    addTearDown(h.dispose);
    breaks.armed = true;
    await _moveAgent(container, 0);
    await _save(container, id);
    await h.settle();
    return breaks.count;
  }

  final writers = <String,
      Future<bool Function(StrategyData)> Function(ProviderContainer, String)>{
    'a save through the app after another edit': (c, id) async {
      final agentId = c.read(agentProvider)[1].id;
      await _moveAgent(c, 1);
      final moved = c.read(agentProvider).singleWhere((a) => a.id == agentId);
      await _save(c, id);
      return (StrategyData strategy) => strategy.pages.single.agentData.any(
          (agent) => agent.id == agentId && agent.position == moved.position);
    },
    'a rename, which changes the Hive record in place': (c, id) async {
      await const LocalLibrary().renameStrategy(_stored(id), 'Renamed');
      return (StrategyData strategy) => strategy.name == 'Renamed';
    },
    'a move to another folder, which changes the Hive record in place':
        (c, id) async {
      await const LocalLibrary().moveStrategy(_stored(id), 'folder-2');
      return (StrategyData strategy) => strategy.folderID == 'folder-2';
    },
  };

  for (final MapEntry(key: name, value: write) in writers.entries) {
    test(
        '$name, landing at any break of the mirror\'s check of a save, lands '
        'in Hive and in the store; every version the mirror publishes is one '
        'Hive held, read back equal, and the store ends equal to Hive',
        () async {
      final total = await breaksInASave();
      expect(total, greaterThan(10));
      for (var at = 1; at <= total; at++) {
        final (h, id, breaks) = await open();
        final published = _Published(h.mirror, h.store, id);
        late StrategyData before;
        late bool Function(StrategyData) landed;
        breaks
          ..armed = true
          ..at = at
          ..then = () async {
            before = strategyAsHiveHoldsIt(cloneStrategy(_stored(id)));
            landed = await write(container, id);
          };
        await _moveAgent(container, 0);
        await _save(container, id);
        await h.settle();
        breaks.armed = false;
        final after = strategyAsHiveHoldsIt(cloneStrategy(_stored(id)));
        final versions = await published.stop();

        expect(landed(before), isFalse, reason: 'break $at');
        expect(landed(after), isTrue, reason: 'break $at: in Hive');
        expect(landed(await _inStore(h.store, id)), isTrue,
            reason: 'break $at: in the store');
        expect(versions, isNotEmpty, reason: 'break $at');
        for (final (index, version) in versions.indexed) {
          expect(_same(before, version) || _same(after, version), isTrue,
              reason: 'break $at, publish $index: '
                  '${strategyDifferences(after, version)}');
        }
        expect(_same(after, versions.last), isTrue, reason: 'break $at');
        expect(published.verdicts, everyElement(isNull), reason: 'break $at');
        final check = await h.mirror.check((hive) => checkStoreAgainstHive(
              hive,
              h.store,
              foreignNames: const [],
              breathe: _still,
              strategiesRefused: h.mirror.refusedStrategies,
              foldersRefused: h.mirror.refusedFolders,
            ));
        expect(check, isA<StoreChecked>(), reason: 'break $at');
        final checked = check as StoreChecked;
        expect(checked.isExact, isTrue,
            reason: 'break $at: ${checked.strategyProblems}');
        expect(h.mirror.strategiesReadingBackDifferently, isEmpty,
            reason: 'break $at');
        await h.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  group('once the app closes', () {
    test(
        'at any break of the mirror\'s check of a save, the mirror stops as '
        'closed with the app, writes nothing more and publishes nothing',
        () async {
      final total = await breaksInASave();
      for (var at = 1; at <= total; at++) {
        final gate = CommitGate();
        final (h, id, breaks) = await open(gate: gate);
        late int commits;
        late int batches;
        final published = <MirrorWrote>[];
        StreamSubscription<MirrorWrote>? listening;
        breaks
          ..armed = true
          ..at = at
          ..then = () async {
            h.mirror.closeWithTheApp();
            commits = gate.commits;
            batches = h.mirror.batches;
            listening = h.mirror.updates.listen(published.add);
          };
        await _moveAgent(container, 0);
        await _save(container, id);
        await h.settle();
        await listening?.cancel();

        expect(h.mirror.phase, _closedWithTheApp, reason: 'break $at');
        expect(gate.commits, commits, reason: 'break $at');
        expect(h.mirror.batches, batches, reason: 'break $at');
        expect(published, isEmpty, reason: 'break $at');
        await h.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test(
        'while a save\'s store write is in flight, its result is not '
        'published, and a store failure after the close does not replace the '
        'reason the mirror stopped', () async {
      final gate = CommitGate();
      final (h, id, _) = await open(gate: gate);
      addTearDown(h.dispose);
      final before = gate.commits;
      gate.hold();
      await _moveAgent(container, 0);
      final saving = _save(container, id);
      await _until(() => gate.commits > before);
      h.mirror.closeWithTheApp();
      final inFlight = gate.commits;
      final published = <MirrorWrote>[];
      final listening = h.mirror.updates.listen(published.add);
      gate
        ..failNext = true
        ..release();
      await saving;
      await h.settle();
      await listening.cancel();

      expect(h.mirror.phase, _closedWithTheApp);
      expect(gate.commits, inFlight);
      expect(published, isEmpty);
      expect(_stored(id).pages.single.agentData.first.position,
          container.read(agentProvider).first.position);
    });

    test('catching up before the app closes stops the mirror', () async {
      final (h, _, _) = await open();
      addTearDown(h.dispose);
      await storeCatchUpBeforeClose();
      expect(h.mirror.phase, _closedWithTheApp);
    });
  });

  group('once the app closes during the first copy', () {
    var copies = 0;
    Future<(StoreMirror, LibraryStore, CommitGate, _Breaks)>
        beforeCopy() async {
      copies += 1;
      final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      await box.clear();
      for (final name in ['a', 'b']) {
        final strategy = _generated('copy-$copies-$name');
        await box.put(strategy.id, strategy);
      }
      final breaks = _Breaks();
      final gate = CommitGate();
      final store = switch (await LibraryStore.open(
        GatedEngine(MemoryEngine(MemoryStorage()), gate),
        canRead: appCanRead,
      )) {
        StoreOpened(:final store) => store,
        StoreNotOpened(:final problem) => fail('$problem'),
      };
      addTearDown(store.close);
      final mirror = StoreMirror(
        reads: HiveReads(),
        betweenAnimations: breaks.breathe,
      );
      return (mirror, store, gate, breaks);
    }

    Future<ShadowCopy> copy(StoreMirror mirror, LibraryStore store) async {
      final writes = LibraryBoxWrites();
      try {
        return await mirror.copyThenFollow(store, writes: writes);
      } finally {
        await writes.stop();
      }
    }

    Future<StoreCheck> check(StoreMirror mirror) =>
        mirror.check((_) => fail('a check ran after the app closed'));

    test(
        'at any break, the copy is cancelled, not faulted, nothing more is '
        'written, and no check starts', () async {
      final (first, firstStore, _, firstBreaks) = await beforeCopy();
      firstBreaks.armed = true;
      expect(await copy(first, firstStore), isA<ShadowCopyFinished>());
      final total = firstBreaks.count;
      expect(total, greaterThan(10));
      for (var at = 1; at <= total; at++) {
        final (mirror, store, gate, breaks) = await beforeCopy();
        late int commits;
        breaks
          ..armed = true
          ..at = at
          ..then = () async {
            mirror.closeWithTheApp();
            commits = gate.commits;
          };
        expect(await copy(mirror, store), isA<ShadowCopyCancelled>(),
            reason: 'break $at');
        expect(mirror.phase, _closedWithTheApp, reason: 'break $at');
        expect(await check(mirror), isA<StoreCheckCancelled>(),
            reason: 'break $at');
        expect(gate.commits, commits, reason: 'break $at');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
        'before it starts, the copy and a check do not start, and a fault '
        'after the close does not replace the reason', () async {
      final (mirror, store, gate, _) = await beforeCopy();
      final commits = gate.commits;
      mirror.closeWithTheApp();
      mirror.onFault(StateError('a fault after the close'), StackTrace.empty);
      expect(await copy(mirror, store), isA<ShadowCopyCancelled>());
      expect(await check(mirror), isA<StoreCheckCancelled>());
      expect(mirror.phase, _closedWithTheApp);
      expect(gate.commits, commits);
    });

    test(
        'while one of its store writes is in flight, the copy is cancelled, '
        'and the write failing does not replace the reason', () async {
      final (mirror, store, gate, _) = await beforeCopy();
      final before = gate.commits;
      gate.hold();
      final copying = copy(mirror, store);
      await _until(() => gate.commits > before);
      mirror.closeWithTheApp();
      final inFlight = gate.commits;
      gate
        ..failNext = true
        ..release();
      expect(await copying, isA<ShadowCopyCancelled>());
      expect(mirror.phase, _closedWithTheApp);
      expect(await check(mirror), isA<StoreCheckCancelled>());
      expect(gate.commits, inFlight);
    });

    test(
        'the startup run ends as closed with the app and never starts its '
        'check', () async {
      final (mirror, store, _, breaks) = await beforeCopy();
      breaks
        ..armed = true
        ..at = 3
        ..then = () async => mirror.closeWithTheApp();
      final states = <ShadowState>[];
      final listening = container.listen(
        shadowProvider,
        (_, next) => states.add(next),
      );
      addTearDown(listening.close);
      final notifier = container.read(shadowProvider.notifier)
        ..begin(
          opening: Future.value(LibraryStoreReady(
            File('${hiveDirectory.path}/library.sqlite'),
            store,
            const StorageCreated(),
            const [],
            store.close,
          )),
          firstFrame: Future.value(),
          hiveDirectory: hiveDirectory.path,
          mode: Mirroring(mirror),
        );
      await notifier.running;

      expect(container.read(shadowProvider), isA<ShadowClosedWithTheApp>());
      expect(states.whereType<ShadowChecking>(), isEmpty);
      expect(mirror.phase, _closedWithTheApp);
    });
  });
}
