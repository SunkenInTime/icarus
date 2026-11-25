import 'dart:convert';
import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';

final class Lives {
  final _names = <int, String>{};
  final _numbers = <String, int>{};

  String name(int life) => _names.putIfAbsent(life, () {
    final name = 'L${_names.length}';
    _numbers[name] = life;
    return name;
  });

  int number(String name) =>
      _numbers[name] ?? (throw StateError('$name has not been seen yet'));
}

Map<String, Object?> wireOf(OpAnswer answer, Lives lives) => switch (answer) {
  AppliedAnswer(:final opId, :final revision, :final life) => {
    'opId': opId,
    'status': 'applied',
    'appliedRevision': revision,
    'appliedLife': lives.name(life),
  },
  NoopAnswer(:final opId, :final revision, :final life, :final replay) => {
    'opId': opId,
    'status': 'noop',
    'currentRevision': revision,
    'currentLife': lives.name(life),
    if (replay == NoopReplay.appliedWhenFirstReceived) 'wasApplied': true,
  },
  AnswerWithoutLife(:final opId, :final revision) => {
    'opId': opId,
    'answered without a life': true,
    'revision': ?revision,
  },
  NoopWithoutRevision(:final opId) => {'opId': opId, 'status': 'noop'},
  RejectedAnswer(:final opId, :final reason, :final current) => {
    'opId': opId,
    'status': 'rejected',
    'reason': reason.wireName,
    if (current case ServerSnapshot(
      :final target,
      :final revision,
      life: final life?,
      :final value,
    ))
      'current': {
        'type': target.name,
        'revision': revision,
        'life': lives.name(life),
        'value': value.toJson(),
      },
  },
  FailedAnswer(:final opId, :final code) => {
    'opId': opId,
    'status': 'failed',
    'code': '$code',
  },
};

void main() {
  final cases =
      jsonDecode(File('test/server_cases.json').readAsStringSync())
          as List<Object?>;
  group(
    'the stand-in server answers these cases, sent through its batch method, '
    'as convex/ops.ts does (tool/server_cases/serverCases.test.ts runs the '
    'same file against the real one)',
    () {
      for (final raw in cases.cast<Map<String, Object?>>()) {
        test(raw['name']! as String, () {
          final server = Server();
          final lives = Lives();
          var attempt = 0;
          for (final step
              in (raw['steps']! as List).cast<Map<String, Object?>>()) {
            if (step['create'] == true) {
              server.create();
            } else if (step['recreate'] == true) {
              server.recreate();
            } else if (step['purge'] == true) {
              server.purgeAfterThirtyDays();
            } else {
              final ops = <StrategyOp>[];
              final named = <String, int>{};
              for (final op
                  in (step['send']! as List).cast<Map<String, Object?>>()) {
                final decoded = switch (StrategyOp.decode({
                  for (final MapEntry(:key, :value) in op.entries)
                    if (key != 'expectedLife') key: value,
                })) {
                  Read(:final value) => value,
                  CouldNotRead(:final problem) => fail(problem),
                };
                ops.add(decoded);
                if (op['expectedLife'] case final String life) {
                  named[decoded.opId] = lives.number(life);
                }
              }
              final events = server.answer(
                'device',
                SendBatch(
                  ++attempt,
                  'device',
                  ops,
                  strategyLife: switch (step['strategyLife']) {
                    final String life => lives.number(life),
                    _ => null,
                  },
                  lives: named,
                ),
              );
              if (step['refused'] case final String code) {
                expect(events, [
                  isA<BatchRefused>()
                      .having(
                        (event) => event.refusal,
                        'refusal',
                        BatchRefusal.strategyReplaced,
                      )
                      .having(
                        (event) => event.currentLife,
                        'currentLife',
                        createdAtOf(server.rows.strategy),
                      )
                      .having(
                        (event) => switch (event.currentLife) {
                          final life? => lives.name(life),
                          null => null,
                        },
                        'currentLife named',
                        step['currentLife'],
                      ),
                ]);
                expect(code, 'STRATEGY_REPLACED');
                continue;
              }
              final answers = [
                for (final event in events)
                  switch (event) {
                    OpAnswered(:final answer) => wireOf(answer, lives),
                    _ => fail('expected answers, got $event'),
                  },
              ];
              expect(answers, step['expect']);
            }
          }
        });
      }
    },
  );
}
