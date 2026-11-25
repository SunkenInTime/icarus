import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

const _strategyId = 'live-result-strategy';
const _pageId = 'live-result-page';
const _build = 'live-result-cost';
const _warmups = 5;
const _runs = 51;
const _burstPerSecond = 20;
const _burstSeconds = 10;
const _freehandPoints = 250;
const _frameAt144Hz = 6944;
const _life = 1767326400000;

final _account = Account('live-result-account');

const _readsAll = CanRead(element: _anyElement, lineupGroup: _anyLineupGroup);

bool _anyElement(ElementPayload payload) => true;

bool _anyLineupGroup(LineupGroupPayload payload) => true;

final class Seeded {
  Seeded(int seed) : _state = seed & 0xffffffff;

  int _state;

  double next() {
    _state = (_state + 0x6d2b79f5) & 0xffffffff;
    var t = _state;
    t = _imul(t ^ (t >>> 15), t | 1);
    t ^= (t + _imul(t ^ (t >>> 7), t | 61)) & 0xffffffff;
    return ((t ^ (t >>> 14)) & 0xffffffff) / 4294967296;
  }

  static int _imul(int a, int b) => (a * b) & 0xffffffff;

  String _hex(int count) => [
    for (var i = 0; i < count; i++) (next() * 16).floor().toRadixString(16),
  ].join();

  String uuid() {
    final variant = '89ab'[(next() * 4).floor()];
    return '${_hex(8)}-${_hex(4)}-4${_hex(3)}-$variant${_hex(3)}-${_hex(12)}';
  }

  T pick<T>(List<T> list) => list[(next() * list.length).floor()];

  Map<String, Object?> position() => {
    'dx': 200 + next() * 1400,
    'dy': 100 + next() * 800,
  };
}

const _agents = ['astra', 'jett', 'sova', 'omen', 'killjoy', 'viper', 'fade'];

const _kinds = [
  'agent',
  'ability',
  'ability',
  'utility',
  'text',
  'ability',
  'drawing',
  'agent',
  'ability',
  'text',
];

Map<String, Object?> _payload(String kind, String id, Seeded rng) {
  final position = rng.position();
  return switch (kind) {
    'agent' => {
      'kind': 'agent',
      'data': {
        'elementType': 'agent',
        'id': id,
        'isAlly': true,
        'isDeleted': false,
        'kind': 'plain',
        'lineUpID': null,
        'position': position,
        'state': 'none',
        'type': rng.pick(_agents),
        'weapon': 'none',
      },
    },
    'ability' => {
      'kind': 'ability',
      'data': {
        'armLengthsMeters': [10, 10, 10, 10],
        'data': {'index': (rng.next() * 4).floor(), 'type': rng.pick(_agents)},
        'elementType': 'ability',
        'id': id,
        'isAlly': true,
        'isDeleted': false,
        'length': 0,
        'lineUpID': null,
        'position': position,
        'rotation': 0,
        'visualState': {
          'showInnerFill': true,
          'showInnerOutline': true,
          'showRangeFill': true,
          'showRangeOutline': true,
          'showVisionCone': true,
        },
      },
    },
    'utility' => {
      'kind': 'utility',
      'data': {
        'angle': 0,
        'customColorValue': 4289887296,
        'customDiameter': null,
        'customLength': 1.895722920590427,
        'customOpacityPercent': 100,
        'customWidth': 0.2875432525951557,
        'elementType': 'utility',
        'id': id,
        'isAlly': true,
        'isDeleted': false,
        'length': 0,
        'mapDoor': null,
        'position': position,
        'rotation': 1.5707963267948966,
        'type': 'customRectangle',
        'visionElevation': null,
      },
    },
    'text' => {
      'kind': 'text',
      'data': {
        'elementType': 'text',
        'fontSize': 20,
        'id': id,
        'isDeleted': false,
        'position': position,
        'size': 260,
        'sizeVersion': 1,
        'tagColorValue': 4280468830,
        'text': 'Smoke heaven, then swing\nwith the flash',
      },
    },
    _ => _freehand(id, rng),
  };
}

