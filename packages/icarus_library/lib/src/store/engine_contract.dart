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

String? _value(KeyRead read, String what) => switch (read) {
  KeyHeld(:final value) => value,
  KeyMissing() => null,
  KeyNotRead(:final failure) => _broke('$what failed: $failure'),
};

Future<String?> _read(StorageLease lease, String area, String key) async =>
    _value(await lease.read(area, key), 'read $area $key');

void _same(Object? actual, Object? expected, String what) {
  if (actual != expected) _broke('$what: expected $expected, got $actual');
}

void _sameList(List<Object?> actual, List<Object?> expected, String what) {
  if (actual.length != expected.length ||
      !Iterable<int>.generate(
        actual.length,
      ).every((i) => actual[i] == expected[i])) {
    _broke('$what: expected $expected, got $actual');
  }
}

void _ended(Object result, String what) {
  switch (result) {
    case StorageFailed(failure: LeaseEnded()) ||
        KeyNotRead(failure: LeaseEnded()):
      return;
    case _:
      _broke('$what through an ended lease gave $result, not LeaseEnded');
  }
}

void _endedStatus(StorageLease lease, String when) {
  if (lease.status is! Ended) _broke('a lease $when still says it holds');
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
      _same(await _read(lease, 'one', key), value, 'read $key');
      _same(await _read(lease, 'two', key), null, 'other area');
    }
    if (await lease.read('one', 'missing') is! KeyMissing) {
      _broke('a key never written did not read as missing');
    }
    await harness.close(engine);
  }),
  _check('lists keys, and keys with values, by prefix in ascending order', (
    harness,
  ) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    final values = {
      'page/b': '2',
      'page/a': '1',
      'page/a/x': '3',
      'pages': '4',
      'other': '5',
    };
    _done(await lease.write('a', values), 'write');
    const under = ['page/a', 'page/a/x', 'page/b'];
    _sameList(_done(await lease.keys('a', 'page/'), 'keys'), under, 'keys');
    _sameList(
      [
        for (final (:key, :value) in _done(
          await lease.entries('a', 'page/'),
          'entries',
        ))
          '$key=$value',
      ],
      [for (final key in under) '$key=${values[key]}'],
      'entries',
    );
    _sameList(_done(await lease.keys('a', ''), 'keys'), [
      'other',
      'page/a',
      'page/a/x',
      'page/b',
      'pages',
    ], 'every key');
    _sameList(_done(await lease.entries('b', ''), 'entries'), [], 'empty');
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
        await _read(reopened, 'a', 'k$i'),
        i == 7 || i == 8 ? null : 'v$i',
        'k$i after a crash',
      );
    }
    await harness.close(after);
  }),
  _check(
    'holds keys up to its maxKeyLength, at least 255, and refuses longer',
    (harness) async {
      final engine = await harness.open();
      final lease = await _lease(engine);
      final limit = lease.maxKeyLength;
      if (limit < 255) _broke('maxKeyLength $limit is under 255');
      final area = 'a' * maxAreaLength;
      final longest = 'k' * limit;
      _done(await lease.write(area, {longest: 'v'}), 'write');
      _same(await _read(lease, area, longest), 'v', 'the longest key');
      switch (await lease.write(area, {'${longest}k': 'v', 'short': 'v'})) {
        case StorageFailed(failure: KeyTooLong()):
          break;
        case final other:
          _broke('a key past maxKeyLength gave $other, not KeyTooLong');
      }
      _same(await _read(lease, area, 'short'), null, 'a refused write landed');
      await harness.close(engine);
    },
  ),
  _check('grants one lease at a time on the same storage', (harness) async {
    final first = await harness.open();
    final second = await harness.open();
    final held = await _lease(first);
    if (held.status is! Holding) _broke('a new lease does not say it holds');
    if (await second.lease() is! HeldByAnotherWriter) {
      _broke('a second engine leased storage that was already leased');
    }
    if (await first.lease() is! HeldByAnotherWriter) {
      _broke('the same engine leased its storage twice');
    }
    final writing = held.write('a', {'x': 'first'});
    if (await second.lease() is! HeldByAnotherWriter) {
      _broke('a second lease was granted while the first was writing');
    }
    _done(await writing, 'write');
    if (await held.release() is! Released) _broke('release did not release');
    _endedStatus(held, 'released');
    final next = await _lease(second);
    _same(await _read(next, 'a', 'x'), 'first', 'the first writer\'s write');
    await harness.close(first);
    await harness.close(second);
  }),
  _check('a write in flight when its lease ends lands whole or not at all', (
    harness,
  ) async {
    final first = await harness.open();
    final second = await harness.open();
    final held = await _lease(first);
    final values = {for (var i = 0; i < 20; i++) 'k$i': 'v$i'};
    final writing = held.write('a', values);
    await held.release();
    final next = await _lease(second);
    final atGrant = [
      for (final key in values.keys) await _read(next, 'a', key),
    ];
    final wrote = await writing;
    final afterWrite = [
      for (final key in values.keys) await _read(next, 'a', key),
    ];
    _sameList(afterWrite, atGrant, 'the old lease wrote after the new grant');
    final expected = switch (wrote) {
      Done() => values.values.toList(),
      StorageFailed() => List<String?>.filled(values.length, null),
    };
    _sameList(atGrant, expected, 'what the in-flight write left');
    await harness.close(first);
    await harness.close(second);
  }),
  _check('a released lease refuses every call', (harness) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    _done(await lease.write('a', {'x': 'kept'}), 'write');
    await lease.release();
    _endedStatus(lease, 'released');
    _ended(await lease.read('a', 'x'), 'read');
    _ended(await lease.keys('a', ''), 'keys');
    _ended(await lease.entries('a', ''), 'entries');
    _ended(await lease.write('a', {'x': 'lost'}), 'write');
    _ended(await lease.delete('a', ['x']), 'delete');
    final next = await _lease(engine);
    _same(await _read(next, 'a', 'x'), 'kept', 'after release');
    await harness.close(engine);
  }),
  _check(
    'a lease ends when its engine closes, and stays ended after another writer',
    (harness) async {
      final first = await harness.open();
      final old = await _lease(first);
      _done(await old.write('a', {'name': 'before'}), 'write');
      await harness.close(first);
      _endedStatus(old, 'whose engine closed');
      _ended(await old.write('a', {'name': 'stale'}), 'write');
      final second = await harness.open();
      final current = await _lease(second);
      _done(await current.write('a', {'name': 'renamed'}), 'write');
      await current.release();
      _ended(await old.write('a', {'name': 'stale'}), 'write');
      _ended(await old.read('a', 'name'), 'read');
      final check = await _lease(second);
      _same(
        await _read(check, 'a', 'name'),
        'renamed',
        'the ended lease wrote nothing',
      );
      await harness.close(second);
    },
  ),
];
