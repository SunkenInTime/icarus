import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/screenshot/caption_export_layout.dart';

const _frame = Size(1920, 1080);
const _mapLeft = 500.0;
const _mapRight = 1420.0;

/// A note on a 40 by 40 item whose upper right corner is at [x], [y].
CaptionExportNote _note(String id, double x, double y) => (
      id: id,
      text: id,
      anchor: Offset(x, y),
      corners: [Offset(x, y + 40), Offset(x - 40, y + 40), Offset(x - 40, y)],
    );

/// The least distance between the middles of two numbers that don't touch.
const _apart = 2 * CaptionExportMetrics.dotRadius + CaptionExportMetrics.dotGap;

void _expectApart(CaptionExportLayout layout) {
  for (final a in layout.entries) {
    for (final b in layout.entries) {
      if (a.number < b.number) {
        expect(
          (a.dot - b.dot).distance,
          greaterThanOrEqualTo(_apart),
          reason: 'numbers ${a.number} and ${b.number}',
        );
      }
    }
  }
}

CaptionExportLayout _layout(
  List<CaptionExportNote> notes, {
  List<Rect> obstacles = const [],
  double height = 120,
}) =>
    layoutExportCaptions(
      notes: notes,
      frame: _frame,
      mapLeft: _mapLeft,
      mapRight: _mapRight,
      obstacles: obstacles,
      measure: (_, __) => height,
    );

