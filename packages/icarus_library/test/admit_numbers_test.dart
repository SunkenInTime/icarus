import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/json.dart'
    show admitChecking, allNumbersFinite;
import 'package:test/test.dart';

bool _writtenWholeOnTheWeb(double number) =>
    number.abs() >= 9007199254740992 &&
    number.abs() < 1e21 &&
    number == number.roundToDouble();

List<double> _doublesOfEveryMagnitude() {
  final random = Random(5);
  final bits = ByteData(8);
  final numbers = <double>[
    double.maxFinite,
    -double.maxFinite,
    double.minPositive,
    1e21,
    1e-7,
    0.000001,
    123456789012345680000.0,
    1.2345678901234567e-6,
    0.1,
    -0.0,
  ];
  while (numbers.length < 200000) {
    for (var i = 0; i < 8; i++) {
      bits.setUint8(i, random.nextInt(256));
    }
    final number = bits.getFloat64(0);
    if (number.isFinite) numbers.add(number);
    numbers.add(random.nextDouble() * pow(10, random.nextInt(40) - 12));
  }
  return [
    for (final number in numbers)
      if (!identical(1, 1.0) || !_writtenWholeOnTheWeb(number)) number,
  ];
}

void main() {
  var walks = 0;
  bool counted(Object? decoded) {
    walks++;
    return allNumbersFinite(decoded);
  }

  setUp(() => walks = 0);

  test(
    'rows of numbers as this platform writes them are decoded without a walk',
    () {
      final numbers = _doublesOfEveryMagnitude();
      for (var at = 0; at < numbers.length; at += 1000) {
        final text = jsonEncode({
          'payload': {
            'data': {
              'points': numbers.sublist(at, min(at + 1000, numbers.length)),
            },
          },
          'sortIndex': at,
        });
        expect(
          admitChecking(text, counted),
          isA<Admitted>(),
          reason: switch (admitChecking(text, counted)) {
            NotAdmitted(:final problem) => problem,
            Admitted() => '',
          },
        );
      }
      expect(walks, 0);
    },
  );

  test(
    'a row with one unusual number takes one walk, whatever else it holds',
    () {
      expect(admitChecking('{"a":1.5,"b":[12e5,2]}', counted), isA<Admitted>());
      expect(walks, 1);
      expect(
        admitChecking('{"a":1.5,"b":[9.99e308,2]}', counted),
        isA<NotAdmitted>().having(
          (refused) => refused.problem,
          'problem',
          'holds a number that is not finite',
        ),
      );
      expect(walks, 2);
    },
  );

  test('what the scan refuses by its spelling is refused before any walk', () {
    for (final text in [
      '[9007199254740993]',
      '[1e401]',
      '[0.${'0' * 93}1e401]',
      '${'[' * 129}${']' * 129}',
    ]) {
      expect(admitChecking(text, counted), isA<NotAdmitted>(), reason: text);
    }
    expect(walks, 0);
  });
}
