import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'icarus_library.dart';
import 'sqlite_storage.dart';

const takeStrategyId = 'live-result-strategy';
const takePageId = 'live-result-page';
const _build = 'live-result-cost';
const freehandPoints = 250;
const frameAt144Hz = 6944;
const itemLife = 1767326400000;

final takeAccount = Account('live-result-account');

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
  for (var i = 1; i < freehandPoints; i++) {
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
  pagePublicId: takePageId,
  payload: ElementPayload(
    kind: ElementKind.values.byName(kind),
    payloadVersion: 1,
    data: data,
  ),
  sortIndex: sortIndex,
  revision: revision,
  unknownFields: jsonObject(const {'createdAt': itemLife}),
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
    publicId: takePageId,
    strategyPublicId: takeStrategyId,
    name: 'Page 1',
    sortIndex: 0,
    isAttack: true,
    revision: 1,
    unknownFields: jsonObject(const {'createdAt': itemLife}),
  );

  HeaderRead header() => HeaderRead(
    strategy: ReadableStrategy(
      publicId: takeStrategyId,
      name: 'Dense retake',
      mapData: 'ascent',
      themeProfileId: null,
      revision: 1,
      createdAt: DateTime.utc(2026, 1, 2, 3),
      updatedAt: DateTime.utc(2026, 1, 2, 3),
      unknownFields: jsonObject(const {'createdAt': itemLife}),
    ),
    pages: [page],
    settings: [
      ReadablePageSettings(
        pagePublicId: takePageId,
        settings: const PageSettings(
          agentSize: 1,
          abilitySize: 1,
          useNeutralTeamColors: false,
        ),
        revision: 1,
        unknownFields: jsonObject(const {'createdAt': itemLife}),
      ),
    ],
  );

  PageRead read() => PageRead(page: page, elements: _rows, lineupGroups: []);

  (String, double) lastMove = ('', 0);

  var _changes = 0;

  PageRead moved() => landed(nextMove());

  PageRead changed(int count) {
    _rows = [..._rows];
    for (var step = 0; step < count; step++) {
      final index = (_changes + step) % _rows.length;
      final data = _data[index];
      if (data['position'] case Map<String, Object?>()) {
        final x = 200.0 + ((_changes + step) * 7.31) % 1400;
        _data[index] = {
          ...data,
          'position': {'dx': x, 'dy': 450.25},
        };
        lastMove = (_ids[index], x);
      } else {
        _data[index] = {
          ...data,
          'colorValue': (data['colorValue']! as int) + 1,
        };
      }
      _revisions[index]++;
      _rows[index] = _element(
        _ids[index],
        _kindOf[index],
        _data[index],
        index,
        _revisions[index],
      );
    }
    _changes += count;
    return read();
  }

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
    if (gap > frameAt144Hz) over++;
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

final class TakeCostFailed implements Exception {
  TakeCostFailed(this.why);

  final String why;

  @override
  String toString() => why;
}

Never _fail(String why) => throw TakeCostFailed(why);

T saved<T, R>(Saving<T, R> result, String what) => _saved(result, what);

void applied(Recorded recorded, String what) => _applied(recorded, what);

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
  Bench._(
    this.store,
    this.engine,
    this.server,
    this.session,
    this.clock,
    this.path,
  );

  final LibraryStore store;
  final SqliteEngine engine;
  final ServerPage server;
  final int session;
  final EngineClock clock;
  final String path;

  static Future<Bench> open(Directory folder, int elements, String label) =>
      _started(
        '${folder.path}${Platform.pathSeparator}library-$label.sqlite',
        ServerPage(elements, Seeded(elements)),
        adding: true,
      );

  Future<Bench> reopened() async {
    await close();
    return _started(path, server, adding: false);
  }

  static Future<Bench> _started(
    String path,
    ServerPage server, {
    required bool adding,
  }) async {
    final engine = SqliteEngine(path);
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
    if (adding) {
      _saved(
        await store.addCloudStrategy(takeAccount, server.header(), [
          server.read(),
        ]),
        'adding the cloud strategy',
      );
    }
    _applied(
      _saved(
        await store.record(takeAccount, takeStrategyId, const [
          AppRestarted(build: _build),
          ConnectionReturned(),
        ]),
        'opening a session',
      ),
      'opening a session',
    );
    final session = switch (await store.readStrategy(takeStrategyId)) {
      Found(value: StrategyContent(sync: final CloudStrategy cloud)) =>
        cloud.queue.session.number,
      final other => _fail('no cloud strategy to read a session from: $other'),
    };
    return Bench._(store, engine, server, session, clock, path);
  }

  Future<void> take(PageRead result) async => _applied(
    _saved(
      await store.record(takeAccount, takeStrategyId, [
        BaseArrived(result, session: session, from: const LiveResult()),
      ]),
      'a live page result',
    ),
    'a live page result',
  );

  Future<void> checkStored() async {
    final (id, x) = server.lastMove;
    final page = switch (await store.readPage(takeStrategyId, takePageId)) {
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

final class TakeTimes {
  final wall = <int>[];
  final longest = <int>[];

  int get wallMedian => _median(wall);
  int get wallWorst => wall.reduce(math.max);
  int get longestMedian => _median(longest);
  int get longestWorst => longest.reduce(math.max);

  static int _median(List<int> values) =>
      (values.toList()..sort())[values.length ~/ 2];

  Map<String, int> toJson() => {
    'wallMedian': wallMedian,
    'wallWorst': wallWorst,
    'longestMedian': longestMedian,
    'longestWorst': longestWorst,
  };
}

Future<int> _timedTake(
  Bench bench,
  Ticker ticker,
  PageRead result,
  TakeTimes? times,
) async {
  ticker.start();
  final watch = Stopwatch()..start();
  await bench.take(result);
  final took = watch.elapsedMicroseconds;
  ticker.stop();
  times?.wall.add(took);
  times?.longest.add(ticker.longest);
  return took;
}

Future<TakeTimes> timeTakes(
  Bench bench, {
  required int changed,
  int warmups = 5,
  int runs = 51,
}) async {
  final ticker = Ticker();
  final times = TakeTimes();
  for (var run = 0; run < warmups + runs; run++) {
    await _timedTake(
      bench,
      ticker,
      bench.server.changed(changed),
      run < warmups ? null : times,
    );
  }
  return times;
}

Future<(Bench, TakeTimes)> timeOpens(
  Bench bench, {
  int warmups = 2,
  int runs = 21,
}) async {
  final ticker = Ticker();
  final times = TakeTimes();
  var open = bench;
  for (var run = 0; run < warmups + runs; run++) {
    open = await open.reopened();
    await _timedTake(
      open,
      ticker,
      open.server.read(),
      run < warmups ? null : times,
    );
  }
  return (open, times);
}
