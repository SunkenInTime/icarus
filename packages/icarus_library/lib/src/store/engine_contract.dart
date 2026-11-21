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

typedef _Areas = Map<String, Map<String, String>>;

Set<String> _areasOf(List<Change> changes) => {
  for (final change in changes)
    if (isArea(change.area)) change.area,
};

Future<_Areas> _snapshot(StorageLease lease, Set<String> areas) async => {
  for (final area in areas)
    area: {
      for (final (:key, :value) in _done(
        await lease.entries(area, ''),
        'listing $area',
      ))
        key: value,
    },
};

_Areas _after(_Areas before, List<Change> changes) {
  final after = {
    for (final MapEntry(:key, :value) in before.entries) key: {...value},
  };
  for (final change in changes) {
    switch ((change, after[change.area])) {
      case (_, null):
        break;
      case (Put(:final key, :final value), final values?):
        values[key] = value;
      case (Delete(:final key), final values?):
        values.remove(key);
      case (ClearArea(), final values?):
        values.clear();
    }
  }
  return after;
}

bool _sameAreas(_Areas left, _Areas right) =>
    left.length == right.length &&
    left.entries.every(
      (area) =>
          right[area.key]?.length == area.value.length &&
          area.value.entries.every(
            (entry) => right[area.key]![entry.key] == entry.value,
          ),
    );

void _effect(
  Committing committing,
  _Areas before,
  _Areas expected,
  _Areas seen,
  String what,
) {
  final none = _sameAreas(seen, before);
  final all = _sameAreas(seen, expected);
  switch (committing) {
    case CommitApplied() when !all:
      _broke('$what: CommitApplied, but not every change is there');
    case CommitRefused() when !none:
      _broke('$what: $committing, but it changed storage');
    case CommitUnknown() when !all && !none:
      _broke('$what: $committing left some of its changes and not others');
    case _:
      return;
  }
}

Future<Committing> _commit(
  StorageLease lease,
  List<Change> changes,
  String what,
) async {
  final areas = _areasOf(changes);
  final before = await _snapshot(lease, areas);
  final committing = await lease.commit(changes);
  _effect(
    committing,
    before,
    _after(before, changes),
    await _snapshot(lease, areas),
    what,
  );
  return committing;
}

Future<void> _applied(
  StorageLease lease,
  List<Change> changes,
  String what,
) async {
  final committing = await _commit(lease, changes, what);
  if (committing is! CommitApplied) {
    _broke('$what gave $committing, not CommitApplied');
  }
}

Future<void> _put(
  StorageLease lease,
  String area,
  Map<String, String> values,
  String what,
) => _applied(lease, [
  for (final MapEntry(:key, :value) in values.entries) Put(area, key, value),
], what);

Future<void> _refusedAs<F extends StorageFailure>(
  StorageLease lease,
  List<Change> changes,
  String what,
) async {
  switch (await _commit(lease, changes, what)) {
    case CommitRefused(:final failure) when failure is F:
      return;
    case final other:
      _broke('$what gave $other, not CommitRefused($F)');
  }
}

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

Future<List<String>> _entryKeys(
  StorageLease lease,
  String area,
  String prefix,
) async => [
  for (final (:key, value: _) in _done(
    await lease.entries(area, prefix),
    'entries $area $prefix',
  ))
    key,
];

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

