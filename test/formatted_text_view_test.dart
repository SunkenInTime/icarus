import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/draggable_widgets/text/formatted_text_view.dart';

void main() {
  testWidgets('renders formatted inline text without markers', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FormattedTextView(
            text: '**bold**',
            style: TextStyle(fontSize: 14),
            hintText: 'Write here...',
          ),
        ),
      ),
    );
    final richText = tester.widget<RichText>(find.byType(RichText));
    expect(richText.text.toPlainText(), 'bold');
    expect(richText.text.style?.fontWeight, isNot(FontWeight.w700));
    bool hasBold(InlineSpan span) {
      if (span is TextSpan && span.style?.fontWeight == FontWeight.w700) {
        return true;
      }
      return span is TextSpan &&
          (span.children ?? const <InlineSpan>[]).any(hasBold);
    }

    expect(hasBold(richText.text), isTrue);
    expect(find.text('**bold**'), findsNothing);
  });

  testWidgets('renders bullet glyph and empty hint', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              FormattedTextView(
                text: '- item',
                style: TextStyle(fontSize: 14),
                hintText: 'Write here...',
              ),
              FormattedTextView(
                text: '',
                style: TextStyle(fontSize: 14),
                hintText: 'Write here...',
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('•'), findsOneWidget);
    expect(find.text('Write here...'), findsOneWidget);
  });
}
