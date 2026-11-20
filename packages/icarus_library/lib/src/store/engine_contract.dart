import 'engine.dart';

abstract interface class PendingWrite {
  Future<void> get reached;

  void letGo();
}

abstract interface class EngineHarness {
  Future<StorageEngine> open();

  Future<void> close(StorageEngine engine);

  Future<void> crash(StorageEngine engine);

  PendingWrite holdNextWrite(StorageEngine engine);
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

void _applied(Committing committing, String what) {
  if (committing is! CommitApplied) {
    _broke('$what gave $committing, not CommitApplied');
  }
}

Future<Committing> _put(
  StorageLease lease,
  String area,
  Map<String, String> values,
) => lease.commit([
  for (final MapEntry(:key, :value) in values.entries) Put(area, key, value),
]);

Future<Committing> _delete(
  StorageLease lease,
  String area,
  List<String> keys,
) => lease.commit([for (final key in keys) Delete(area, key)]);

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
        KeyNotRead(failure: LeaseEnded()) ||
        CommitRefused(failure: LeaseEnded()):
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

int _compareUnits(String a, String b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final order = a.codeUnitAt(i) - b.codeUnitAt(i);
    if (order != 0) return order;
  }
  return a.length - b.length;
}

final List<EngineCheck> engineContract = [
  _check('a commit across areas is seen whole or not at all after a reopen', (
    harness,
  ) async {
    final first = await harness.open();
    final lease = await _lease(first);
    _applied(await _put(lease, 'c', {'old': '1'}), 'seed');
    _applied(await _put(lease, 'd', {'x': '1', 'y': '2'}), 'seed');
    _applied(
      await lease.commit(const [
        Put('a', 'one', '1'),
        Put('b', 'two', '2'),
        Delete('c', 'old'),
        ClearArea('d'),
      ]),
      'a commit across four areas',
    );
    switch (await lease.commit([
      const Put('a', 'three', '3'),
      const Delete('b', 'two'),
      Put('c', 'k' * (lease.maxKeyLength + 1), 'too long'),
    ])) {
      case CommitRefused():
        break;
      case final other:
        _broke('a commit holding a name past the limit gave $other');
    }
    await harness.crash(first);
    final reopened = await _lease(await harness.open());
    _same(await _read(reopened, 'a', 'one'), '1', 'area a');
    _same(await _read(reopened, 'b', 'two'), '2', 'area b');
    _same(await _read(reopened, 'c', 'old'), null, 'area c');
    _sameList(_done(await reopened.keys('d', ''), 'keys'), [], 'area d');
    _same(await _read(reopened, 'a', 'three'), null, 'a refused commit');
  }),
  _check('clearing an area deletes every name in it and nothing else', (
    harness,
  ) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    _applied(
      await _put(lease, 'area-1', {'a': '1', 'b/c': '2', 'z': '3'}),
      'seed',
    );
    _applied(await _put(lease, 'area-10', {'a': '1'}), 'seed');
    _applied(await _put(lease, 'area-2', {'a': '1'}), 'seed');
    _applied(await lease.commit(const [ClearArea('area-1')]), 'clear');
    _sameList(_done(await lease.keys('area-1', ''), 'keys'), [], 'cleared');
    _same(await _read(lease, 'area-10', 'a'), '1', 'a similar area');
    _same(await _read(lease, 'area-2', 'a'), '1', 'another area');
    await harness.close(engine);
  }),
  _check('reads back each value exactly, and only in its own area', (
    harness,
  ) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    _applied(await _put(lease, 'one', _values), 'write');
    for (final MapEntry(:key, :value) in _values.entries) {
      _same(await _read(lease, 'one', key), value, 'read $key');
      _same(await _read(lease, 'two', key), null, 'other area');
    }
    if (await lease.read('one', 'missing') is! KeyMissing) {
      _broke('a name never written did not read as missing');
    }
    await harness.close(engine);
  }),
  _check('matches names exactly and lists them in ascending code unit order', (
    harness,
  ) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    final names = [
      for (final unit in nameAlphabet.codeUnits)
        'n${String.fromCharCode(unit)}x',
      'n_',
      'n%',
      'nx_y',
      'nxay',
    ].where(isName).toList();
    _applied(
      await _put(lease, 'a', {for (final name in names) name: name}),
      'write',
    );
    final sorted = [...names]..sort(_compareUnits);
    _sameList(_done(await lease.keys('a', ''), 'keys'), sorted, 'order');
    _sameList(_done(await lease.keys('a', 'n_'), 'keys'), [
      for (final name in sorted)
        if (name.startsWith('n_')) name,
    ], 'a prefix holding _');
    _sameList(_done(await lease.keys('a', 'nx_'), 'keys'), [
      'nx_y',
    ], 'a prefix holding _ within a name');
    _sameList(_done(await lease.keys('a', 'n-'), 'keys'), [
      'n-x',
    ], 'a prefix holding -');
    for (final name in names) {
      _same(await _read(lease, 'a', name), name, 'read $name');
    }
    _same(await _read(lease, 'a', 'n_x_'), null, 'a near name');
    await harness.close(engine);
  }),
  _check('lists keys with values by prefix', (harness) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    final values = {
      'page/b': '2',
      'page/a': '1',
      'page/a/x': '3',
      'pages': '4',
      'other': '5',
    };
    _applied(await _put(lease, 'a', values), 'write');
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
    _sameList(_done(await lease.entries('b', ''), 'entries'), [], 'empty');
    await harness.close(engine);
  }),
  _check('a delete removes only the names it gives', (harness) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    _applied(await _put(lease, 'a', {'x': '1', 'y': '2', 'z': '3'}), 'write');
    _applied(await _delete(lease, 'a', ['x', 'z', 'never']), 'delete');
    _sameList(_done(await lease.keys('a', ''), 'keys'), ['y'], 'kept');
    await harness.close(engine);
  }),
  _check('a commit that applied survives a crash, whole', (harness) async {
    final before = await harness.open();
    final lease = await _lease(before);
    _applied(
      await _put(lease, 'a', {for (var i = 0; i < 50; i++) 'k$i': 'v$i'}),
      'write',
    );
    _applied(await _delete(lease, 'a', ['k7', 'k8']), 'delete');
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
    'holds names up to a limit of at least 255 that never changes, and handles longer ones as stated',
    (harness) async {
      final engine = await harness.open();
      final lease = await _lease(engine);
      final limit = lease.maxKeyLength;
      if (limit < 255) _broke('maxKeyLength $limit is under 255');
      final area = 'a' * maxAreaLength;
      final longest = 'k' * limit;
      _applied(await _put(lease, area, {longest: 'v'}), 'write');
      _same(await _read(lease, area, longest), 'v', 'the longest name');
      switch (await _put(lease, area, {'${longest}k': 'v', 'short': 'v'})) {
        case CommitRefused(failure: KeyTooLong()):
          break;
        case final other:
          _broke('a name past the limit gave $other, not CommitRefused');
      }
      _same(await _read(lease, area, 'short'), null, 'a refused write landed');
      if (await lease.read(area, '${longest}k') is! KeyMissing) {
        _broke('reading a name past the limit was not KeyMissing');
      }
      _applied(
        await _delete(lease, area, ['${longest}k']),
        'a delete past the limit',
      );
      await lease.release();
      await harness.close(engine);
      final again = await _lease(await harness.open());
      _same(again.maxKeyLength, limit, 'the limit on the same storage');
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
    final pending = harness.holdNextWrite(first);
    final writing = _put(held, 'a', {'x': 'first'});
    await pending.reached;
    if (await second.lease() is! HeldByAnotherWriter) {
      _broke('a second lease was granted while the first was writing');
    }
    pending.letGo();
    _applied(await writing, 'write');
    if (await held.release() is! Released) _broke('release did not release');
    _endedStatus(held, 'released');
    final next = await _lease(second);
    _same(await _read(next, 'a', 'x'), 'first', 'the first writer\'s write');
    await harness.close(first);
    await harness.close(second);
  }),
  _check(
    'a write pending when its lease ends lands before the next grant or not at all',
    (harness) async {
      final first = await harness.open();
      final second = await harness.open();
      final held = await _lease(first);
      final values = {for (var i = 0; i < 20; i++) 'k$i': 'v$i'};
      final pending = harness.holdNextWrite(first);
      final writing = _put(held, 'a', values);
      await pending.reached;
      final releasing = held.release();
      final leasing = second.lease();
      pending.letGo();
      await releasing;
      final next = switch (await leasing) {
        Leased(:final lease) => lease,
        HeldByAnotherWriter() => await _lease(second),
        LeaseFailed(:final failure) => _broke('leasing failed: $failure'),
      };
      final atGrant = [
        for (final key in values.keys) await _read(next, 'a', key),
      ];
      final wrote = await writing;
      final afterWrite = [
        for (final key in values.keys) await _read(next, 'a', key),
      ];
      _sameList(afterWrite, atGrant, 'the old lease wrote after the new grant');
      switch (wrote) {
        case CommitApplied():
          _sameList(atGrant, values.values.toList(), 'a commit that applied');
        case CommitRefused():
          _sameList(
            atGrant,
            List<String?>.filled(values.length, null),
            'a commit that was refused',
          );
        case CommitUnknown():
          break;
      }
      await harness.close(first);
      await harness.close(second);
    },
  ),
  _check('a released lease refuses every call and changes nothing', (
    harness,
  ) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    _applied(await _put(lease, 'a', {'x': 'kept'}), 'write');
    await lease.release();
    _endedStatus(lease, 'released');
    _ended(await lease.read('a', 'x'), 'read');
    _ended(await lease.keys('a', ''), 'keys');
    _ended(await lease.entries('a', ''), 'entries');
    _ended(await _put(lease, 'a', {'x': 'lost'}), 'write');
    _ended(
      await _put(lease, 'a', {'k' * 4096: 'lost'}),
      'write of a long name',
    );
    _ended(await _delete(lease, 'a', ['x']), 'delete');
    final next = await _lease(engine);
    _same(await _read(next, 'a', 'x'), 'kept', 'after release');
    await harness.close(engine);
  }),
  _check(
    'a lease ends when its engine closes, stays ended, and a closed engine grants none',
    (harness) async {
      final first = await harness.open();
      final old = await _lease(first);
      _applied(await _put(old, 'a', {'name': 'before'}), 'write');
      await harness.close(first);
      _endedStatus(old, 'whose engine closed');
      _ended(await _put(old, 'a', {'name': 'stale'}), 'write');
      if (await first.lease() is! LeaseFailed) {
        _broke('a closed engine granted a lease');
      }
      final second = await harness.open();
      final current = await _lease(second);
      _applied(await _put(current, 'a', {'name': 'renamed'}), 'write');
      await current.release();
      _ended(await _put(old, 'a', {'name': 'stale'}), 'write');
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
