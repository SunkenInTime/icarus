import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

import 'released_batch_cases.dart';

const recordingPath = 'test/collab/fixtures/released_batch_arguments.json';

void main() {
  final recordTo = Platform.environment['RECORD_RELEASED_BATCH'];
  if (recordTo != null) {
    test('records the released batch arguments to $recordTo', () async {
      File(recordTo).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(await recordReleased())}'
        '\n',
      );
    });
    return;
  }

  final recorded = {
    for (final entry
        in jsonDecode(File(recordingPath).readAsStringSync()) as List<Object?>)
      (entry! as Map<String, Object?>)['case']! as String: entry,
  };

  test('the recording from main holds exactly these cases', () {
    expect(
      recorded.keys.toList(),
      [for (final released in releasedCases()) released.name],
    );
  });

  for (final released in releasedCases()) {
    test(
        '${released.name}: the arguments handed to the native client are the '
        'ones main sends, byte for byte and in order', () async {
      final call = await releasedCall(released);
      final args = call.args.toDart();
      expect(
        encodedSpecially(args),
        isNull,
        reason: 'buildArgs is jsonEncode of each argument only when no value '
            'needs the native client\'s special encoding',
      );
      expect(call.args.value['clientProtocolVersion'], isA<ConvexFloat>());
      expect(args['clientProtocolVersion'], isA<double>());
      expect(recordingOf(released.name, call), recorded[released.name]);
    });
  }
}
