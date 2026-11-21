import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/json.dart'
    show admitChecking, canonicalJson, settleNumbers;
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
    return settleNumbers(decoded);
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

  test(
    'a whole double of 2^53 or more, written by this platform, reads back as the same double',
    () {
      final numbers = [
        9007199254740992.0,
        1152921504606846976.0,
        -1152921504606846976.0,
        9223372036854775808.0,
        1e20,
        123456789012345680000.0,
      ];
      for (final text in [
        jsonEncode({'points': numbers}),
        canonicalJson({'points': numbers}),
      ]) {
        final admitted = admitChecking(text, counted);
        expect(admitted, isA<Admitted>(), reason: text);
        final points = ((admitted as Admitted).json! as JsonObject)['points']!;
        expect([...(points as JsonList)], numbers, reason: text);
        for (final point in points) {
          expect(point, isA<double>(), reason: text);
        }
      }
    },
  );

  test(
    'a number with a point or an exponent is a double on every platform, and saving it keeps its value',
    () {
      for (final (text, value) in [
        ('[9007199254740993e0]', 9007199254740992.0),
        ('[9007199254740991.1]', 9007199254740991.0),
        ('[1.5e300]', 1.5e300),
      ]) {
        final read =
            (admitChecking(text, counted) as Admitted).json! as JsonList;
        expect(read.single, value, reason: text);
        final again =
            (admitChecking(canonicalJson(read), counted) as Admitted).json!
                as JsonList;
        expect(again.single, value, reason: text);
      }
    },
  );

  test(
    'a whole number past 2^53 is written as the double that holds it exactly, and otherwise keeps its digits and is refused on reading',
    () {
      expect(
        canonicalJson([int.parse('1000000000000000000')]),
        canonicalJson([1e18]),
      );
      final inexact = canonicalJson([int.parse('1152921504606846977')]);
      expect(inexact, '[1152921504606846977]');
      expect(admitChecking(inexact, counted), isA<NotAdmitted>());
    },
    testOn: 'vm',
  );

  test(
    'a bare number past 2^53 reads as the same double on every platform',
    () {
      final admitted = admitChecking('1152921504606847000', counted);
      expect(
        admitted,
        isA<Admitted>().having(
          (admitted) => admitted.json,
          'json',
          isA<double>().having((json) => json, 'value', 1152921504606846976.0),
        ),
      );
    },
  );

  test(
    'the smallest 64-bit integer is written as the double that holds it',
    () {
      final smallest = int.parse('-9223372036854775808');
      final written = canonicalJson([smallest]);
      final read = (admitChecking(written, counted) as Admitted).json!;
      expect((read as JsonList).single, smallest.toDouble());
    },
    testOn: 'vm',
  );

  test('a whole number JavaScript writes for no double is refused', () {
    for (final text in [
      '[9007199254740993]',
      '[1152921504606846976]',
      '[9223372036854775808]',
      '[99999999999999999999]',
    ]) {
      expect(
        admitChecking(text, counted),
        isA<NotAdmitted>().having(
          (refused) => refused.problem,
          'problem',
          'holds a whole number JavaScript cannot hold exactly',
        ),
        reason: text,
      );
    }
    expect(walks, 0);
  });

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
