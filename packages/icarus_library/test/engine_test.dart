import 'package:icarus_library/engine_contract.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

final class MemoryHarness implements EngineHarness {
  MemoryHarness(this.storage);

  final MemoryStorage Function() storage;
  late final MemoryStorage _storage = storage();

  @override
  Future<StorageEngine> open() async => MemoryEngine(_storage);

  @override
  Future<void> close(StorageEngine engine) => (engine as MemoryEngine).close();

  @override
  Future<void> crash(StorageEngine engine) => (engine as MemoryEngine).close();
}

final class EveryoneLeases implements StorageEngine {
  EveryoneLeases(this.storage);

  final MemoryStorage storage;

  @override
  Future<Leasing> lease() => MemoryEngine(storage).lease().then(
    (leasing) => switch (leasing) {
      HeldByAnotherWriter() => MemoryEngine(MemoryStorage()).lease(),
      _ => Future.value(leasing),
    },
  );
}

final class ForgetfulHarness implements EngineHarness {
  var _storage = MemoryStorage();

  @override
  Future<StorageEngine> open() async => MemoryEngine(_storage);

  @override
  Future<void> close(StorageEngine engine) => (engine as MemoryEngine).close();

  @override
  Future<void> crash(StorageEngine engine) async {
    await (engine as MemoryEngine).close();
    _storage = MemoryStorage();
  }
}

final class LeakyHarness implements EngineHarness {
  final _storage = MemoryStorage();

  @override
  Future<StorageEngine> open() async => EveryoneLeases(_storage);

  @override
  Future<void> close(StorageEngine engine) async {}

  @override
  Future<void> crash(StorageEngine engine) async {}
}

void main() {
  group('The memory engine keeps the engine contract:', () {
    for (final check in engineContract) {
      test(check.name, () async {
        expect(
          await check.run(MemoryHarness(MemoryStorage.new)),
          isA<Passed>(),
        );
      });
    }
  });

  test('the contract fails an engine that loses writes in a crash', () async {
    final results = {
      for (final check in engineContract)
        check.name: await check.run(ForgetfulHarness()),
    };
    expect(
      results['a write or delete that returned survives a crash, whole'],
      isA<Broke>(),
    );
  });

  test('the contract fails an engine that grants a lease to everyone', () async {
    final results = {
      for (final check in engineContract)
        check.name: await check.run(LeakyHarness()),
    };
    expect(
      results['grants one lease at a time on the same storage'],
      isA<Broke>(),
    );
    expect(
      results['a lease ends when its engine closes, and stays ended after another writer'],
      isA<Broke>(),
    );
  });
}