Map<String, Object?> _freehand(String id, Seeded rng) {
  final points = [rng.position()];
  for (var i = 1; i < _freehandPoints; i++) {
    final last = points[i - 1];
    points.add({
      'dx': (last['dx']! as double) + (rng.next() - 0.4) * 6,
      'dy': (last['dy']! as double) + (rng.next() - 0.45) * 6,
    });
  }
  double edge(String axis, double Function(double, double) pick) =>
      points.map((point) => point[axis]! as double).reduce(pick);
  return {
    'kind': 'drawing',
    'data': {
      'boundingBox': {
        'max': {'dx': edge('dx', math.max), 'dy': edge('dy', math.max)},
        'min': {'dx': edge('dx', math.min), 'dy': edge('dy', math.min)},
      },
      'colorValue': 4280468830,
      'elementType': 'drawing',
      'hasArrow': true,
      'id': id,
      'isDotted': false,
      'listOfPoints': points,
      'showTraversalTime': false,
      'thickness': 5,
      'traversalSpeedProfile': 'running',
      'type': 'freeDrawing',
    },
  };
}

LiveElement _element(
  String id,
  String kind,
  Map<String, Object?> data,
  int sortIndex,
  int revision,
) => LiveElement(
  publicId: id,
  pagePublicId: _pageId,
  payload: ElementPayload(
    kind: ElementKind.values.byName(kind),
    payloadVersion: 1,
    data: data,
  ),
  sortIndex: sortIndex,
  revision: revision,
  unknownFields: jsonObject(const {'createdAt': _life}),
);

final class ServerPage {
  ServerPage(int count, Seeded rng) {
    for (var index = 0; index < count; index++) {
      final id = rng.uuid();
      final kind = _kinds[index % _kinds.length];
      final made = _payload(kind, id, rng);
      _kindOf.add(made['kind']! as String);
      _data.add(made['data']! as Map<String, Object?>);
      _ids.add(id);
      _revisions.add(1);
      if ((_data.last).containsKey('position')) _movable.add(index);
    }
    _rows = [
      for (var index = 0; index < count; index++)
        _element(_ids[index], _kindOf[index], _data[index], index, 1),
    ];
  }

  final _ids = <String>[];
  final _kindOf = <String>[];
  final _data = <Map<String, Object?>>[];
  final _revisions = <int>[];
  final _movable = <int>[];
  late List<LiveElement> _rows;
  var _moves = 0;

  int get freehand => _kindOf.where((kind) => kind == 'drawing').length;

  final page = LivePage(
    publicId: _pageId,
    strategyPublicId: _strategyId,
    name: 'Page 1',
    sortIndex: 0,
    isAttack: true,
    revision: 1,
    unknownFields: jsonObject(const {'createdAt': _life}),
  );

  HeaderRead header() => HeaderRead(
    strategy: ReadableStrategy(
      publicId: _strategyId,
      name: 'Dense retake',
      mapData: 'ascent',
      themeProfileId: null,
      revision: 1,
      createdAt: DateTime.utc(2026, 1, 2, 3),
      updatedAt: DateTime.utc(2026, 1, 2, 3),
      unknownFields: jsonObject(const {'createdAt': _life}),
    ),
    pages: [page],
    settings: [
      ReadablePageSettings(
        pagePublicId: _pageId,
        settings: const PageSettings(
          agentSize: 1,
          abilitySize: 1,
          useNeutralTeamColors: false,
        ),
        revision: 1,
        unknownFields: jsonObject(const {'createdAt': _life}),
      ),
    ],
  );

  PageRead read() => PageRead(page: page, elements: _rows, lineupGroups: []);

  (String, double) lastMove = ('', 0);

  PageRead moved() => landed(nextMove());

  Move nextMove() {
    final index = _movable[_moves % _movable.length];
    _moves++;
    final x = 200.0 + (_moves * 7.31) % 1400;
    final data = {
      ..._data[index],
      'position': {'dx': x, 'dy': 450.25},
    };
    return Move(
      index: index,
      id: _ids[index],
      revision: _revisions[index],
      x: x,
      payload: ElementPayload(
        kind: ElementKind.values.byName(_kindOf[index]),
        payloadVersion: 1,
        data: data,
      ),
      data: data,
    );
  }

  PageRead landed(Move move) {
    final index = move.index;
    final x = move.x;
    _data[index] = move.data;
    _revisions[index] = move.revision + 1;
    _rows = [..._rows];
    _rows[index] = _element(
      _ids[index],
      _kindOf[index],
      _data[index],
      index,
      _revisions[index],
    );
    lastMove = (_ids[index], x);
    return read();
  }
}

final class Move {
  Move({
    required this.index,
    required this.id,
    required this.revision,
    required this.x,
    required this.payload,
    required this.data,
  });

  final int index;
  final String id;
  final int revision;
  final double x;
  final ElementPayload payload;
  final Map<String, Object?> data;
}

