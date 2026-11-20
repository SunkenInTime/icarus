import 'engine.dart';

abstract interface class EngineHarness {
  Future<StorageEngine> open();

  Future<void> close(StorageEngine engine);

  Future<void> crash(StorageEngine engine);
}

sealed class CheckResult {
  const CheckResult();
}

final class Passed extends CheckResult {
  const Passed();
}

final class Broke extends CheckResult {
  const Broke(this.what);

  final String what;

  @override
  String toString() => 'Broke($what)';
}

final class EngineCheck {
  const EngineCheck(this.name, this.run);

  final String name;
  final Future<CheckResult> Function(EngineHarness harness) run;
}

final class _Broken implements Exception {
  const _Broken(this.what);

  final String what;
}

Never _broke(String what) => throw _Broken(what);

Future<StorageLease> _lease(StorageEngine engine) async =>
    switch (await engine.lease()) {
      Leased(:final lease) => lease,
      HeldByAnotherWriter() => _broke('a free storage refused a lease'),
      LeaseFailed(:final failure) => _broke('leasing failed: $failure'),
    };

T _done<T>(Stored<T> stored, String what) => switch (stored) {
  Done(:final value) => value,
  StorageFailed(:final failure) => _broke('$what failed: $failure'),
};

void _same(Object? actual, Object? expected, String what) {
  if (actual != expected) _broke('$what: expected $expected, got $actual');
}

void _sameList(List<String> actual, List<String> expected, String what) {
  if (actual.length != expected.length ||
      !Iterable<int>.generate(
        actual.length,
      ).every((i) => actual[i] == expected[i])) {
    _broke('$what: expected $expected, got $actual');
  }
}

void _ended<T>(Stored<T> stored, String what) {
  if (stored case StorageFailed(failure: LeaseEnded())) return;
  _broke('$what through an ended lease gave $stored, not LeaseEnded');
}

EngineCheck _check(
  String name,
  Future<void> Function(EngineHarness harness) body,
) => EngineCheck(name, (harness) async {
  try {
    await body(harness);
    return const Passed();
  } on _Broken catch (broken) {
    return Broke(broken.what);
  }
});

const _values = {
  'plain': 'a value',
  'empty': '',
  'unicode': 'Säge 🎯 「Bind」',
  'quotes': '{"a":"\\"b\\"","c":[1,2.5,null]}',
};

final List<EngineCheck> engineContract = [
  _check('reads back each value exactly, and only in its own area', (
    harness,
  ) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    _done(await lease.write('one', _values), 'write');
    for (final MapEntry(:key, :value) in _values.entries) {
      _same(_done(await lease.read('one', key), 'read'), value, 'read $key');
      _same(_done(await lease.read('two', key), 'read'), null, 'other area');
    }
    _same(_done(await lease.read('one', 'missing'), 'read'), null, 'missing');
    await harness.close(engine);
  }),
  _check('lists keys by prefix in ascending order', (harness) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    _done(
      await lease.write('a', {
        'page/b': '2',
        'page/a': '1',
        'page/a/x': '3',
        'pages': '4',
        'other': '5',
      }),
      'write',
    );
    _sameList(_done(await lease.keys('a', 'page/'), 'keys'), [
      'page/a',
      'page/a/x',
      'page/b',
    ], 'keys under page/');
    _sameList(_done(await lease.keys('a', ''), 'keys'), [
      'other',
      'page/a',
      'page/a/x',
      'page/b',
      'pages',
    ], 'every key');
    _sameList(_done(await lease.keys('b', ''), 'keys'), [], 'empty area');
    await harness.close(engine);
  }),
  _check('a delete removes only the keys it names', (harness) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    _done(await lease.write('a', {'x': '1', 'y': '2', 'z': '3'}), 'write');
    _done(await lease.delete('a', ['x', 'z', 'never']), 'delete');
    _sameList(_done(await lease.keys('a', ''), 'keys'), ['y'], 'kept');
    await harness.close(engine);
  }),
  _check('a write or delete that returned survives a crash, whole', (
    harness,
  ) async {
    final before = await harness.open();
    final lease = await _lease(before);
    _done(
      await lease.write('a', {for (var i = 0; i < 50; i++) 'k$i': 'v$i'}),
      'write',
    );
    _done(await lease.delete('a', ['k7', 'k8']), 'delete');
    await harness.crash(before);
    final after = await harness.open();
    final reopened = await _lease(after);
    for (var i = 0; i < 50; i++) {
      _same(
        _done(await reopened.read('a', 'k$i'), 'read'),
        i == 7 || i == 8 ? null : 'v$i',
        'k$i after a crash',
      );
    }
    await harness.close(after);
  }),
  _check('holds a key as long as its maxKeyLength, at least 255', (
    harness,
  ) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    if (lease.maxKeyLength < 255) {
      _broke('maxKeyLength ${lease.maxKeyLength} is under 255');
    }
    final key = 'k' * (lease.maxKeyLength < 4096 ? lease.maxKeyLength : 4096);
    _done(await lease.write('a', {key: 'v'}), 'write');
    _same(_done(await lease.read('a', key), 'read'), 'v', 'long key');
    await harness.close(engine);
  }),
  _check('grants one lease at a time on the same storage', (harness) async {
    final first = await harness.open();
    final second = await harness.open();
    final held = await _lease(first);
    if (await second.lease() is! HeldByAnotherWriter) {
      _broke('a second engine leased storage that was already leased');
    }
    if (await first.lease() is! HeldByAnotherWriter) {
      _broke('the same engine leased its storage twice');
    }
    await held.release();
    final next = await _lease(second);
    _done(await next.write('a', {'x': 'second'}), 'write');
    await harness.close(first);
    await harness.close(second);
  }),
  _check('a released lease refuses every call', (harness) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    _done(await lease.write('a', {'x': 'kept'}), 'write');
    await lease.release();
    _ended(await lease.read('a', 'x'), 'read');
    _ended(await lease.keys('a', ''), 'keys');
    _ended(await lease.write('a', {'x': 'lost'}), 'write');
    _ended(await lease.delete('a', ['x']), 'delete');
    final next = await _lease(engine);
    _same(_done(await next.read('a', 'x'), 'read'), 'kept', 'after release');
    await harness.close(engine);
  }),
  _check(
    'a lease ends when its engine closes, and stays ended after another writer',
    (harness) async {
      final first = await harness.open();
      final old = await _lease(first);
      _done(await old.write('a', {'name': 'before'}), 'write');
      await harness.close(first);
      _ended(await old.write('a', {'name': 'stale'}), 'write');
      final second = await harness.open();
      final current = await _lease(second);
      _done(await current.write('a', {'name': 'renamed'}), 'write');
      await current.release();
      _ended(await old.write('a', {'name': 'stale'}), 'write');
      _ended(await old.read('a', 'name'), 'read');
      final check = await _lease(second);
      _same(
        _done(await check.read('a', 'name'), 'read'),
        'renamed',
        'the ended lease wrote nothing',
      );
      await harness.close(second);
    },
  ),
];
