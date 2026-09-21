import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_markup.dart';

TextEditingValue value(
  String text, {
  int? start,
  int? end,
}) {
  final offset = start ?? text.length;
  return TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: offset,
      extentOffset: end ?? offset,
    ),
  );
}

void main() {
  test('parses line kinds and inline markers', () {
    final lines = parseMarkup('- bullet\n2. numbered\n# heading\n*foo*');
    expect(lines.map((line) => line.kind), [
      MarkupLineKind.bullet,
      MarkupLineKind.numbered,
      MarkupLineKind.heading,
      MarkupLineKind.paragraph,
    ]);
    expect(lines[1].number, 2);
    expect(lines[3].plainText, 'foo');
    expect(lines[3].inlines.where((inline) => inline.isMarker), hasLength(2));
  });

  test('keeps unclosed markers literal and parses bold italic', () {
    expect(parseMarkup('**unclosed').single.plainText, '**unclosed');
    final inlines = parseMarkup('***x***').single.inlines;
    expect(inlines.where((inline) => inline.isMarker), hasLength(2));
    expect(inlines[1].bold, isTrue);
    expect(inlines[1].italic, isTrue);
    expect(parseMarkup('a * b').single.plainText, 'a * b');
  });

  test('renumbers numbered runs from the first typed number', () {
    final lines = parseMarkup('4. one\n9. two\n10. three');
    expect(lines.map((line) => line.number), [4, 5, 6]);
  });

  test('toggles inline formatting', () {
    final wrapped = MarkupEditing.toggleInline(
      value('word', start: 0, end: 4),
      '**',
    );
    expect(wrapped.text, '**word**');
    expect(
        wrapped.selection, const TextSelection(baseOffset: 2, extentOffset: 6));
    final unwrapped = MarkupEditing.toggleInline(
      value('**word**', start: 2, end: 6),
      '**',
    );
    expect(unwrapped.text, 'word');
    expect(unwrapped.selection,
        const TextSelection(baseOffset: 0, extentOffset: 4));
    expect(MarkupEditing.toggleInline(value('word', start: 2), '*').text,
        '*word*');
    expect(MarkupEditing.toggleInline(value('', start: 0), '**').selection,
        const TextSelection.collapsed(offset: 2));
    expect(
      MarkupEditing.toggleInline(value('  word  ', start: 0, end: 8), '**')
          .text,
      '  **word**  ',
    );
    expect(
      MarkupEditing.toggleInline(value('**word**', start: 2, end: 6), '*').text,
      '***word***',
    );
  });

  test('toggles line kinds and preserves logical selection', () {
    final added = MarkupEditing.toggleLineKind(
      value('one\ntwo', start: 0, end: 7),
      MarkupLineKind.bullet,
    );
    expect(added.text, '- one\n- two');
    expect(
        added.selection, const TextSelection(baseOffset: 2, extentOffset: 11));
    final removed = MarkupEditing.toggleLineKind(
      value('- one\n- two', start: 2, end: 9),
      MarkupLineKind.bullet,
    );
    expect(removed.text, 'one\ntwo');
    final replaced = MarkupEditing.toggleLineKind(
      value('- one\n- two', start: 2, end: 9),
      MarkupLineKind.numbered,
    );
    expect(replaced.text, '1. one\n2. two');
  });

  test('continues and exits lists', () {
    expect(
      MarkupEditing.continueList(
        value('- one', start: 5),
        value('- one\n', start: 6),
      ).text,
      '- one\n- ',
    );
    expect(
      MarkupEditing.continueList(
        value('3. one', start: 6),
        value('3. one\n', start: 7),
      ).text,
      '3. one\n4. ',
    );
    expect(
      MarkupEditing.continueList(
        value('- ', start: 2),
        value('- \n', start: 3),
      ).text,
      '',
    );
    expect(
      MarkupEditing.continueList(
        value('# heading', start: 9),
        value('# heading\n', start: 10),
      ).text,
      '# heading\n',
    );
    expect(
      MarkupEditing.continueList(
        value('- one', start: 5),
        value('- ones', start: 6),
      ).text,
      '- ones',
    );
  });
}