final class Ticker {
  final _clock = Stopwatch();
  var _running = false;
  var _last = 0;
  int longest = 0;
  int busy = 0;
  int over = 0;

  void start() {
    _running = true;
    longest = 0;
    busy = 0;
    over = 0;
    _clock
      ..reset()
      ..start();
    _last = 0;
    _schedule();
  }

  void _schedule() => Timer(Duration.zero, _tick);

  void _tick() {
    _gap();
    if (_running) _schedule();
  }

  void _gap() {
    final now = _clock.elapsedMicroseconds;
    final gap = now - _last;
    _last = now;
    if (gap > longest) longest = gap;
    if (gap > 50) busy += gap;
    if (gap > _frameAt144Hz) over++;
  }

  void stop() {
    _gap();
    _running = false;
  }
}

final class EngineClock {
  int waited = 0;
  int commits = 0;
  int reads = 0;

  void reset() {
    waited = 0;
    commits = 0;
    reads = 0;
  }
}

final class TimedEngine implements StorageEngine {
  TimedEngine(this.inner, this.clock);

  final SqliteEngine inner;
  final EngineClock clock;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
    Leased(:final lease) => Leased(_TimedLease(lease, clock)),
    final other => other,
  };
}

final class _TimedLease implements StorageLease {
  _TimedLease(this.inner, this.clock);

  final StorageLease inner;
  final EngineClock clock;

  Future<T> _timed<T>(Future<T> Function() call) async {
    final watch = Stopwatch()..start();
    try {
      return await call();
    } finally {
      clock.waited += watch.elapsedMicroseconds;
    }
  }

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  LeaseStatus get status => inner.status;

  @override
  Future<KeyRead> read(String area, String key) {
    clock.reads++;
    return _timed(() => inner.read(area, key));
  }

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) {
    clock.reads++;
    return _timed(() => inner.keys(area, prefix));
  }

  @override
  Future<Stored<List<String>>> areas(String prefix) {
    clock.reads++;
    return _timed(() => inner.areas(prefix));
  }

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) {
    clock.reads++;
    return _timed(() => inner.entries(area, prefix));
  }

  @override
  Future<Committing> commit(List<Change> changes) {
    clock.commits++;
    return _timed(() => inner.commit(changes));
  }

  @override
  Future<Releasing> release() => inner.release();
}

Never _fail(String why) {
  stderr.writeln('live_result_cost: $why');
  exit(1);
}

T _saved<T, R>(Saving<T, R> result, String what) => switch (result) {
  Saved(:final value) => value,
  NothingToSave() => _fail('$what saved nothing'),
  Refused(:final reason) => _fail('$what was refused: $reason'),
  NotSaved(:final failure) => _fail('$what was not saved: $failure'),
  SaveInDoubt(:final failure) => _fail('$what is in doubt: $failure'),
};

void _applied(Recorded recorded, String what) {
  for (final outcome in recorded.outcomes) {
    switch (outcome) {
      case ReportApplied() || EditsGoThroughCommit():
        break;
      case ReportNotApplicable(:final why):
        _fail('$what did not apply: $why');
    }
  }
}

final class Bench {
  Bench._(this.store, this.engine, this.server, this.session, this.clock);

  final LibraryStore store;
  final SqliteEngine engine;
  final ServerPage server;
  final int session;
  final EngineClock clock;

