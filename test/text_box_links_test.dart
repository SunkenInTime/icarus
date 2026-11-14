import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/duplicate_drag_modifier_provider.dart';
import 'package:icarus/widgets/draggable_widgets/text/formatted_text_view.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_links.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_markup.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';
import 'package:icarus/widgets/text_link_read_region.dart';
// Only the test swaps the platform's launcher; the app uses url_launcher.
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _RecordingLauncher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

const _clip = 'https://www.youtube.com/shorts/H36dywKYmI4';
const _note = 'Plant default, then watch:\n$_clip';

List<TextPiece> _pieces(String line) => textPieces(parseMarkup(line).single);

/// Where the text on screen draws [words]: the middle of their first line.
Offset _wordsPoint(WidgetTester tester, String words) {
  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.byType(RichText),
  )) {
    final at = paragraph.text.toPlainText().indexOf(words);
    if (at < 0) continue;
    final box = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: at, extentOffset: at + words.length),
        )
        .first;
    return paragraph.localToGlobal(box.toRect().center);
  }
  throw StateError('"$words" is not drawn');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CoordinateSystem(playAreaSize: const Size(1920, 1080));

  late _RecordingLauncher launcher;
  late UrlLauncherPlatform realLauncher;
  setUp(() {
    realLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher = _RecordingLauncher();
  });
  tearDown(() => UrlLauncherPlatform.instance = realLauncher);

  group('links in a line', () {
    test('a line without one is drawn in the same stretches as before', () {
      for (final line in [
        'Plant default',
        '**Retake** through _market_ now',
        '***both*** and * a lone star',
        'snake_case and 2 * 3 * 4',
      ]) {
        final shown = [
          for (final inline in parseMarkup(line).single.inlines)
            if (!inline.isMarker) (inline.raw, inline.bold, inline.italic),
        ];
        expect(
          [for (final p in _pieces(line)) (p.text, p.bold, p.italic)],
          shown,
          reason: line,
        );
        expect(_pieces(line).every((piece) => piece.uri == null), isTrue);
      }
    });

    test('a link inside bold text keeps its weight and ends at the marker', () {
      final pieces = _pieces('**Watch $_clip**');
      expect(pieces.map((piece) => piece.text), ['Watch ', _clip]);
      expect(pieces.every((piece) => piece.bold), isTrue);
      expect(pieces.last.uri, Uri.parse(_clip));
    });

    test('an address holding markup characters is shown and opened as typed',
        () {
      const typed = 'https://youtu.be/a_b_c?utm_source=x&utm_medium=y';
      final pieces = _pieces('Clip: $typed.');
      expect(pieces.map((piece) => piece.text).join(), 'Clip: $typed.');
      final link = pieces.singleWhere((piece) => piece.uri != null);
      expect(link.text, typed);
      expect(link.uri, Uri.parse(typed));
    });

    test('only web addresses become links', () {
      const text = 'javascript:alert(1) file:///C:/x.exe icarus://open '
          'mailto:a@b.co ftp://files.example/x data:text/html,hi '
          'https://user:pw@evil.example';
      expect(textLinks(text), isEmpty);
      expect(
        textLinks('WWW.Example.com HTTP://example.org youtu.be/x')
            .map((uri) => uri.scheme),
        everyElement(anyOf('http', 'https')),
      );
    });

    test('the links of a text are listed once each, in order', () {
      expect(textLinks('$_clip\n- www.twitch.tv/videos/1\n# $_clip'), [
        Uri.parse(_clip),
        Uri.parse('https://www.twitch.tv/videos/1'),
      ]);
    });
  });

  Widget textBox({bool picture = false}) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: FormattedTextView(
              text: _note,
              style: const TextStyle(fontSize: 16),
              hintText: '',
              links: !picture,
            ),
          ),
        ),
      );

  List<TextLinkSpan> linkSpans(WidgetTester tester) {
    final spans = <TextLinkSpan>[];
    for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
      text.text.visitChildren((span) {
        if (span is TextLinkSpan) spans.add(span);
        return true;
      });
    }
    return spans;
  }

  testWidgets('a link is drawn as one, and as plain text in a picture',
      (tester) async {
    await tester.pumpWidget(textBox());
    final link = linkSpans(tester).single;
    expect(link.text, _clip);
    expect(link.uri, Uri.parse(_clip));
    expect(link.style?.color, Settings.accentInk);
    expect(link.style?.decoration, TextDecoration.underline);
    final drawn = tester.getSize(find.byType(FormattedTextView));

    await tester.pumpWidget(textBox(picture: true));
    expect(linkSpans(tester), isEmpty);
    expect(find.textContaining(_clip, findRichText: true), findsOneWidget);
    // The same box, so a picture puts everything where the canvas has it.
    expect(tester.getSize(find.byType(FormattedTextView)), drawn);
  });

  /// A text box someone can edit, in an app that keeps its record of Ctrl
  /// and Cmd as GlobalShortcuts does.
  Widget editable(ProviderContainer container) {
    bool record(KeyEvent event) {
      container.read(duplicateDragModifierProvider.notifier).handleKeyEvent(
            event,
          );
      return false;
    }

    HardwareKeyboard.instance.addHandler(record);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(record));
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: TextWidget(id: 'note', text: _note, size: 400, fontSize: 16),
          ),
        ),
      ),
    );
  }

  testWidgets('a click on a link edits the text and opens nothing',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(editable(container));
    await tester.tapAt(_wordsPoint(tester, 'https://'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(launcher.opened, isEmpty);
  });

  testWidgets('a key the window lost while held opens nothing on the way back',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(editable(container));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    // The browser took the keyboard, and the key came up over there: the app
    // forgets it, as GlobalShortcuts does when the window loses the keyboard.
    container.read(duplicateDragModifierProvider.notifier).clear();
    expect(HardwareKeyboard.instance.isControlPressed, isTrue);

    await tester.tapAt(_wordsPoint(tester, 'https://'));
    await tester.pump();
    expect(launcher.opened, isEmpty);
    expect(find.byType(TextField), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('a click on a link with Ctrl held opens it and edits nothing',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(editable(container));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(_wordsPoint(tester, 'https://'));
    await tester.pump();
    expect(launcher.opened, [_clip]);
    expect(find.byType(TextField), findsNothing);

    // Beside the link it is a click like any other.
    await tester.tapAt(_wordsPoint(tester, 'Plant default'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(launcher.opened, [_clip]);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a reader opens a link with a click, never with a drag',
      (tester) async {
    final items = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                IgnorePointer(
                  child: Stack(
                    key: items,
                    children: const [
                      TextWidget(
                        id: 'note',
                        text: _note,
                        size: 400,
                        fontSize: 16,
                      ),
                    ],
                  ),
                ),
                Positioned.fill(child: TextLinkReadRegion(items: items)),
              ],
            ),
          ),
        ),
      ),
    );
    final link = _wordsPoint(tester, 'https://');

    await tester.dragFrom(link, const Offset(60, 30));
    await tester.tapAt(_wordsPoint(tester, 'Plant default'));
    await tester.tapAt(link, buttons: kSecondaryButton);
    await tester.pump();
    expect(launcher.opened, isEmpty);

    await tester.tapAt(link);
    await tester.pump();
    expect(launcher.opened, [_clip]);
    expect(find.byType(TextField), findsNothing);
  });
}
