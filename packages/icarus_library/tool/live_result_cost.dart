import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/take_cost.dart';

const _warmups = 5;
const _runs = 51;
const _burstPerSecond = 20;
const _burstSeconds = 10;
const _strategyId = takeStrategyId;
const _pageId = takePageId;
const _freehandPoints = freehandPoints;
const _life = itemLife;
final _account = takeAccount;

Never _fail(String why) {
  stderr.writeln('live_result_cost: $why');
  exit(1);
}

T _saved<T, R>(Saving<T, R> result, String what) => saved(result, what);

void _applied(Recorded recorded, String what) => applied(recorded, what);

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

String _takeLine(String what, TakeTimes times) =>
    '$what: longest main-isolate stretch median '
    '${_ms(times.longestMedian)} ms, worst ${_ms(times.longestWorst)} ms; '
    'record wall median ${_ms(times.wallMedian)} ms, worst '
    '${_ms(times.wallWorst)} ms';

Future<Map<String, Object?>> pageTakes(Directory folder) async {
  final results = <String, Object?>{};
  for (final (items, changed) in const [
    (300, 1),
    (60, 1),
    (300, 10),
    (300, 300),
  ]) {
    for (final checked in const [false, true]) {
      shownTakesChecked = checked;
      final label = 'T$items-$changed${checked ? '-checked' : ''}';
      final bench = await Bench.open(folder, items, label);
      final times = await timeTakes(bench, changed: changed);
      await bench.checkStored();
      await bench.close();
      stdout.writeln(
        _takeLine(
          'T $changed of $items items changed, $_runs results after '
          '$_warmups warm-ups, takes ${checked ? '' : 'not '}checked',
          times,
        ),
      );
      results[label] = times.toJson();
    }
  }
  shownTakesChecked = false;
  final (opened, opens) = await timeOpens(
    await Bench.open(folder, 300, 'open-300'),
  );
  await opened.close();
  stdout.writeln(
    _takeLine(
      'O the first result of 300 unchanged items after the store reopens, '
      '${opens.wall.length} reopens',
      opens,
    ),
  );
  results['O300'] = opens.toJson();
  return results;
}

Future<void> measureLiveResults(List<String> args) async {
  final folder = await Directory.systemTemp.createTemp('live_result_cost');
  try {
    final results = <String, Object?>{
      'platform': Platform.operatingSystem,
      'dart': Platform.version,
      if (args.contains('takes'))
        ...await pageTakes(folder)
      else if (args.contains('own'))
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