  static Future<Bench> open(
    Directory folder,
    int elements,
    String label,
  ) async {
    final engine = SqliteEngine(
      '${folder.path}${Platform.pathSeparator}library-$label.sqlite',
    );
    final clock = EngineClock();
    final store = switch (await LibraryStore.open(
      TimedEngine(engine, clock),
      canRead: _readsAll,
      clock: () => DateTime.now().toUtc(),
      build: _build,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => _fail('store did not open: $problem'),
    };
    store.takeCloudResultsFrom(CloudResults.liveQueries);
    final server = ServerPage(elements, Seeded(elements));
    _saved(
      await store.addCloudStrategy(_account, server.header(), [server.read()]),
      'adding the cloud strategy',
    );
    _applied(
      _saved(
        await store.record(_account, _strategyId, const [
          AppRestarted(build: _build),
          ConnectionReturned(),
        ]),
        'opening a session',
      ),
      'opening a session',
    );
    final session = switch (await store.readStrategy(_strategyId)) {
      Found(value: StrategyContent(sync: final CloudStrategy cloud)) =>
        cloud.queue.session.number,
      final other => _fail('no cloud strategy to read a session from: $other'),
    };
    return Bench._(store, engine, server, session, clock);
  }

  Future<void> take(PageRead result) async => _applied(
    _saved(
      await store.record(_account, _strategyId, [
        BaseArrived(result, session: session, from: const LiveResult()),
      ]),
      'a live page result',
    ),
    'a live page result',
  );

  Future<void> checkStored() async {
    final (id, x) = server.lastMove;
    final page = switch (await store.readPage(_strategyId, _pageId)) {
      Found(:final value) => value,
      final other => _fail('the page could not be read back: $other'),
    };
    final row = page.elements.firstWhere((row) => row.publicId == id);
    final stored = switch (row) {
      ReadableElementRow(:final payload) =>
        (payload.data['position']! as JsonObject)['dx'],
      _ => _fail('the moved element reads back unreadable'),
    };
    if (stored != x) {
      _fail('the last move reads back at $stored, not $x');
    }
  }

  Future<void> close() async {
    await store.close();
    await engine.close();
  }
}

int _median(List<int> values) => (values.toList()..sort())[values.length ~/ 2];

int _worst(List<int> values) => values.reduce(math.max);

String _ms(int micros) => (micros / 1000).toStringAsFixed(2);

Future<Map<String, Object?>> oneAtATime(Directory folder, int elements) async {
  final bench = await Bench.open(folder, elements, 'one-$elements');
  final ticker = Ticker();
  for (var warm = 0; warm < _warmups; warm++) {
    await bench.take(bench.server.moved());
  }
  final wall = <int>[];
  final longest = <int>[];
  final busy = <int>[];
  final waited = <int>[];
  final commits = <int>[];
  final reads = <int>[];
  for (var run = 0; run < _runs; run++) {
    final result = bench.server.moved();
    bench.clock.reset();
    ticker.start();
    final watch = Stopwatch()..start();
    await bench.take(result);
    final took = watch.elapsedMicroseconds;
    ticker.stop();
    wall.add(took);
    longest.add(ticker.longest);
    busy.add(ticker.busy);
    waited.add(bench.clock.waited);
    commits.add(bench.clock.commits);
    reads.add(bench.clock.reads);
  }
  await bench.checkStored();
  final freehand = bench.server.freehand;
  await bench.close();
  final summary = {
    'elements': elements,
    'freehand': freehand,
    'runs': _runs,
    'wallMedian': _median(wall),
    'wallWorst': _worst(wall),
    'longestMedian': _median(longest),
    'longestWorst': _worst(longest),
    'mainBusyMedian': _median(busy),
    'mainBusyWorst': _worst(busy),
    'engineWaitMedian': _median(waited),
    'engineWaitWorst': _worst(waited),
    'commitsMedian': _median(commits),
    'readsMedian': _median(reads),
  };
  stdout.writeln(
    'A $elements elements ($freehand freehand of $_freehandPoints points), '
    '$_runs results after $_warmups warm-ups: record wall median '
    '${_ms(_median(wall))} ms, worst ${_ms(_worst(wall))} ms; longest '
    'main-isolate stretch median ${_ms(_median(longest))} ms, worst '
    '${_ms(_worst(longest))} ms; main-isolate busy in total median '
    '${_ms(_median(busy))} ms, worst ${_ms(_worst(busy))} ms; waiting on '
    'the SQLite isolate median ${_ms(_median(waited))} ms, worst '
    '${_ms(_worst(waited))} ms (${_median(commits)} commits, '
    '${_median(reads)} reads per result)',
  );
  return summary;
}

final class _Arrival {
  _Arrival(this.index, this.due, this.result);

