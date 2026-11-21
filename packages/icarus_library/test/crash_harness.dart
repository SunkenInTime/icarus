import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

abstract interface class CrashHarness {
  String get name;

  Future<void> start(Contents seed);

  Future<StorageEngine> open();

  void arm(int step);

  void disarm();

  int get stepsSinceArmed;

  bool get crashed;

  Future<void> crash();

  Future<void> finish();
}

final class MemoryCrashHarness implements CrashHarness {
  late MemoryStorage _storage;
  final _leases = <StorageLease>[];
  int _steps = 0;
  int? _crashAt;
  int _armedFrom = 0;
  bool _crashed = false;

  @override
  String get name => 'memory, stopping before any engine call';

  @override
  Future<void> start(Contents seed) async {
    await crash();
    _storage = MemoryStorage(seed);
  }

  @override
  Future<StorageEngine> open() async =>
      WrappingEngine(MemoryEngine(_storage), (lease) {
        _leases.add(lease);
        return _SteppedLease(this, lease);
      });

  bool _step() {
    if (_crashed) return false;
    _steps++;
    if (_crashAt case final at? when _steps >= at) {
      _crashed = true;
      return false;
    }
    return true;
  }

  @override
  void arm(int step) {
    _armedFrom = _steps;
    _crashAt = _steps + step;
  }

  @override
  void disarm() {
    _armedFrom = _steps;
    _crashAt = null;
  }

  @override
  int get stepsSinceArmed => _steps - _armedFrom;

  @override
  bool get crashed => _crashed;

  @override
  Future<void> crash() async {
    _crashed = true;
    for (final lease in _leases) {
      await lease.release();
    }
    _leases.clear();
    _crashed = false;
    _crashAt = null;
  }

  @override
  Future<void> finish() => crash();
}

final class _SteppedLease extends ForwardingLease {
  _SteppedLease(this._harness, super.inner);

  final MemoryCrashHarness _harness;

  static const _stopped = StorageFailed<Never>(
    DeviceFailure('the app stopped'),
  );

  @override
  Future<KeyRead> read(String area, String key) async => _harness._crashed
      ? const KeyNotRead(DeviceFailure('the app stopped'))
      : await inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      _harness._crashed ? _stopped : await inner.keys(area, prefix);

  @override
  Future<Committing> commit(List<Change> changes) async => _harness._step()
      ? await inner.commit(changes)
      : const CommitRefused(DeviceFailure('the app stopped'));
}

Future<Committing> put(
  StorageLease lease,
  String area,
  Map<String, String> values,
) => lease.commit([
  for (final MapEntry(:key, :value) in values.entries) Put(area, key, value),
]);

Future<Committing> remove(
  StorageLease lease,
  String area,
  Iterable<String> keys,
) => lease.commit([for (final key in keys) Delete(area, key)]);

void committed(Committing committing) => switch (committing) {
  CommitApplied() => null,
  CommitRefused(:final failure) => fail('the commit was refused: $failure'),
  CommitUnknown(:final failure) => fail('the commit is unknown: $failure'),
};

Future<StorageLease> leaseOf(StorageEngine engine) async =>
    switch (await engine.lease()) {
      Leased(:final lease) => lease,
      final other => fail('no lease: $other'),
    };

String? valueOf(KeyRead read) => switch (read) {
  KeyHeld(:final value) => value,
  KeyMissing() => null,
  KeyNotRead(:final failure) => fail('reading failed: $failure'),
};

T stored<T>(Stored<T> result) => switch (result) {
  Done(:final value) => value,
  StorageFailed(:final failure) => fail('storage failed: $failure'),
};

Future<Contents> contentsOf(StorageLease engine, Iterable<String> areas) async {
  final contents = <String, Map<String, String>>{};
  for (final area in areas) {
    final values = <String, String>{};
    for (final key in stored(await engine.keys(area, ''))) {
      values[key] = valueOf(await engine.read(area, key))!;
    }
    if (values.isNotEmpty) contents[area] = values;
  }
  return contents;
}

void storeCrashContract(CrashHarness Function() makeHarness) =>
    group('the store', () => _storeCrashContract(makeHarness));

