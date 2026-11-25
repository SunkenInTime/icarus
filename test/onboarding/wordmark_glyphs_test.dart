import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/onboarding/ignite_splash.dart';
import 'package:icarus/onboarding/wordmark_glyphs.dart';

void main() {
  test('the wordmark asset gives five letters around the mark', () {
    final glyphs = WordmarkGlyphs.parse(File(wordmarkAsset).readAsStringSync());
    final mark = glyphs.mark.getBounds();
    final letters = [for (final letter in glyphs.letters) letter.getBounds()];

    expect(letters, hasLength(5));
    for (final bounds in [mark, ...letters]) {
      expect(bounds.isEmpty, isFalse);
      expect(glyphs.viewBox.contains(bounds.topLeft), isTrue);
      expect(glyphs.viewBox.contains(bounds.bottomRight), isTrue);
    }
    expect(letters.where((b) => b.right < mark.left), hasLength(2));
    expect(letters.where((b) => b.left > mark.right), hasLength(3));
  });

  test('the web loader lights the same dots as the splash', () {
    final glyphs = WordmarkGlyphs.parse(File(wordmarkAsset).readAsStringSync());
    final page = File('web/index.html').readAsStringSync();
    final listed =
        RegExp(r'var mark = \[([^\]]*)\]').firstMatch(page)!.group(1)!;
    final rows = [
      for (final row in RegExp(r"'([01]+)'").allMatches(listed)) row.group(1)!,
    ];

    expect(rows, IgniteSplash.litRows(glyphs.mark));
    expect(page, contains('columns = ${IgniteSplash.latticeColumns}'));
    expect(page, contains('size = ${IgniteSplash.latticeSize.round()}'));
  });
}
