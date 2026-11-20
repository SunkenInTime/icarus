import 'package:icarus_library/engine_contract.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';

final class MemoryHarness implements EngineHarness {
  MemoryHarness([MemoryStorage? storage])
    : storage = storage ?? MemoryStorage();

  MemoryStorage storage;

  @override
  Future<StorageEngine> open() async => MemoryEngine(storage);

  @override
  Future<void> close(StorageEngine engine) => (engine as MemoryEngine).close();

  @override
  Future<void> crash(StorageEngine engine) => (engine as MemoryEngine).close();

  @override
  PendingWrite holdNextWrite(StorageEngine engine) => storage.holdNextWrite();
}

final class ForgetfulHarness extends MemoryHarness {
  @override
  Future<void> crash(StorageEngine engine) async {
    await super.crash(engine);
    storage = MemoryStorage();
  }
}

final class EveryoneLeases implements StorageEngine {
  EveryoneLeases(this.storage);

  final MemoryStorage storage;

  @override
  Future<Leasing> lease() async =>
      switch (await MemoryEngine(storage).lease()) {
        HeldByAnotherWriter() => await MemoryEngine(MemoryStorage()).lease(),
        final other => other,
      };
}

final class LeakyHarness extends MemoryHarness {
  @override
  Future<StorageEngine> open() async => EveryoneLeases(storage);

  @override
  Future<void> close(StorageEngine engine) async {}

  @override
  Future<void> crash(StorageEngine engine) async {}
}

final class WildcardLease extends ForwardingLease {
  WildcardLease(super.inner);

  bool _matches(String key, String prefix) {
    if (key.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] != '_' && prefix[i] != key[i]) return false;
    }
    return true;
  }

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      switch (await inner.keys(area, '')) {
        Done(:final value) => Done([
          for (final key in value)
            if (_matches(key, prefix)) key,
        ]),
        final failed => failed,
      };
}

final class WildcardHarness extends MemoryHarness {
  @override
  Future<StorageEngine> open() async =>
      WrappingEngine(MemoryEngine(storage), WildcardLease.new);

  @override
  Future<void> close(StorageEngine engine) =>
      ((engine as WrappingEngine).inner as MemoryEngine).close();

  @override
  Future<void> crash(StorageEngine engine) => close(engine);
}

Future<Map<String, CheckResult>> runAll(
  EngineHarness Function() harness,
) async => {
  for (final check in engineContract) check.name: await check.run(harness()),
};

void main() {
  group('The memory engine keeps the engine contract:', () {
    for (final check in engineContract) {
      test(check.name, () async {
        expect(await check.run(MemoryHarness()), isA<Passed>());
      });
    }
  });

  test('the contract fails an engine that loses writes in a crash', () async {
    final results = await runAll(ForgetfulHarness.new);
    expect(
      results['a write or delete that returned Wrote survives a crash, whole'],
      isA<Broke>(),
    );
  });

  test(
    'the contract fails an engine that grants a lease to everyone',
    () async {
      final results = await runAll(LeakyHarness.new);
      expect(
        results['grants one lease at a time on the same storage'],
        isA<Broke>(),
      );
    },
  );

  test(
    'the contract fails an engine whose prefixes match like SQL LIKE',
    () async {
      final results = await runAll(WildcardHarness.new);
      expect(
        results['matches names exactly and lists them in ascending code unit order'],
        isA<Broke>(),
      );
    },
  );

  test(
    'a lease asked for during or after an engine closes is refused or ended',
    () async {
      final engine = MemoryEngine(MemoryStorage());
      final first = switch (await engine.lease()) {
        Leased(:final lease) => lease,
        final other => fail('$other'),
      };
      final closing = engine.close();
      final during = await engine.lease();
      await closing;
      expect(first.status, isA<Ended>());
      switch (during) {
        case Leased(:final lease):
          expect(lease.status, isA<Ended>());
        case LeaseFailed(:final failure):
          expect(failure, isA<EngineClosed>());
        case HeldByAnotherWriter():
          fail('a lease during close was neither refused nor ended');
      }
      expect(
        await engine.lease(),
        isA<LeaseFailed>().having(
          (failed) => failed.failure,
          'failure',
          isA<EngineClosed>(),
        ),
      );
    },
  );
}
