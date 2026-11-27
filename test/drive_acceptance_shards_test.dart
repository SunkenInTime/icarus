import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/drive/acceptance.dart';

void main() {
  final repo = Directory.current;

  for (final onWindows in [false, true]) {
    final (:set, :starts, plan: _, leftOut: _) =
        acceptanceSet(repo, onWindows: onWindows);
    String? before(String name) => starts[name]!.before;
    final chains = chainsOf(set, before);
    final system = onWindows ? 'Windows' : 'Linux';

    test('on $system the chains hold every script of the set once', () {
      final inChains = chains.expand((chain) => chain).toList();
      expect(inChains.toSet(), set.toSet());
      expect(inChains, hasLength(set.length));
      for (final chain in chains) {
        expect(before(chain.first), isNull);
        for (var index = 1; index < chain.length; index++) {
          expect(before(chain[index]), chain[index - 1]);
        }
      }
    });

    for (final n in [1, 2, 3, 4, 5, 7]) {
      test(
          'on $system, split into $n parts, every script runs in exactly one '
          'part, no chain is split, and together they are the whole set', () {
        final parts = [for (var k = 1; k <= n; k++) shardOf(chains, k, n)];
        final ran = [
          for (final part in parts)
            for (final chain in part) ...chain,
        ];
        expect(ran, hasLength(set.length));
        expect(ran.toSet(), set.toSet());
        for (final part in parts) {
          for (final chain in part) {
            expect(chains, contains(equals(chain)));
          }
          final inPart = part.expand((chain) => chain).toSet();
          for (final name in inPart) {
            if (before(name) case final earlier?) {
              expect(inPart, contains(earlier), reason: name);
            }
          }
        }
        expect(
          [for (var k = 1; k <= n; k++) shardOf(chains, k, n)],
          parts,
          reason: 'the same names and n give the same parts',
        );
      });
    }
  }

  test('a part outside 1..n is refused', () {
    expect(() => shardOf(const [], 0, 4), throwsArgumentError);
    expect(() => shardOf(const [], 5, 4), throwsArgumentError);
    expect(() => shardOf(const [], 1, 0), throwsArgumentError);
  });

  group('combining the parts', () {
    late Directory scratch;
    final (:set, :starts, plan: _, leftOut: _) =
        acceptanceSet(repo, onWindows: Platform.isWindows);
    final plan = jsonDecode(
      File('tool/drive/acceptance.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final storeOnly = (plan['storeOnly']! as List).cast<String>().toSet();
    final chains = chainsOf(set, (name) => starts[name]!.before);

    setUp(() => scratch = Directory.systemTemp.createTempSync('parts-'));
    tearDown(() => scratch.deleteSync(recursive: true));

    String part(int k, int n, {Set<String> failing = const {}}) {
      final scripts = [
        for (final chain in shardOf(chains, k, n)) ...chain,
      ];
      final folder = Directory('${scratch.path}/part-$k')..createSync();
      bool alone(String name) => storeOnly.contains(name);
      File('${folder.path}/verdicts.json').writeAsStringSync(jsonEncode({
        'shard': '$k/$n',
        'scripts': scripts,
        'cleanInBoth': [
          for (final name in scripts)
            if (!alone(name) && !failing.contains(name)) name,
        ],
        'failingInBoth': [
          for (final name in scripts)
            if (!alone(name) && failing.contains(name)) name,
        ],
        'failingOnlyOnTheStore': const <String>[],
        'failingOnlyOnHive': const <String>[],
        'storeAloneClean': [
          for (final name in scripts)
            if (alone(name)) name,
        ],
        'storeAloneFailing': const <String>[],
      }));
      return folder.path;
    }

    test('four clean parts make a clean whole', () {
      final (:report, :clean) =
          combineParts([for (var k = 1; k <= 4; k++) part(k, 4)], repo);
      expect(clean, isTrue, reason: report);
      expect(report, contains('set: ${set.length} scripts in 4 parts'));
    });

    test('a part that never wrote its verdicts fails the whole', () {
      final folders = [for (var k = 1; k <= 4; k++) part(k, 4)];
      File('${folders[2]}/verdicts.json').deleteSync();

      final (:report, :clean) = combineParts(folders, repo);

      expect(clean, isFalse);
      expect(report, contains('did not finish'));
      expect(report, contains('part 3/4 is missing'));
    });

    test('a part left out of the list fails the whole', () {
      final (:report, :clean) =
          combineParts([for (var k = 1; k <= 3; k++) part(k, 4)], repo);

      expect(clean, isFalse);
      expect(report, contains('part 4/4 is missing'));
      expect(report, contains('no part ran'));
    });

    test('a part given twice fails the whole', () {
      final first = part(1, 2);
      final (:report, :clean) = combineParts([first, first, part(2, 2)], repo);

      expect(clean, isFalse);
      expect(report, contains('part 1/2 is given twice'));
    });

    test('a failing script in one part fails the whole and is named', () {
      final failing = chains
          .map((chain) => chain.first)
          .firstWhere((name) => !storeOnly.contains(name));
      final (:report, :clean) = combineParts(
        [for (var k = 1; k <= 4; k++) part(k, 4, failing: {failing})],
        repo,
      );

      expect(clean, isFalse);
      expect(report, contains('failing in both: 1 ($failing)'));
    });
  });
}
