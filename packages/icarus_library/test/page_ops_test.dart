import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final autoNamed = [
    page('page-a', sortIndex: 0, isAutoNamed: true),
    page('page-b', sortIndex: 1, isAutoNamed: true),
    page('page-c', sortIndex: 2, name: 'Retake', isAutoNamed: false),
  ];

  List<String> namesInOrder(StrategyRowSet rows) {
    final live = rows.pages.whereType<LivePage>().toList()
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return [for (final page in live) page.name];
  }

  test(
    'adding a page in the middle renumbers the auto-named pages after it',
    () {
      final session = Session(strategyRows(pages: autoNamed));
      session.apply(
        const PageAddOp(
          opId: 'add',
          pagePublicId: 'page-new',
          name: 'Page 2',
          isAutoNamed: true,
          sortIndex: 1,
          expectedStrategyRevision: 1,
        ),
      );
      expect(namesInOrder(session.rows), [
        'Page 1',
        'Page 2',
        'Page 3',
        'Retake',
      ]);
      expect(session.rows.page('page-b')!.revision, 2);
      expect(session.rows.page('page-a')!.revision, 1);
      expect(session.rows.strategy.revision, 2);
      expect(session.rows.settingsOf('page-new')!.revision, 1);
    },
  );

  test('a page added past the end lands last', () {
    final session = Session(strategyRows(pages: autoNamed));
    session.apply(
      const PageAddOp(
        opId: 'add',
        pagePublicId: 'page-new',
        name: 'Last',
        sortIndex: 99,
        expectedStrategyRevision: 1,
      ),
    );
    expect(session.rows.page('page-new')!.sortIndex, 3);
  });

  test('a deleted page goes to the trash with its content kept', () {
    final agent = element('jett', pageId: 'page-b');
    final session = Session(strategyRows(pages: autoNamed, elements: [agent]));
    final result = session.apply(
      const PageDeleteOp(
        opId: 'delete',
        pagePublicId: 'page-b',
        expectedStrategyRevision: 1,
      ),
    );
    final trashed = session.rows.page('page-b')!;
    expect(trashed, isA<TrashedPage>());
    expect(trashed.sortIndex, 1);
    expect(trashed.revision, 1);
    expect(session.rows.element('jett'), agent);
    expect(namesInOrder(session.rows), ['Page 1', 'Retake']);
    expect(result.undo, const UndoByRestoringPage('page-b'));
  });

  test('editing content on a page in the trash fails', () {
    final session = Session(
      strategyRows(
        pages: [
          page('page-a', sortIndex: 0),
          page('page-b', sortIndex: 1, deleted: true),
        ],
        elements: [element('jett', pageId: 'page-b')],
      ),
    );
    expect(
      refused(
        session.attempt(
          const ElementReorderOp(
            opId: 'reorder',
            elementPublicId: 'jett',
            pagePublicId: 'page-b',
            sortIndex: 3,
            expectedElementRevision: 1,
          ),
        ),
      ),
      const Failed(FailureCode.pageDeleted),
    );
  });

  test('the last page cannot be deleted', () {
    final session = Session(
      strategyRows(pages: [page('page-a', sortIndex: 0)]),
    );
    expect(
      refused(
        session.attempt(
          const PageDeleteOp(
            opId: 'delete',
            pagePublicId: 'page-a',
            expectedStrategyRevision: 1,
          ),
        ),
      ),
      const Failed(FailureCode.invalidOp),
    );
  });

  test('a page op made on an old strategy revision is refused', () {
    final session = Session(strategyRows(pages: autoNamed));
    expect(
      refused(
        session.attempt(
          const PageReorderOp(
            opId: 'reorder',
            pagePublicId: 'page-a',
            sortIndex: 2,
            expectedStrategyRevision: 7,
          ),
        ),
      ),
      const Rejected(RejectionReason.revisionMismatch),
    );
  });

  test('moving a page and undoing it puts every page back as it was', () {
    final before = strategyRows(pages: autoNamed);
    final session = Session(before);
    final moved = session.apply(
      const PageReorderOp(
        opId: 'reorder',
        pagePublicId: 'page-a',
        sortIndex: 2,
        expectedStrategyRevision: 1,
      ),
    );
    expect(namesInOrder(session.rows), ['Page 1', 'Retake', 'Page 3']);
    session.apply(undoOp(moved));
    expect(namesInOrder(session.rows), namesInOrder(before));
    expect(
      [for (final page in session.rows.pages) page.sortIndex],
      [for (final page in before.pages) page.sortIndex],
    );
  });

  test('renaming a page and undoing it restores the name', () {
    final session = Session(strategyRows(pages: autoNamed));
    final renamed = session.apply(
      const PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-c',
        name: 'Execute',
        expectedPageRevision: 1,
      ),
    );
    expect(session.rows.page('page-c')!.name, 'Execute');
    session.apply(undoOp(renamed));
    expect(session.rows.page('page-c')!.name, 'Retake');
  });

  test(
    'a page added as a copy holds the live content of the page it copies',
    () {
      final kept = element('jett', pageId: 'page-a', sortIndex: 2);
      final gone = deletedElement('sage', pageId: 'page-a');
      final session = Session(
        strategyRows(
          pages: [page('page-a', sortIndex: 0)],
          elements: [kept, gone],
        ),
      );
      final result = session.apply(
        const PageAddOp(
          opId: 'copy',
          pagePublicId: 'page-copy',
          sortIndex: 1,
          expectedStrategyRevision: 1,
          copyContentFromPagePublicId: 'page-a',
        ),
      );
      final copied = session.rows.elementsOn('page-copy').toList();
      expect(copied, hasLength(1));
      final copy = copied.single as LiveElement;
      expect(copy.publicId, startsWith('jett~cp1~'));
      expect(copy.sortIndex, 2);
      expect(copy.revision, 1);
      expect(copy.payload.data['id'], copy.publicId);
      expect(session.rows.element('jett'), kept);
      expect(
        result.writes.whereType<RowAdded>().map((write) => write.key),
        containsAll([const PageKey('page-copy'), ElementKey(copy.publicId)]),
      );
    },
  );

  test('changing settings that were never set cannot be undone by an op', () {
    final session = Session(
      strategyRows(
        pages: [page('page-a', sortIndex: 0)],
        pageSettings: [
          const PageSettingsRow(pagePublicId: 'page-a', revision: 1),
        ],
      ),
    );
    final result = session.apply(
      const PageSettingsPatchOp(
        opId: 'settings',
        pagePublicId: 'page-a',
        settings: defaultSettings,
        expectedPageSettingsRevision: 1,
      ),
    );
    expect(result.undo, isA<UndoUnavailable>());
    expect(session.rows.settingsOf('page-a')!.settings, defaultSettings);
  });

  test('clearing the theme and undoing it brings the theme back', () {
    final themed = StrategyRowSet(
      strategy: const StrategyRow(
        publicId: strategyId,
        name: 'Retake B',
        mapData: 'ascent',
        themeProfileId: 'ember',
        revision: 3,
      ),
      pages: [page('page-a', sortIndex: 0)],
    );
    final session = Session(themed);
    final cleared = session.apply(
      const StrategyPatchOp(
        opId: 'clear',
        themeProfile: ClearValue(),
        expectedStrategyRevision: 3,
      ),
    );
    expect(session.rows.strategy.themeProfileId, isNull);
    expect(session.rows.strategy.revision, 4);
    session.apply(undoOp(cleared));
    expect(session.rows.strategy.themeProfileId, 'ember');
  });

  test(
    'pages that share a place are ordered by id, as the server orders them',
    () {
      final session = Session(
        strategyRows(
          pages: [
            page('z', sortIndex: 0, name: 'z'),
            page('a', sortIndex: 0, name: 'a'),
          ],
        ),
      );
      session.apply(
        const PageAddOp(
          opId: 'add',
          pagePublicId: 'n',
          name: 'n',
          sortIndex: 2,
          expectedStrategyRevision: 1,
        ),
      );
      expect(session.rows.page('a')!.sortIndex, 0);
      expect(session.rows.page('a')!.revision, 1);
      expect(session.rows.page('z')!.sortIndex, 1);
      expect(session.rows.page('z')!.revision, 2);
    },
  );

  test(
    'the same copy op gives the same copied rows every time it is applied',
    () {
      final rows = strategyRows(
        pages: [page('page-a', sortIndex: 0)],
        elements: [element('jett', pageId: 'page-a')],
      );
      const copy = PageAddOp(
        opId: 'copy-op',
        pagePublicId: 'page-copy',
        sortIndex: 1,
        expectedStrategyRevision: 1,
        copyContentFromPagePublicId: 'page-a',
      );
      final first = applied(applyOp(rows, copy));
      final second = applied(applyOp(rows, copy));
      expect(second.rows.toList(), first.rows.toList());
      expect(second.undo, first.undo);
      final other = applied(
        applyOp(
          rows,
          const PageAddOp(
            opId: 'another-copy-op',
            pagePublicId: 'page-copy',
            sortIndex: 1,
            expectedStrategyRevision: 1,
            copyContentFromPagePublicId: 'page-a',
          ),
        ),
      );
      final ids = {for (final row in first.rows) row.key};
      final otherIds = {for (final row in other.rows) row.key};
      expect(ids.difference(otherIds).whereType<ElementKey>(), hasLength(1));
    },
  );

  test('a page deleted here waits in the trash without a time', () {
    final session = Session(strategyRows());
    session.apply(
      const PageDeleteOp(
        opId: 'delete',
        pagePublicId: 'page-b',
        expectedStrategyRevision: 1,
      ),
    );
    expect(session.rows.page('page-b'), isA<PendingTrashedPage>());
  });

  test('a page the server trashed says when and who', () {
    Map<String, Object?> trashed(Object? deletedBy) => {
      'publicId': 'page-b',
      'strategyPublicId': strategyId,
      'name': 'Page 2',
      'sortIndex': 1,
      'isAttack': true,
      'revision': 3,
      'deleted': true,
      'deletedAt': 1700000000000,
      'deletedBy': deletedBy,
    };
    for (final (json, deleter) in [
      (trashed('you'), const DeletedByYou()),
      (trashed({'name': 'Mia'}), const DeletedByName('Mia')),
      (trashed('unknown'), const DeleterUnknown()),
    ]) {
      final row = readValue(PageRow.decode(json));
      expect(row, isA<ConfirmedTrashedPage>());
      final confirmed = row as ConfirmedTrashedPage;
      expect(confirmed.deletedBy, deleter);
      expect(confirmed.deletedAt.millisecondsSinceEpoch, 1700000000000);
      expect(row.toJson(), json);
    }
    expect(PageRow.decode(trashed(null)), isA<CouldNotRead<PageRow>>());
  });
}