void _storeCrashContract(CrashHarness Function() makeHarness) {
  late Contents seeded;
  late CrashHarness harness;

  setUpAll(() async {
    seeded = await seededContents();
  });

  setUp(() {
    harness = makeHarness();
  });

  tearDown(() => harness.finish());

  for (final MapEntry(key: name, value: op) in everyOpType().entries) {
    test('$name: a crash at any step leaves the rows before or after, an '
        'acknowledged edit is never lost, and reopening can itself be cut '
        'short', () async {
      final clean = MemoryStorage(seeded);
      final cleanStore = await openStore(MemoryEngine(clean));
      savedValue(await cleanStore.commit(strategyId, op));
      await cleanStore.close();
      final areas = {...seeded.keys, ...clean.contents.keys};
      final before = withoutSlot(seeded);
      final after = withoutSlot(clean.contents);

      await harness.start(seeded);
      final counting = await openStore(await harness.open());
      harness.disarm();
      savedValue(await counting.commit(strategyId, op));
      final steps = harness.stepsSinceArmed;
      expect(steps, greaterThan(0));
      final random = Random(steps);

      for (var step = 1; step <= steps; step++) {
        await harness.start(seeded);
        final store = await openStore(await harness.open());
        harness.arm(step);
        final result = await store.commit(strategyId, op);
        expect(harness.crashed, isTrue, reason: 'no crash at step $step');
        await harness.crash();

        var interruptions = 0;
        while (true) {
          if (interruptions < 20) {
            harness.arm(1 + random.nextInt(steps));
          } else {
            harness.disarm();
          }
          final engine = await harness.open();
          final opening = await LibraryStore.open(
            engine,
            canRead: readsKnownKinds,
            clock: fixedClock,
          );
          if (!harness.crashed) {
            if (opening case StoreOpened(:final store)) await store.close();
            break;
          }
          interruptions++;
          await harness.crash();
        }
        harness.disarm();
        final engine = await harness.open();
        await (await openStore(engine)).close();
        final lease = await leaseOf(engine);
        final rows = withoutSlot(await contentsOf(lease, areas));
        await lease.release();
        final isBefore = sameContents(rows, before);
        final isAfter = sameContents(rows, after);
        final where =
            'crash at step $step of $steps, then $interruptions '
            'interrupted reopenings';
        expect(isBefore || isAfter, isTrue, reason: 'neither, $where');
        switch (result) {
          case Saved():
            expect(isAfter, isTrue, reason: 'saved, then lost: $where');
          case NotSaved():
            expect(isBefore, isTrue, reason: 'not saved, yet kept: $where');
          case SaveInDoubt():
            break;
          case NothingToSave() || Refused():
            fail('unexpected ${describeSaving(result)}');
        }
        await harness.crash();
      }
    });
  }
}

void engineCrashContract(CrashHarness Function() makeHarness) =>
    group('the engine', () => _engineCrashContract(makeHarness));

void _engineCrashContract(CrashHarness Function() makeHarness) {
  late CrashHarness harness;

  setUp(() {
    harness = makeHarness();
  });

  tearDown(() => harness.finish());

  test('after a crash at any step of random commits across areas, with '
      'puts, deletes and area clears, every applied commit is there, a '
      'refused one left nothing, an unknown one is wholly there or wholly '
      'absent, and no other row changed', () async {
    const areas = ['library', 'strategy/a', 'strategy/b'];
    for (var seed = 0; seed < 40; seed++) {
      final random = Random(seed);
      final model = <String, Map<String, String>>{
        for (final area in areas)
          area: {for (var i = 0; i < 8; i++) 'k$i': 'seed-$area-$i'},
      };
      await harness.start(model);
      final engine = await leaseOf(await harness.open());
      harness.arm(1 + random.nextInt(60));
      Map<String, Map<String, String>>? inFlight;
      for (var write = 0; !harness.crashed && write < 40; write++) {
        final next = {
          for (final MapEntry(:key, :value) in model.entries) key: {...value},
        };
        final changes = <Change>[];
        for (final area in {
          for (var i = 0; i < 1 + random.nextInt(3); i++)
            areas[random.nextInt(areas.length)],
        }) {
          switch (random.nextInt(5)) {
            case 0:
              changes.add(ClearArea(area));
              next[area]!.clear();
            case 1:
              for (var i = 0; i < 1 + random.nextInt(6); i++) {
                final key = 'k${random.nextInt(16)}';
                changes.add(Delete(area, key));
                next[area]!.remove(key);
              }
            case _:
              for (var i = 0; i < 1 + random.nextInt(10); i++) {
                final key = 'k${random.nextInt(16)}';
                final value = 'w$write-$key-${'x' * random.nextInt(3000)}';
                changes.add(Put(area, key, value));
                next[area]![key] = value;
              }
          }
        }
        switch (await engine.commit(changes)) {
          case CommitApplied():
            model
              ..clear()
              ..addAll(next);
          case CommitRefused():
            break;
          case CommitUnknown():
            inFlight = next;
        }
      }
      await harness.crash();
      harness.disarm();
      final reopened = await leaseOf(await harness.open());
      final rows = await contentsOf(reopened, areas);
      await reopened.release();
      final acknowledged = sameContents(rows, _nonEmpty(model));
      final landed =
          inFlight != null && sameContents(rows, _nonEmpty(inFlight));
      expect(
        acknowledged || landed,
        isTrue,
        reason:
            'seed $seed: the rows are neither the acknowledged ones nor '
            'those with the write in flight',
      );
    }
  });
}

Contents _nonEmpty(Contents contents) => {
  for (final MapEntry(:key, :value) in contents.entries)
    if (value.isNotEmpty) key: value,
};
