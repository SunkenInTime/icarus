import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/share/share_link_format.dart';

void main() {
  final production = icarusProductionShareOrigin;
  final beta = Uri.parse('https://beta.icarusstrats.com');
  final pagesPreview = Uri.parse('https://abc123.icarus-web-a50.pages.dev');
  final localDev = Uri.parse('http://localhost:5000');

  group('share link formatting', () {
    test('builds user-facing icarusstrats.com share URLs', () {
      expect(
        buildIcarusShareLink('ICR-2345-6789-ABCD-EFGH', origin: production),
        'https://icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH',
      );
    });

    test('builds share URLs on the current web origin', () {
      expect(
        buildIcarusShareLink('ICR-2345-6789-ABCD-EFGH', origin: beta),
        'https://beta.icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH',
      );
      expect(
        buildIcarusShareLink('ICR-2345-6789-ABCD-EFGH', origin: pagesPreview),
        'https://abc123.icarus-web-a50.pages.dev/share/ICR-2345-6789-ABCD-EFGH',
      );
      expect(
        buildIcarusShareLink('ICR-2345-6789-ABCD-EFGH', origin: localDev),
        'http://localhost:5000/share/ICR-2345-6789-ABCD-EFGH',
      );
    });

    test('built links round-trip through the recognizer', () {
      for (final origin in [production, beta, pagesPreview, localDev]) {
        final link = buildIcarusShareLink(
          'ICR-2345-6789-ABCD-EFGH',
          origin: origin,
        );
        expect(
          extractIcarusShareCode(link, currentOrigin: origin),
          'ICR-2345-6789-ABCD-EFGH',
          reason: link,
        );
      }
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
          currentOrigin: production,
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
      expect(
        extractIcarusShareCode(
          'https://www.icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH',
          currentOrigin: production,
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
      expect(
        isIcarusShareUri(
          Uri.parse('https://icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH'),
          currentOrigin: production,
        ),
        isTrue,
      );
    });

    test('recognizes production links while running on another origin', () {
      expect(
        isIcarusShareUri(
          Uri.parse('https://icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH'),
          currentOrigin: beta,
        ),
        isTrue,
      );
      expect(
        extractIcarusShareCode(
          'https://www.icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH',
          currentOrigin: pagesPreview,
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
    });

    test('recognizes links on the current web origin', () {
      expect(
        isIcarusShareUri(
          Uri.parse(
            'https://beta.icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH',
          ),
          currentOrigin: beta,
        ),
        isTrue,
      );
      expect(
        extractIcarusShareCode(
          'https://BETA.icarusstrats.com/share/icr-2345-6789-abcd-efgh',
          currentOrigin: beta,
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
      expect(
        extractIcarusShareCode(
          'https://abc123.icarus-web-a50.pages.dev/share/ICR-2345-6789-ABCD-EFGH',
          currentOrigin: pagesPreview,
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
    });

    test('does not trust another origin just because the web app can', () {
      // A native build (production origin) must not accept beta links, and
      // a beta page must not accept a different preview's links.
      expect(
        isIcarusShareUri(
          Uri.parse(
            'https://beta.icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH',
          ),
          currentOrigin: production,
        ),
        isFalse,
      );
      expect(
        isIcarusShareUri(
          Uri.parse(
            'https://other.icarus-web-a50.pages.dev/share/ICR-2345-6789-ABCD-EFGH',
          ),
          currentOrigin: beta,
        ),
        isFalse,
      );
      expect(
        isIcarusShareUri(
          Uri.parse('http://beta.icarusstrats.com/share/ICR-2345-6789-ABCD'),
          currentOrigin: beta,
        ),
        isFalse,
        reason: 'scheme is part of the origin',
      );
      expect(
        isIcarusShareUri(
          Uri.parse('http://localhost:6000/share/ICR-2345-6789-ABCD-EFGH'),
          currentOrigin: localDev,
        ),
        isFalse,
        reason: 'port is part of the origin',
      );
    });

    test('the web page root is not a share link', () {
      expect(
        isIcarusShareUri(
          Uri.parse('https://beta.icarusstrats.com/'),
          currentOrigin: beta,
        ),
        isFalse,
      );
      expect(
        isIcarusShareUri(
          Uri.parse('https://beta.icarusstrats.com/?code=abc'),
          currentOrigin: beta,
        ),
        isFalse,
        reason: 'an auth callback carries ?code= but is not a share link',
      );
    });

    test('extracts codes from custom scheme links', () {
      expect(
        extractIcarusShareCode(
          'icarus://share?code=icr-2345-6789-abcd-efgh',
          currentOrigin: production,
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
      expect(
        extractIcarusShareCode(
          'icarus://share?code=icr-2345-6789-abcd-efgh',
          currentOrigin: beta,
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
    });

    test('keeps legacy UUID tokens unchanged', () {
      const legacyToken = '0ee927ca-babc-4350-9b6f-02cfa833b14b';
      expect(
        extractIcarusShareCode(
          'icarus://share?token=$legacyToken',
          currentOrigin: production,
        ),
        legacyToken,
      );
      expect(
        extractIcarusShareCode(
          'https://icarusstrats.com/share/$legacyToken',
          currentOrigin: production,
        ),
        legacyToken,
      );
    });

    test('rejects unrelated URLs', () {
      expect(
        extractIcarusShareCode(
          'https://example.com/share/ICR-2345-6789-ABCD-EFGH',
          currentOrigin: beta,
        ),
        isNull,
      );
      expect(
        isIcarusShareUri(
          Uri.parse('https://example.com/share/ICR-2345-6789-ABCD-EFGH'),
          currentOrigin: beta,
        ),
        isFalse,
      );
      expect(
        isIcarusShareUri(
          Uri.parse('https://icarusstrats.com.evil.test/share/ICR-2345'),
          currentOrigin: production,
        ),
        isFalse,
      );
      expect(
        isIcarusShareUri(
          Uri.parse('ftp://icarusstrats.com/share/ICR-2345-6789-ABCD-EFGH'),
          currentOrigin: production,
        ),
        isFalse,
      );
    });

    test('links that do not decode are rejected, not thrown', () {
      expect(
        isIcarusShareUri(
          Uri.parse('https://beta.icarusstrats.com/share/%FF'),
          currentOrigin: beta,
        ),
        isFalse,
      );
      expect(
        extractIcarusShareCode(
          'https://beta.icarusstrats.com/share/%FF',
          currentOrigin: beta,
        ),
        isNull,
      );
      expect(
        extractIcarusShareCode(
          'https://beta.icarusstrats.com/share?code=%E0%A4%A',
          currentOrigin: beta,
        ),
        isNull,
      );
    });

    test('rejects garbage input', () {
      expect(extractIcarusShareCode('', currentOrigin: beta), isNull);
      expect(extractIcarusShareCode('   ', currentOrigin: beta), isNull);
      expect(
        isIcarusShareUri(Uri.parse('share'), currentOrigin: beta),
        isFalse,
        reason: 'a relative path has no origin',
      );
      expect(
        isIcarusShareUri(Uri(), currentOrigin: beta),
        isFalse,
      );
    });

    test('accepts standalone share codes', () {
      expect(
        extractIcarusShareCode(
          'icr-2345-6789-abcd-efgh',
          currentOrigin: production,
        ),
        'ICR-2345-6789-ABCD-EFGH',
      );
    });
  });
}