Future<void> _heldThroughEnd(
  EngineHarness harness,
  Future<Object?> Function(StorageEngine engine, StorageLease lease) end,
  String how,
) async {
  final first = await harness.open();
  final second = await harness.open();
  final held = await _lease(first);
  final changes = [
    for (var i = 0; i < 20; i++) Put(i.isEven ? 'a' : 'b', 'k$i', 'v$i'),
  ];
  const areas = {'a', 'b'};
  final before = await _snapshot(held, areas);
  final expected = _after(before, changes);
  final pending = harness.holdNextWrite(first);
  final writing = held.commit(changes);
  await pending.reached;
  final ending = end(first, held);
  await Future.any([
    ending,
    Future<void>.delayed(const Duration(milliseconds: 200)),
  ]);
  StorageLease? next;
  _Areas? atGrant;
  var nextWrote = false;
  if (await second.lease() case Leased(:final lease)) {
    next = lease;
    atGrant = await _snapshot(lease, areas);
    await _put(lease, 'a', {'k0': 'next'}, 'the next holder\'s write');
    nextWrote = true;
  }
  pending.letGo();
  await ending;
  next ??= await _lease(second);
  atGrant ??= await _snapshot(next, areas);
  final wrote = await writing;
  _effect(wrote, before, expected, atGrant, 'a write held while $how');
  final later = await _snapshot(next, areas);
  final kept = {
    for (final MapEntry(:key, :value) in atGrant.entries) key: {...value},
  };
  if (nextWrote) kept['a']!['k0'] = 'next';
  if (!_sameAreas(later, kept)) {
    _broke(
      'a write held while $how changed storage after the next lease was '
      'granted, or undid what the next holder saved',
    );
  }
  await harness.close(first);
  await harness.close(second);
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
  _check('a commit across areas is seen whole or not at all after a reopen', (
    harness,
  ) async {
    final first = await harness.open();
    final lease = await _lease(first);
    await _put(lease, 'c', {'old': '1'}, 'seed');
    await _put(lease, 'd', {'x': '1', 'y': '2'}, 'seed');
    await _applied(lease, const [
      Put('a', 'one', '1'),
      Put('b', 'two', '2'),
      Delete('c', 'old'),
      ClearArea('d'),
    ], 'a commit across four areas');
    await _refusedAs<KeyTooLong>(lease, [
      const Put('a', 'three', '3'),
      const Delete('b', 'two'),
      Put('c', 'k' * (lease.maxKeyLength + 1), 'too long'),
    ], 'a commit holding a name past the limit');
    await harness.crash(first);
    final reopened = await _lease(await harness.open());
    _same(await _read(reopened, 'a', 'one'), '1', 'area a');
    _same(await _read(reopened, 'b', 'two'), '2', 'area b');
    _same(await _read(reopened, 'c', 'old'), null, 'area c');
    _sameList(_done(await reopened.keys('d', ''), 'keys'), [], 'area d');
    _same(await _read(reopened, 'a', 'three'), null, 'a refused commit');
  }),
  _check('applies the changes of one commit in list order', (harness) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    await _put(lease, 'c', {'x': '0'}, 'seed');
    await _applied(lease, const [
      Put('a', 'k', '1'),
      Put('a', 'k', '2'),
      Put('b', 'k', '1'),
      Delete('b', 'k'),
      Put('c', 'k', '1'),
      ClearArea('c'),
      ClearArea('d'),
      Put('d', 'k', '1'),
    ], 'a commit naming the same names more than once');
    _same(await _read(lease, 'a', 'k'), '2', 'a later put');
    _same(await _read(lease, 'b', 'k'), null, 'a delete after a put');
    _sameList(_done(await lease.keys('c', ''), 'keys'), [], 'a clear after');
    _same(await _read(lease, 'd', 'k'), '1', 'a put after a clear');
    await harness.close(engine);
  }),
  _check('an empty commit applies and changes nothing', (harness) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    await _put(lease, 'a', {'x': '1', 'y': '2'}, 'seed');
    await _put(lease, 'b', {'z': '3'}, 'seed');
    const seeded = {'a', 'b'};
    final before = await _snapshot(lease, seeded);
    final areasBefore = _done(await lease.areas(''), 'areas');
    await _applied(lease, const [], 'an empty commit');
    if (!_sameAreas(await _snapshot(lease, seeded), before)) {
      _broke('an empty commit changed what is stored');
    }
    _sameList(
      _done(await lease.areas(''), 'areas'),
      areasBefore,
      'areas after an empty commit',
    );
    await harness.close(engine);
  }),
  _check(
    'a commit naming anything outside the alphabet or past the limit is refused whole',
    (harness) async {
      final engine = await harness.open();
      final lease = await _lease(engine);
      final limit = lease.maxKeyLength;
      await _put(lease, 'a', {'kept': '1', 'k' * limit: 'longest'}, 'seed');
      const ok = Put('a', 'new', '1');
      final cases = <String, (List<Change>, bool)>{
        'a name with a capital letter': (
          [ok, const Put('a', 'Bad', 'x')],
          true,
        ),
        'a name with a space': ([ok, const Put('a', 'a b', 'x')], true),
        'a name with %': ([ok, const Put('a', 'a%', 'x')], true),
        'an empty name': ([ok, const Put('a', '', 'x')], true),
        'a delete of a name outside the alphabet': (
          [ok, const Delete('a', 'Kept')],
          true,
        ),
        'an area outside the alphabet': ([ok, const Put('A', 'x', 'x')], true),
        'an area past its limit': (
          [ok, Put('a' * (maxAreaLength + 1), 'x', 'x')],
          true,
        ),
        'a clear of an area outside the alphabet': (
          [ok, const ClearArea('A')],
          true,
        ),
        'a put past the limit': ([ok, Put('a', 'k' * (limit + 1), 'x')], false),
        'a delete past the limit': (
          [ok, Delete('a', 'k' * (limit + 1))],
          false,
        ),
      };
      for (final MapEntry(key: what, value: (changes, alphabet))
          in cases.entries) {
        if (alphabet) {
          await _refusedAs<NameNotAllowed>(lease, changes, what);
        } else {
          await _refusedAs<KeyTooLong>(lease, changes, what);
        }
        _same(await _read(lease, 'a', 'new'), null, '$what: the valid put');
      }
      _same(await _read(lease, 'a', 'kept'), '1', 'a name refused deletes');
      _same(
        await _read(lease, 'a', 'k' * limit),
        'longest',
        'the longest name beside a delete past the limit',
      );
      await harness.close(engine);
    },
  ),
  _check('clearing an area deletes every name in it and nothing else', (
    harness,
  ) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    await _put(lease, 'area-1', {'a': '1', 'b/c': '2', 'z': '3'}, 'seed');
    await _put(lease, 'area-10', {'a': '1'}, 'seed');
    await _put(lease, 'area-2', {'a': '1'}, 'seed');
    await _applied(lease, const [ClearArea('area-1')], 'clear');
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
    await _put(lease, 'one', _values, 'write');
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
      'nx_y',
      'nxay',
    ];
    await _put(lease, 'a', {for (final name in names) name: name}, 'write');
    final sorted = [...names]..sort(compareCodeUnits);
    _sameList(_done(await lease.keys('a', ''), 'keys'), sorted, 'order');
    _sameList(await _entryKeys(lease, 'a', ''), sorted, 'entries order');
    for (final name in names) {
      _same(await _read(lease, 'a', name), name, 'read $name');
    }
    _same(await _read(lease, 'a', 'n_x_'), null, 'a near name');
    await harness.close(engine);
  }),
  _check('keys and entries match a prefix literally', (harness) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    const names = [
      'a-b',
      'a.b',
      'a/b',
      'a_b',
      'aab',
      'ab',
      'axb',
      'x_y',
      'xay',
      'xy',
    ];
    await _put(lease, 'a', {for (final name in names) name: name}, 'write');
    for (final prefix in ['a_', 'a-', 'a.', 'a/', 'x_', 'x_y', 'a.b', 'aa']) {
      final expected = [
        for (final name in [...names]..sort(compareCodeUnits))
          if (name.startsWith(prefix)) name,
      ];
      _sameList(
        _done(await lease.keys('a', prefix), 'keys'),
        expected,
        'keys under $prefix',
      );
      _sameList(
        await _entryKeys(lease, 'a', prefix),
        expected,
        'entries under $prefix',
      );
    }
    await harness.close(engine);
  }),
  _check(
    'lists the areas that hold names under a prefix, literally and in code unit order',
    (harness) async {
      final engine = await harness.open();
      final lease = await _lease(engine);
      const areas = [
        'xay',
        'a_1',
        'b',
        'a',
        'ab',
        'a/1',
        'x_y',
        'a.1',
        'aa1',
        'a-1',
      ];
      await _applied(lease, [
        for (final area in areas) Put(area, 'k', area),
        const Put('gone', 'k', '1'),
        const Put('emptied', 'k', '1'),
      ], 'seed');
      await _applied(lease, const [
        ClearArea('gone'),
        Delete('emptied', 'k'),
      ], 'empty two areas');
      final sorted = [...areas]..sort(compareCodeUnits);
      _sameList(
        _done(await lease.areas(''), 'areas'),
        sorted,
        'every area holding a name',
      );
      for (final prefix in ['a_', 'a-', 'a.', 'a/', 'x_', 'a', 'e', 'zz']) {
        _sameList(_done(await lease.areas(prefix), 'areas'), [
          for (final area in sorted)
            if (area.startsWith(prefix)) area,
        ], 'areas under $prefix');
      }
      await harness.close(engine);
    },
  ),
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
    await _put(lease, 'a', values, 'write');
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
    await _put(lease, 'a', {'x': '1', 'y': '2', 'z': '3'}, 'write');
    await _applied(lease, const [
      Delete('a', 'x'),
      Delete('a', 'z'),
      Delete('a', 'never'),
    ], 'delete');
    _sameList(_done(await lease.keys('a', ''), 'keys'), ['y'], 'kept');
    await harness.close(engine);
  }),
  _check('a commit that applied survives a crash, whole', (harness) async {
    final before = await harness.open();
    final lease = await _lease(before);
    await _put(lease, 'a', {
      for (var i = 0; i < 50; i++) 'k$i': 'v$i',
    }, 'write');
    await _applied(lease, const [
      Delete('a', 'k7'),
      Delete('a', 'k8'),
    ], 'delete');
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
    'holds names up to a limit of at least 255 that never changes, and reads longer ones as missing',
    (harness) async {
      final engine = await harness.open();
      final lease = await _lease(engine);
      final limit = lease.maxKeyLength;
      if (limit < 255) _broke('maxKeyLength $limit is under 255');
      final area = 'a' * maxAreaLength;
      final longest = 'k' * limit;
      await _put(lease, area, {longest: 'v'}, 'write');
      _same(await _read(lease, area, longest), 'v', 'the longest name');
      if (await lease.read(area, '${longest}k') is! KeyMissing) {
        _broke('reading a name past the limit was not KeyMissing');
      }
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
    final writing = held.commit(const [Put('a', 'x', 'first')]);
    await pending.reached;
    if (await second.lease() is! HeldByAnotherWriter) {
      _broke('a second lease was granted while the first was writing');
    }
    pending.letGo();
    if (await writing is! CommitApplied) _broke('the held write did not apply');
    if (await held.release() is! Released) _broke('release did not release');
    _endedStatus(held, 'released');
    final next = await _lease(second);
    _same(await _read(next, 'a', 'x'), 'first', 'the first writer\'s write');
    await harness.close(first);
    await harness.close(second);
  }),
  _check(
    'a write pending when its lease ends lands whole before the next grant or not at all',
    (harness) => _heldThroughEnd(
      harness,
      (engine, lease) => lease.release(),
      'released',
    ),
  ),
  _check(
    'a write pending when its engine closes lands whole before the next grant or not at all',
    (harness) => _heldThroughEnd(
      harness,
      (engine, lease) => harness.close(engine),
      'closed',
    ),
  ),
  _check(
    'a commit across areas cut short by a crash is seen whole or not at all',
    (harness) => _heldThroughEnd(
      harness,
      (engine, lease) => harness.crash(engine),
      'crashed',
    ),
  ),
  _check('grants one lease among callers who ask at nearly the same moment', (
    harness,
  ) async {
    final engines = [for (var i = 0; i < 3; i++) await harness.open()];
    Future<Leasing> now(int i) => engines[i].lease();
    Future<Leasing> nextMicrotask(int i) =>
        Future.microtask(() => engines[i].lease());
    Future<Leasing> nextTick(int i) => Future(() => engines[i].lease());
    final rounds = <String, List<Future<Leasing>> Function()>{
      'two in the same turn': () => [now(0), now(1)],
      'the same engine twice in the same turn': () => [now(0), now(0)],
      'one a microtask after the other': () => [now(0), nextMicrotask(1)],
      'one a timer tick after the other': () => [now(0), nextTick(1)],
      'three at staggered starts': () => [
        now(0),
        nextMicrotask(1),
        nextTick(2),
      ],
    };
    for (final MapEntry(key: what, value: ask) in rounds.entries) {
      final asked = await Future.wait(ask());
      final granted = asked.whereType<Leased>().toList();
      if (granted.length != 1) {
        _broke('$what: ${granted.length} leases were granted, not one');
      }
      for (final lease in granted) {
        await lease.lease.release();
      }
    }
    for (final engine in engines) {
      await harness.close(engine);
    }
  }),
  _check('an ended lease answers LeaseEnded before anything else', (
    harness,
  ) async {
    final engine = await harness.open();
    final lease = await _lease(engine);
    await _put(lease, 'a', {'x': 'kept'}, 'write');
    await lease.release();
    _endedStatus(lease, 'released');
    final long = 'k' * (lease.maxKeyLength + 1);
    _ended(await lease.read('a', 'x'), 'read');
    _ended(await lease.read('a', long), 'read of a long name');
    _ended(await lease.read('A', 'x'), 'read outside the alphabet');
    _ended(await lease.keys('a', ''), 'keys');
    _ended(await lease.entries('a', ''), 'entries');
    _ended(await lease.areas(''), 'areas');
    _ended(await lease.commit(const [Put('a', 'x', 'lost')]), 'write');
    _ended(await lease.commit([Put('a', long, 'lost')]), 'long write');
    _ended(await lease.commit([Delete('a', long)]), 'long delete');
    _ended(await lease.commit(const [Put('A', 'x', 'lost')]), 'bad area');
    _ended(await lease.commit(const []), 'empty commit');
    _ended(await lease.commit(const [Delete('a', 'x')]), 'delete');
    final next = await _lease(engine);
    _same(await _read(next, 'a', 'x'), 'kept', 'after release');
    await harness.close(engine);
  }),
  _check(
    'a lease ends when its engine closes, stays ended, and a closed engine answers EngineClosed',
    (harness) async {
      final first = await harness.open();
      final old = await _lease(first);
      await _put(old, 'a', {'name': 'before'}, 'write');
      await harness.close(first);
      _endedStatus(old, 'whose engine closed');
      _ended(await old.commit(const [Put('a', 'name', 'stale')]), 'write');
      switch (await first.lease()) {
        case LeaseFailed(failure: EngineClosed()):
          break;
        case final other:
          _broke('a closed engine answered $other, not EngineClosed');
      }
      final second = await harness.open();
      final current = await _lease(second);
      await _put(current, 'a', {'name': 'renamed'}, 'write');
      await current.release();
      _ended(await old.commit(const [Put('a', 'name', 'stale')]), 'write');
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