  final int index;
  final int due;
  final PageRead result;
}

Future<Map<String, Object?>> burst(
  Directory folder,
  int elements, {
  required bool newestOnly,
}) async {
  final bench = await Bench.open(
    folder,
    elements,
    newestOnly ? 'newest-$elements' : 'every-$elements',
  );
  for (var warm = 0; warm < _warmups; warm++) {
    await bench.take(bench.server.moved());
  }
  final total = _burstPerSecond * _burstSeconds;
  const every = 1000000 ~/ _burstPerSecond;
  final pending = <_Arrival>[];
  final waitingAtStart = <int>[];
  final recordWall = <int>[];
  final storedAfter = List<int?>.filled(total, null);
  var arrived = 0;
  var taken = 0;
  var running = false;
  final allDone = Completer<void>();
  final ticker = Ticker();
  final clock = Stopwatch();

  Future<void> drain() async {
    running = true;
    while (pending.isNotEmpty) {
      final next = newestOnly ? pending.removeLast() : pending.removeAt(0);
      final skipped = newestOnly ? [...pending] : const <_Arrival>[];
      if (newestOnly) pending.clear();
      waitingAtStart.add(pending.length + skipped.length);
      final started = clock.elapsedMicroseconds;
      await bench.take(next.result);
      final finished = clock.elapsedMicroseconds;
      recordWall.add(finished - started);
      taken++;
      for (final done in [...skipped, next]) {
        storedAfter[done.index] = finished - done.due;
      }
    }
    running = false;
    if (arrived == total && !allDone.isCompleted) allDone.complete();
  }

  clock.start();
  ticker.start();
  final feed = Timer.periodic(const Duration(microseconds: every), (timer) {
    while (arrived < total && arrived < timer.tick) {
      final result = bench.server.moved();
      pending.add(_Arrival(arrived, (arrived + 1) * every, result));
      arrived++;
    }
    if (arrived == total) timer.cancel();
    if (!running) unawaited(drain());
  });
  await allDone.future;
  feed.cancel();
  ticker.stop();
  await bench.checkStored();
  await bench.close();
  final behind = storedAfter.whereType<int>().toList();
  if (behind.length != total) _fail('${total - behind.length} never stored');
  final rule = newestOnly ? 'newest only' : 'every result';
  final summary = {
    'elements': elements,
    'rule': rule,
    'arrived': total,
    'recorded': taken,
    'longestStall': ticker.longest,
    'stallsOverFrame': ticker.over,
    'waitingMedian': _median(waitingAtStart),
    'waitingMax': _worst(waitingAtStart),
    'waitingLast': waitingAtStart.last,
    'storedAfterMedian': _median(behind),
    'storedAfterWorst': _worst(behind),
    'recordWallMedian': _median(recordWall),
    'recordWallWorst': _worst(recordWall),
    'elapsed': clock.elapsedMicroseconds,
  };
  stdout.writeln(
    'B $elements elements, $rule: $total results at $_burstPerSecond a '
    'second, $taken recorded, finished after '
    '${_ms(clock.elapsedMicroseconds)} ms; longest main-isolate stall '
    '${_ms(ticker.longest)} ms, ${ticker.over} stalls over one 144 Hz frame; '
    'results waiting when a record started median '
    '${_median(waitingAtStart)}, most ${_worst(waitingAtStart)}, at the last '
    'one ${waitingAtStart.last}; arrival to stored (it or a newer result) '
    'median ${_ms(_median(behind))} ms, worst ${_ms(_worst(behind))} ms; '
    'record wall median ${_ms(_median(recordWall))} ms, worst '
    '${_ms(_worst(recordWall))} ms',
  );
  return summary;
}

final class StepTimes {
  final wall = <int>[];
  final longest = <int>[];
  final waited = <int>[];

  Map<String, int> summary() => {
    'wallMedian': _median(wall),
    'wallWorst': _worst(wall),
    'longestMedian': _median(longest),
    'longestWorst': _worst(longest),
    'engineWaitMedian': _median(waited),
    'longestFirstTenMedian': _median(longest.take(10).toList()),
    'longestLastTenMedian': _median(longest.skip(longest.length - 10).toList()),
  };

