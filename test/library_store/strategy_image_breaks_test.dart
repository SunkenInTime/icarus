import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/local_library.dart';

import '../library_rows/generated_strategies.dart';
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

Future<void> _moveAgent(ProviderContainer c, int index) async {
  final agent = c.read(agentProvider)[index];
  c
      .read(agentProvider.notifier)
      .updatePosition(agent.position + const Offset(9, 7), agent.id);
}

Future<void> _save(ProviderContainer c, String id) =>
    c.read(strategyProvider.notifier).forceSaveNow(id);

StrategyData _stored(String id) => const LocalLibrary().storedStrategy(id)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  setUpAll(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    appProviderContainer = container;
  });
  setUp(() async {
    await openUnitHive();
    for (final id in ['folder-1', 'folder-2']) {
      await Hive.box<Folder>(HiveBoxNames.foldersBox).put(
        id,
        Folder(name: id, id: id, dateCreated: DateTime.utc(2026, 1, 1)),
      );
    }
  });
  tearDown(() async => Hive.close());

  var opened = 0;
  Future<(UnitHarness, String, _Breaks)> open() async {
    opened += 1;
    final id = 'breaks-$opened';
    final breaks = _Breaks();
    final strategy = generatedStrategy(Optionals.set).copyWith(
      id: id,
      pages: [
        generatedPage(
          id: '$id-p0',
          sortIndex: 0,
          optionals: Optionals.set,
          isAttack: true,
        ),
      ],
    );
    final h = await openInEditor(
      container,
      strategy,
      betweenSteps: breaks.breathe,
      journaled: false,
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

  final writers = <String, Future<void> Function(ProviderContainer, String)>{
    'a save through the app after another edit': (c, id) async {
      await _moveAgent(c, 1);
      await _save(c, id);
    },
    'a rename, which changes the Hive record in place': (c, id) async {
      await const LocalLibrary().renameStrategy(_stored(id), 'Renamed');
    },
    'a move to another folder, which changes the Hive record in place':
        (c, id) async {
      await const LocalLibrary().moveStrategy(_stored(id), 'folder-2');
    },
  };

  for (final MapEntry(key: name, value: write) in writers.entries) {
    test(
        '$name, landing at any break of the mirror\'s check of a save, leaves '
        'the store equal to Hive with nothing reading back differently',
        () async {
      final total = await breaksInASave();
      expect(total, greaterThan(10));
      for (var at = 1; at <= total; at++) {
        final (h, id, breaks) = await open();
        breaks
          ..armed = true
          ..at = at
          ..then = () => write(container, id);
        await _moveAgent(container, 0);
        await _save(container, id);
        await h.settle();
        breaks.armed = false;
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

  test(
      'once the app closes, a check that resumes at any break of a save '
      'writes nothing and throws nothing', () async {
    final total = await breaksInASave();
    for (var at = 1; at <= total; at++) {
      final (h, id, breaks) = await open();
      late int batches;
      breaks
        ..armed = true
        ..at = at
        ..then = () async {
          h.mirror.closeWithTheApp();
          batches = h.mirror.batches;
          await h.store.close();
        };
      await _moveAgent(container, 0);
      await _save(container, id);
      await h.settle();
      expect(
        h.mirror.phase,
        isA<MirrorStopped>().having(
            (phase) => phase.stop, 'stop', isA<MirrorClosedWithTheApp>()),
        reason: 'break $at',
      );
      expect(h.mirror.batches, batches, reason: 'break $at');
      await h.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('catching up before the app closes stops the mirror', () async {
    final (h, _, _) = await open();
    addTearDown(h.dispose);
    await storeCatchUpBeforeClose();
    expect(
      h.mirror.phase,
      isA<MirrorStopped>()
          .having((phase) => phase.stop, 'stop', isA<MirrorClosedWithTheApp>()),
    );
  });
}
