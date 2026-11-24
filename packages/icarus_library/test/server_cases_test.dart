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
  NoopAnswer(:final opId, :final revision, :final life) => {
    'opId': opId,
    'status': 'noop',
    'currentRevision': revision,
    'currentLife': lives.name(life),
  },
  ReplayWithoutLife(:final opId, :final revision) => {
    'opId': opId,
    'status': 'noop',
    'currentRevision': revision,
  },
  NoopWithoutRevision(:final opId) => {'opId': opId, 'status': 'noop'},
  RejectedAnswer(:final opId, :final reason, :final current) => {
    'opId': opId,
    'status': 'rejected',
    'reason': reason.wireName,
    if (current case ServerSnapshot(
      :final target,
      :final revision,
      :final life,
    ))
      'current': {
        'type': target.name,
        'revision': revision,
        'life': lives.name(life),
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
    'the stand-in server answers these cases as convex/ops.ts does '
    '(convex/serverCases.test.ts runs the same file against the real one)',
    () {
      for (final raw in cases.cast<Map<String, Object?>>()) {
        test(raw['name']! as String, () {
          final server = Server();
          final lives = Lives();
          for (final step
              in (raw['steps']! as List).cast<Map<String, Object?>>()) {
            if (step['create'] == true) {
              server.create();
            } else if (step['recreate'] == true) {
              server.reupload();
            } else if (step['purge'] == true) {
              server.purgeAfterThirtyDays();
            } else {
              final replaced = switch (step['strategyLife']) {
                final String named =>
                  createdAtOf(server.rows.strategy) != lives.number(named),
                _ => false,
              };
              if (step['refused'] case final String code) {
                expect(replaced, isTrue);
                expect(code, 'STRATEGY_REPLACED');
                continue;
              }
              expect(replaced, isFalse);
              final answers = [
                for (final op
                    in (step['send']! as List).cast<Map<String, Object?>>())
                  () {
                    final named = op['expectedLife'];
                    final decoded = switch (StrategyOp.decode({
                      for (final MapEntry(:key, :value) in op.entries)
                        if (key != 'expectedLife') key: value,
                    })) {
                      Read(:final value) => value,
                      CouldNotRead(:final problem) => fail(problem),
                    };
                    return wireOf(
                      server.apply(
                        'device',
                        decoded,
                        expectedLife: named is String
                            ? lives.number(named)
                            : null,
                      ),
                      lives,
                    );
                  }(),
              ];
              expect(answers, step['expect']);
            }
          }
        });
      }
    },
  );
}
