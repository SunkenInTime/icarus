import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/share/share_link_format.dart';

void main() {
  group('share link formatting', () {
    test('builds user-facing icarusstrats.com share URLs', () {
      expect(
        buildIcarusShareLink('ICR-2345-6789-ABCD-EFGH'),
        'https://icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH',
      );
    });

    test('generates normalized share codes', () {
      expect(
        generateIcarusShareCode(random: Random(1)),
        matches(
          RegExp(
            r'^ICR-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$',
          ),
        ),
      );
    });

    test('extracts codes from icarusstrats.com URLs', () {
      expect(
        extractIcarusShareCode(
          'https://icarusstrats.com/share/icr-2345-6789-abcd-efgh',
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
      expect(
        extractIcarusShareCode(
          'https://www.icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH',
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
      expect(
        isIcarusShareUri(
          Uri.parse('https://icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH'),
        ),
        isTrue,
      );
    });

    test('extracts codes from custom scheme links', () {
      expect(
        extractIcarusShareCode(
          'icarus://share?code=icr-2345-6789-abcd-efgh',
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
    });

    test('keeps legacy UUID tokens unchanged', () {
      const legacyToken = '0ee927ca-babc-4350-9b6f-02cfa833b14b';
      expect(
        extractIcarusShareCode('icarus://share?token=$legacyToken'),
        legacyToken,
      );
      expect(
        extractIcarusShareCode('https://icarusstrats.com/share/$legacyToken'),
        legacyToken,
      );
    });

    test('rejects unrelated URLs', () {
      expect(
        extractIcarusShareCode(
          'https://example.com/share/ICR-2345-6789-ABCD-EFGH',
        ),
        isNull,
      );
      expect(
        isIcarusShareUri(
          Uri.parse('https://example.com/share/ICR-2345-6789-ABCD-EFGH'),
        ),
        isFalse,
      );
    });

    test('accepts standalone share codes', () {
      expect(
        extractIcarusShareCode('icr-2345-6789-abcd-efgh'),
        'ICR-2345-6789-ABCD-EFGH',
      );
    });
  });
}
