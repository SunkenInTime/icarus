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
      expect(session.pageAt('page-b').revision, 2);
      expect(session.pageAt('page-a').revision, 1);
      expect(session.rows.strategy.revision, 2);
      expect(session.settingsAt('page-new').revision, 1);
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
    expect(session.pageAt('page-new').sortIndex, 3);
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
    final trashed = session.pageAt('page-b');
    expect(trashed, isA<TrashedPage>());
    expect(trashed.sortIndex, 1);
    expect(trashed.revision, 1);
    expect(session.rows.element('jett'), agent);
    expect(namesInOrder(session.rows), ['Page 1', 'Retake']);
    expect(session.buildUndoOf(result), isA<RestoreFromTrash>());
    expect(
      (session.buildUndoOf(result) as RestoreFromTrash).pagePublicId,
      'page-b',
    );
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

  test('the last live page cannot be deleted beside an unreadable page', () {
    final session = Session(
      strategyRows(
        pages: [
          page('page-a', sortIndex: 0),
          UnreadablePage(
            publicId: 'page-held',
            strategyPublicId: 'strategy-1',
            sortIndex: 1,
            trashed: false,
            stored: const {'publicId': 'page-held', 'sortIndex': 1},
            problem: 'from a newer build',
          ),
        ],
      ),
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

  test('settings and palettes keep a copy of the fields they were given', () {
    final extra = <String, Object?>{'glow': 1};
    final settings = PageSettings.keeping(
      agentSize: 1,
      abilitySize: 1,
      useNeutralTeamColors: false,
      unknownFields: extra,
    );
    final palette = ThemePalette.keeping(
      base: '#000',
      detail: '#111',
      highlight: '#222',
      unknownFields: extra,
    );
    extra['glow'] = 2;
    expect(settings.toJson()['glow'], 1);
    expect(palette.toJson()['glow'], 1);
    expect(settings.unknownFields, isNot(isA<Map<Object?, Object?>>()));
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
    session.apply(session.undo(moved));
    expect(namesInOrder(session.rows), namesInOrder(before));
    expect(
      [
        for (final page in session.rows.pages)
          (page as ReadablePageRow).sortIndex,
      ],
      [for (final page in before.pages) (page as ReadablePageRow).sortIndex],
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
    expect(session.pageAt('page-c').name, 'Execute');
    session.apply(session.undo(renamed));
    expect(session.pageAt('page-c').name, 'Retake');
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

  test(
    'changing settings that were never set is undone by writing the defaults the page showed',
    () {
      final session = Session(
        strategyRows(
          pages: [page('page-a', sortIndex: 0)],
          pageSettings: [
            ReadablePageSettings(pagePublicId: 'page-a', revision: 1),
          ],
        ),
      );
      const larger = PageSettings(
        agentSize: 2,
        abilitySize: 1,
        useNeutralTeamColors: false,
      );
      final result = session.apply(
        const PageSettingsPatchOp(
          opId: 'settings',
          pagePublicId: 'page-a',
          settings: larger,
          expectedPageSettingsRevision: 1,
        ),
      );
      expect(
        session.buildUndoOf(result),
        isA<UndoReady>().having(
          (ready) => ready.op,
          'op',
          isA<PageSettingsPatchOp>()
              .having((op) => op.settings, 'settings', defaultSettings)
              .having((op) => op.expectedPageSettingsRevision, 'revision', 2),
        ),
      );
      session.apply(session.undo(result));
      expect(session.settingsAt('page-a').settings, defaultSettings);
    },
  );

  test(
    'writing exactly the defaults to settings that were never set leaves nothing to undo',
    () {
      final session = Session(
        strategyRows(
          pages: [page('page-a', sortIndex: 0)],
          pageSettings: [
            ReadablePageSettings(pagePublicId: 'page-a', revision: 1),
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
      expect(session.buildUndoOf(result), isA<NothingToUndo>());
    },
  );

  test('clearing the theme and undoing it brings the theme back', () {
    final themed = StrategyRowSet(
      strategy: strategyRow(themeProfileId: 'ember', revision: 3),
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
    session.apply(session.undo(cleared));
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
      expect(session.pageAt('a').sortIndex, 0);
      expect(session.pageAt('a').revision, 1);
      expect(session.pageAt('z').sortIndex, 1);
      expect(session.pageAt('z').revision, 2);
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
      expect(
        (second.undo as RemoveAddedPage).pagePublicId,
        (first.undo as RemoveAddedPage).pagePublicId,
      );
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

  test('a copy never takes the id of a row the strategy already has', () {
    final rows = strategyRows(elements: [element('jett', pageId: 'page-a')]);
    const copy = PageAddOp(
      opId: 'copy-op',
      pagePublicId: 'page-copy',
      sortIndex: 2,
      expectedStrategyRevision: 1,
      copyContentFromPagePublicId: 'page-a',
    );
    String copiedId(StrategyRowSet rows) => applied(
      applyOp(rows, copy),
    ).rows.whereType<ElementRow>().single.publicId;
    final firstChoice = copiedId(rows);
    final squatter = element(firstChoice, pageId: 'page-b');
    final crowded = rows.withRows([squatter]);
    final copied = applied(applyOp(crowded, copy));
    final copiedElement = copied.rows.whereType<ElementRow>().single;
    expect(copiedElement.publicId, isNot(firstChoice));
    expect(copiedElement.publicId, startsWith('jett~cp1~'));
    expect(crowded.withRows(copied.rows).element(firstChoice), squatter);
  });

  test('a copied lineup group links the copies of its own spots', () {
    final rows = strategyRows(
      lineupGroups: [
        LiveLineupGroup(
          strategyPublicId: strategyId,
          publicId: 'g1',
          pagePublicId: 'page-a',
          payload: LineupGroupPayload(
            payloadVersion: 1,
            data: {
              'id': 'g1',
              'origins': [
                {
                  'id': 'o1',
                  'agent': {'lineUpID': 'o1'},
                },
              ],
              'landings': [
                {
                  'id': 'l1',
                  'ability': {'lineUpID': 'l1'},
                },
              ],
              'links': [
                {'id': 'k1', 'originId': 'o1', 'landingId': 'l1'},
              ],
            },
          ),
          sortIndex: 0,
          revision: 1,
        ),
      ],
    );
    final copied = applied(
      applyOp(
        rows,
        const PageAddOp(
          opId: 'copy-op',
          pagePublicId: 'page-copy',
          sortIndex: 2,
          expectedStrategyRevision: 1,
          copyContentFromPagePublicId: 'page-a',
        ),
      ),
    ).rows.whereType<LiveLineupGroup>().single;
    final data = copied.payload.data.toJson();
    final origin = (data['origins']! as List<Object?>).single! as Map;
    final landing = (data['landings']! as List<Object?>).single! as Map;
    final link = (data['links']! as List<Object?>).single! as Map;
    expect(copied.publicId, startsWith('g1~cp1~'));
    expect(data['id'], copied.publicId);
    expect(link['originId'], origin['id']);
    expect(link['landingId'], landing['id']);
    expect((origin['agent']! as Map)['lineUpID'], origin['id']);
    expect(origin['id'], startsWith('o1~cp1~'));
  });

  test('a trashed page row that contradicts itself is not read', () {
    final base = <String, Object?>{
      'publicId': 'page-b',
      'strategyPublicId': strategyId,
      'name': 'Page 2',
      'sortIndex': 1,
      'isAttack': true,
      'revision': 3,
      'deleted': true,
    };
    for (final json in [
      {...base, 'deletedBy': 'you'},
      {...base, 'deletedAt': 8640000000000001, 'deletedBy': 'you'},
      {...base, 'deleted': false, 'deletedAt': 1, 'deletedBy': 'you'},
    ]) {
      expect(
        PageRow.decode(json),
        isA<CouldNotRead<PageRow>>(),
        reason: '$json',
      );
    }
  });
}
