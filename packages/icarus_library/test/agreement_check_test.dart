import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'support.dart';
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

List<String> problemsWith(
  Map<String, StoredPage> content, {
  StrategyRow? strategy,
  List<PageRow>? pages,
  Map<String, PageSettingsRow>? settings,
  List<String> damaged = const [],
  Shown? shown,
}) => agreementProblems(
  strategy: strategy ?? rows.strategy,
  pages: pages ?? rows.pages.toList(),
  settings:
      settings ?? {for (final row in rows.settings) row.pagePublicId: row},
  damaged: damaged,
  content: content,
  shown: shown ?? shownOfRows(),
);

Map<String, StoredPage> everyPage() => {
  'page-a': stored('page-a'),
  'page-b': stored('page-b'),
};

LiveElement e1() => rows.element('e1')! as LiveElement;

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

  test(
    'a damaged item the queue does not hold is named by its page and key',
    () {
      expect(
        problemsWith({
          'page-a': stored('page-a', damaged: [elementName('page-a', 'e9')]),
          'page-b': stored('page-b'),
        }),
        contains(
          'a damaged row is held on page-a as ${elementName('page-a', 'e9')}',
        ),
      );
    },
  );

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

  test('a damaged page or settings row held here is named', () {
    expect(
      problemsWith(everyPage(), damaged: [pageName('page-b')]),
      contains('a damaged row is held here as ${pageName('page-b')}'),
    );
  });

  test('a page the queue holds both live and trashed is named', () {
    final shown = shownOfRows();
    final both = shown
        .taken(
          headerReadOf(
            rows.withRows([
              page('page-b', sortIndex: 1, deleted: true, revision: 2),
            ]),
          ),
          started: ReadStart.beforeAnyRead,
        )
        .shown;
    final wrong = Shown(
      strategy: both.strategy,
      pages: {...both.pages, ...shown.pages},
      trashed: both.trashed,
      settings: both.settings,
      content: both.content,
      rows: both.rows,
      list: both.list,
      pageReads: both.pageReads,
      goneThisSession: both.goneThisSession,
      highest: both.highest,
      fresh: both.fresh,
      listTaken: both.listTaken,
      pagesTaken: both.pagesTaken,
      fence: both.fence,
    );
    expect(
      problemsWith(everyPage(), shown: wrong),
      contains('the queue holds {page-b} as live and trashed'),
    );
  });

  test('a page held twice here is named', () {
    expect(
      problemsWith(everyPage(), pages: [...rows.pages, rows.page('page-b')!]),
      contains('page page-b is held twice here'),
    );
  });

  test('the strategy row at another version is named', () {
    expect(
      problemsWith(everyPage(), strategy: strategyRow(revision: 9)),
      contains('the strategy row is at another version here'),
    );
  });

  test('a page row at another version is named', () {
    expect(
      problemsWith(
        everyPage(),
        pages: [
          rows.page('page-a')!,
          page('page-b', sortIndex: 1, revision: 5),
        ],
      ),
      contains(startsWith('page page-b is ')),
    );
  });

  test('settings at another version are named', () {
    final revised = ReadablePageSettings(
      pagePublicId: 'page-a',
      settings: defaultSettings,
      revision: 7,
      unknownFields:
          (rows.settingsOf('page-a')! as ReadablePageSettings).unknownFields,
    );
    expect(
      problemsWith(
        everyPage(),
        settings: {
          for (final row in rows.settings) row.pagePublicId: row,
          'page-a': revised,
        },
      ),
      contains(startsWith('the settings of page-a are ')),
    );
  });

  test('an item on its page at another version, or with other contents at '
      'the same version, is named', () {
    final older = LiveElement(
      publicId: 'e1',
      pagePublicId: 'page-a',
      payload: e1().payload,
      sortIndex: e1().sortIndex,
      revision: 7,
      unknownFields: e1().unknownFields,
    );
    final moved = LiveElement(
      publicId: 'e1',
      pagePublicId: 'page-a',
      payload: agentPayload('e1', {
        'position': {'dx': 99, 'dy': 0},
      }),
      sortIndex: e1().sortIndex,
      revision: e1().revision,
      unknownFields: e1().unknownFields,
    );
    for (final changed in [older, moved]) {
      expect(
        problemsWith({
          'page-a': stored('page-a', elements: [changed, rows.element('e2')!]),
          'page-b': stored('page-b'),
        }),
        contains(startsWith('ElementTarget(e1) is ')),
      );
    }
  });
}
