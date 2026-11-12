import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/strategy/open_attempt.dart';

/// The body of the function whose declaration starts with [signature], from
/// its opening brace to the matching closing one.
String _bodyOf(String path, String signature) {
  final source = File(path).readAsStringSync();
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: '$signature is no longer in $path');
  // The parameter list can hold braces of its own (named parameters), so
  // the body starts at the brace after `async`.
  final open = source.indexOf('{', source.indexOf(') async', start));
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
  }
  fail('unbalanced braces after $signature');
}

/// Each `await` in [body] that is not followed by [through].
List<String> _bareWaits(String body, String through) {
  final withoutComments = body.replaceAll(RegExp(r'//.*'), '');
  return [
    for (final match in RegExp(r'\bawait\b\s*').allMatches(withoutComments))
      if (!withoutComments.startsWith(through, match.end))
        withoutComments
            .substring(match.start)
            .split('\n')
            .first
            .trim(),
  ];
}

void main() {
  test('a wait returns what it waited for while the open is current',
      () async {
    final opening = OpenAttempt(() => true);
    expect(await opening.wait(Future.value(7)), 7);
  });

  test('a wait ends an open that gave way while it waited', () async {
    var current = true;
    final opening = OpenAttempt(() => current);
    final step = Completer<int>();
    final waited = opening.wait(step.future);
    // The reader leaves, or opens another strategy, before the step answers.
    current = false;
    step.complete(7);
    await expectLater(waited, throwsA(isA<OpenGaveWay>()));
  });

  // Three rounds of review each found one more wait inside an open after
  // which a superseded open went on to change something: mark itself open,
  // mark another strategy saved, point the upload queue at itself. The rule
  // that ends that is mechanical, so it is checked mechanically: inside the
  // functions that make up an open, nothing waits except through the helper
  // that stops a superseded open.
  group('every wait inside an open can end it', () {
    const provider = 'lib/providers/strategy_provider.dart';
    const session = 'lib/providers/strategy_page_session_provider.dart';
    const editor = 'lib/strategy_view.dart';

    for (final (path, signature, through) in [
      (provider, 'Future<void> openCloudStrategy(', 'opening.wait('),
      (provider, 'Future<void> loadFromHive(', 'opening.wait('),
      (session, 'Future<void> initializeForStrategy(', 'opening.wait('),
      (editor, 'Future<void> _loadInitialStrategy(', '_unlessLeft('),
    ]) {
      test('$signature in $path', () {
        expect(
          _bareWaits(_bodyOf(path, signature), through),
          isEmpty,
          reason: 'Wait with `await $through...)` here. A plain await lets '
              'an open the reader already left carry on to its next step.',
        );
      });
    }

    test('the page step of both opens is given the attempt', () {
      for (final signature in [
        'Future<void> openCloudStrategy(',
        'Future<void> loadFromHive(',
      ]) {
        final body = _bodyOf(provider, signature);
        expect(body, contains('initializeForStrategy('));
        expect(
          body,
          contains('attempt: opening'),
          reason: 'Without it the page session waits on its own and cannot '
              'be stopped when $signature gives way.',
        );
      }
    });

    test('the check itself catches a plain await', () {
      const body = '{\n  await opening.wait(a());\n  await b();\n'
          '  // await in a comment\n}';
      expect(_bareWaits(body, 'opening.wait('), ['await b();']);
    });
  });
}