  String line(String what) =>
      '$what wall median ${_ms(_median(wall))} ms, worst '
      '${_ms(_worst(wall))} ms; longest main-isolate stretch median '
      '${_ms(_median(longest))} ms, worst ${_ms(_worst(longest))} ms; '
      'waiting on SQLite median ${_ms(_median(waited))} ms; longest stretch '
      'median of the first ten ${_ms(_median(longest.take(10).toList()))} ms, '
      'of the last ten '
      '${_ms(_median(longest.skip(longest.length - 10).toList()))} ms';
}

Future<T> _timed<T>(
  Bench bench,
  Ticker ticker,
  StepTimes? times,
  Future<T> Function() step,
) async {
  bench.clock.reset();
  ticker.start();
  final watch = Stopwatch()..start();
  final value = await step();
  final took = watch.elapsedMicroseconds;
  ticker.stop();
  times?.wall.add(took);
  times?.longest.add(ticker.longest);
  times?.waited.add(bench.clock.waited);
  return value;
}

Future<Map<String, Object?>> ownMoves(
  Directory folder,
  int elements, {
  required bool takeResults,
}) async {
  final bench = await Bench.open(
    folder,
    elements,
    takeResults ? 'own-$elements' : 'own-quiet-$elements',
  );
  final ticker = Ticker();
  final commit = StepTimes();
  final claim = StepTimes();
  final answer = StepTimes();
  final result = StepTimes();
  for (var run = 0; run < _warmups + _runs; run++) {
    final measured = run >= _warmups;
    final move = bench.server.nextMove();
    final opId = 'own-move-$run';
    final seen = switch (await bench.store.readStrategy(_strategyId)) {
      Found(:final value) => value,
      final other => _fail('the strategy could not be read: $other'),
    };
    _saved(
      await _timed(
        bench,
        ticker,
        measured ? commit : null,
        () => bench.store.commitAs(
          _account,
          _strategyId,
          ElementPatchOp(
            opId: opId,
            elementPublicId: move.id,
            pagePublicId: _pageId,
            expectedElementRevision: move.revision,
            payload: move.payload,
          ),
          seen: seen,
        ),
      ),
      'an own move',
    );
    final claimed = _saved(
      await _timed(
        bench,
        ticker,
        measured ? claim : null,
        () => bench.store.record(_account, _strategyId, [
          BatchClaimed(
            clientId: 'live-result-client',
            opIds: [opId],
            at: DateTime.now().toUtc(),
          ),
        ]),
      ),
      'claiming the move',
    );
    _applied(claimed, 'claiming the move');
    final attempt = switch ([
      for (final outcome in claimed.outcomes)
        if (outcome case ReportApplied(:final effects))
          ...effects.whereType<SendBatch>(),
    ]) {
      [final sent] when sent.ops.single.opId == opId => sent.attempt,
      final other => _fail('claiming the move sent $other'),
    };
    _applied(
      _saved(
        await _timed(
          bench,
          ticker,
          measured ? answer : null,
          () => bench.store.record(_account, _strategyId, [
            OpAnswered(
              attempt,
              AppliedAnswer(opId, revision: move.revision + 1, life: _life),
            ),
          ]),
        ),
        'the applied answer',
      ),
      'the applied answer',
    );
    final page = bench.server.landed(move);
    if (takeResults) {
      await _timed(
        bench,
        ticker,
        measured ? result : null,
        () => bench.take(page),
      );
    }
  }
  await bench.checkStored();
  final queue = switch (await bench.store.readStrategy(_strategyId)) {
    Found(value: StrategyContent(sync: final CloudStrategy cloud)) =>
      cloud.queue,
    final other => _fail('no cloud strategy to read the queue from: $other'),
  };
  await bench.close();
  final label = takeResults
      ? 'each followed by its live page result'
      : 'with no live page results taken';
  stdout.writeln(
    'C $elements elements, $_runs own moves after $_warmups warm-ups, '
    '$label (queue at the end: ${queue.entries.length} entries, '
    '${queue.landed.length} landed):',
  );
  stdout.writeln('  ${commit.line('commit to stored:')}');
  stdout.writeln('  ${claim.line('claim:')}');
  stdout.writeln('  ${answer.line('applied answer:')}');
  if (takeResults) stdout.writeln('  ${result.line('page result:')}');
  return {
    'elements': elements,
    'takeResults': takeResults,
    'entriesAtEnd': queue.entries.length,
    'landedAtEnd': queue.landed.length,
    'commit': commit.summary(),
    'claim': claim.summary(),
    'answer': answer.summary(),
    if (takeResults) 'result': result.summary(),
  };
}

Future<void> measureLiveResults(List<String> args) async {
  final folder = await Directory.systemTemp.createTemp('live_result_cost');
  try {
    final results = <String, Object?>{
      'platform': Platform.operatingSystem,
      'dart': Platform.version,
      if (args.contains('own'))
        for (final (elements, takeResults) in const [
          (300, true),
          (60, true),
          (300, false),
        ])
          'C$elements${takeResults ? '' : 'quiet'}': await ownMoves(
            folder,
            elements,
            takeResults: takeResults,
          )
      else ...{
        'A300': await oneAtATime(folder, 300),
        'A60': await oneAtATime(folder, 60),
        'B300': await burst(folder, 300, newestOnly: false),
        'B300newest': await burst(folder, 300, newestOnly: true),
      },
    };
    stdout.writeln('JSON ${jsonEncode(results)}');
  } finally {
    await folder.delete(recursive: true);
  }
}