void main() {
  group('a video transition', () {
    const total = Duration(milliseconds: 420);

    test('holds the page being left at its first frame', () {
      final fades = captionFades(Duration.zero, total);
      expect(fades.from, 1);
      expect(fades.to, 0);
    });

    test('shows neither page in the middle', () {
      final fades = captionFades(const Duration(milliseconds: 210), total);
      expect(fades.from, 0);
      expect(fades.to, 0);
    });

    test('has the next page fully in at its last frame', () {
      final fades = captionFades(total, total);
      expect(fades.from, 0);
      expect(fades.to, 1);
    });

    test('is halfway through each fade 75 ms in from either end', () {
      expect(
        captionFades(const Duration(milliseconds: 75), total).from,
        closeTo(0.5, 0.001),
      );
      expect(
        captionFades(const Duration(milliseconds: 345), total).to,
        closeTo(0.5, 0.001),
      );
    });
  });

  test('a page reads at about 20 characters a second', () {
    final layout = _layout([
      (id: 'a', text: 'x' * 100, anchor: const Offset(700, 200), corners: []),
      (id: 'b', text: 'y' * 101, anchor: const Offset(1200, 200), corners: []),
    ]);

    expect(captionReadSeconds(layout), 11);
  });

  test('nothing to print fits', () {
    final layout = _layout(const []);
    expect(layout.fits, isTrue);
    expect(layout.entries, isEmpty);
  });

  test('a note goes to the margin on its side of the map', () {
    final layout = _layout([_note('left', 700, 300), _note('right', 1200, 300)]);

    expect(layout.entries[0].id, 'left');
    expect(layout.entries[0].card.right, lessThanOrEqualTo(_mapLeft));
    expect(layout.entries[1].id, 'right');
    expect(layout.entries[1].card.left, greaterThanOrEqualTo(_mapRight));
  });

  test('numbers run down the left margin, then the right', () {
    final layout = _layout([
      _note('right top', 1200, 100),
      _note('left low', 700, 800),
      _note('left high', 700, 200),
    ]);

    expect(
      [for (final e in layout.entries) '${e.number} ${e.id}'],
      ['1 left high', '2 left low', '3 right top'],
    );
  });

  test('a card sits near its item', () {
    final entry = _layout([_note('a', 700, 600)]).entries.single;

    expect(entry.card.center.dy, closeTo(600, 1));
    expect(entry.dot, const Offset(700, 600));
  });

  test('a card steps past what is already in the margin', () {
    const page = Rect.fromLTWH(28, 540, 300, 120);

    final card = _layout(
      [_note('a', 700, 600)],
      obstacles: [page],
    ).entries.single.card;

    expect(card.overlaps(page), isFalse);
  });

  test('cards in a column never overlap', () {
    final layout = _layout([
      for (var i = 0; i < 5; i++) _note('note $i', 700, 300.0 + i),
    ]);

    expect(layout.fits, isTrue);
    final cards = layout.entries.map((e) => e.card).toList();
    for (var i = 1; i < cards.length; i++) {
      expect(cards[i].top, greaterThanOrEqualTo(cards[i - 1].bottom));
    }
  });

  test('notes low on the map pack upward rather than give up', () {
    final layout = _layout([
      for (var i = 0; i < 6; i++) _note('note $i', 700, 1000),
    ]);

    expect(layout.fits, isTrue);
    expect(layout.entries.last.card.bottom, lessThanOrEqualTo(1080));
  });

  test('a full column sends its last notes to the other margin', () {
    final layout = _layout(
      [for (var i = 0; i < 8; i++) _note('note $i', 700, 100.0 + i * 100)],
      height: 200,
    );

    expect(layout.fits, isTrue);
    final across = layout.entries.where((e) => e.card.left >= _mapRight);
    expect(across, isNotEmpty);
    expect(
      across.map((e) => e.id),
      everyElement(isIn(['note 4', 'note 5', 'note 6', 'note 7'])),
    );
  });

  test('a page that fills both margins does not fit, and drops nothing', () {
    final layout = _layout(
      [for (var i = 0; i < 12; i++) _note('note $i', 700, 300)],
      height: 300,
    );

    expect(layout.fits, isFalse);
    expect(layout.entries, isEmpty);
  });

  test('a full right margin hands notes to a left margin with room', () {
    final layout = _layout(
      [for (var i = 0; i < 8; i++) _note('note $i', 1200, 100.0 + i * 100)],
      height: 200,
    );

    expect(layout.fits, isTrue);
    expect(layout.entries.where((e) => e.card.right <= _mapLeft), isNotEmpty);
  });

  test('one side full and the other nearly full does not fit, and stops', () {
    final layout = _layout(
      [
        for (var i = 0; i < 4; i++) _note('left $i', 700, 300),
        for (var i = 0; i < 3; i++) _note('right $i', 1200, 300),
      ],
      height: 320,
    );

    expect(layout.fits, isFalse);
  });

  test('a note too tall for any margin does not fit', () {
    expect(_layout([_note('a', 700, 300)], height: 1100).fits, isFalse);
  });

  test('a map with no room beside it does not fit', () {
    final layout = layoutExportCaptions(
      notes: [_note('a', 700, 300)],
      frame: _frame,
      mapLeft: 20,
      mapRight: 1900,
      obstacles: const [],
      measure: (_, __) => 100,
    );

    expect(layout.fits, isFalse);
  });

  group('numbers on the map', () {
    test('sit on the corner the marker hangs on when it is free', () {
      final layout = _layout([_note('a', 700, 300), _note('b', 760, 300)]);

      expect(layout.entries[0].dot, const Offset(700, 300));
      expect(layout.entries[1].dot, const Offset(760, 300));
    });

    test('of two items side by side cover neither', () {
      // Two smokes dropped a little apart, as on the canvas.
      final notes = [_note('first', 1300, 580), _note('second', 1312, 592)];
      final layout = _layout(notes);

      _expectApart(layout);
      expect(layout.entries[0].dot, notes[0].anchor);
      expect(
        [notes[1].anchor, ...notes[1].corners],
        contains(layout.entries[1].dot),
        reason: 'the second number stays on a corner of its own item',
      );
    });

    test('of a row of small items cover none', () {
      final layout = _layout([
        for (var i = 0; i < 4; i++) _note('item $i', 700.0 + 20 * i, 400),
      ]);

      _expectApart(layout);
    });

    test('of a stack of items on one spot cover none', () {
      final layout = _layout([
        for (var i = 0; i < 9; i++) _note('item $i', 900, 500),
      ]);

      expect(layout.entries, hasLength(9));
      _expectApart(layout);
    });

    test('stay inside the frame', () {
      final layout = _layout([
        for (var i = 0; i < 3; i++) _note('item $i', 1910, 5),
      ]);

      _expectApart(layout);
      const radius = CaptionExportMetrics.dotRadius;
      for (final entry in layout.entries) {
        expect(entry.dot.dx, inInclusiveRange(radius, _frame.width - radius));
        expect(entry.dot.dy, inInclusiveRange(radius, _frame.height - radius));
      }
    });
  });
}
