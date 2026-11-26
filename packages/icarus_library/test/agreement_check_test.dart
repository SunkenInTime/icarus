import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';

final rows = initialRows();

Shown shownOfRows() {
  var shown = Shown.nothing
      .taken(headerReadOf(rows), started: ReadStart.beforeAnyRead)
      .shown;
  for (final page in rows.pages) {
    shown = shown
        .taken(
          pageReadOf(rows, page.publicId),
          started: ReadStart.beforeAnyRead,
        )
        .shown;
  }
  return shown;
}

StoredPage stored(
  String page, {
  List<ElementRow>? elements,
  List<String> damaged = const [],
}) => (
  elements: elements ?? rows.elementsOn(page).toList(),
  lineupGroups: rows.lineupGroupsOn(page).toList(),
  damaged: damaged,
);

List<String> problemsWith(Map<String, StoredPage> content) => agreementProblems(
  strategy: rows.strategy,
  pages: rows.pages.toList(),
  settings: {for (final row in rows.settings) row.pagePublicId: row},
  damaged: const [],
  content: content,
  shown: shownOfRows(),
);

ElementRow e1() => rows.element('e1')!;

void main() {
  test('a store holding what the queue holds has no problem', () {
    expect(
      problemsWith({'page-a': stored('page-a'), 'page-b': stored('page-b')}),
      isEmpty,
    );
  });

  test('a damaged row where the queue holds a readable one is named', () {
    final problems = problemsWith({
      'page-a': stored(
        'page-a',
        elements: [rows.element('e2')!],
        damaged: [elementName('page-a', 'e1')],
      ),
      'page-b': stored('page-b'),
    });
    expect(
      problems,
      contains('a damaged copy of ElementTarget(e1) is held on page-a'),
    );
  });

  test('an item held on two pages is named, readable or damaged', () {
    expect(
      problemsWith({
        'page-a': stored('page-a'),
        'page-b': stored(
          'page-b',
          elements: [...rows.elementsOn('page-b'), e1()],
        ),
      }),
      contains('ElementTarget(e1) is held on page-a and on page-b here'),
    );
    expect(
      problemsWith({
        'page-a': stored('page-a'),
        'page-b': stored('page-b', damaged: [elementName('page-b', 'e1')]),
      }),
      contains('a damaged copy of ElementTarget(e1) is held on page-b'),
    );
  });

  test('an item at the same revision, life and digest on another page is '
      'named', () {
    expect(
      problemsWith({
        'page-a': stored('page-a', elements: [rows.element('e2')!]),
        'page-b': stored(
          'page-b',
          elements: [...rows.elementsOn('page-b'), e1()],
        ),
      }),
      contains(
        'ElementTarget(e1) is on page-b here and on page-a in the queue',
      ),
    );
  });
}
