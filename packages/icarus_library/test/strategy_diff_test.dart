import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/strategy_diff_check.dart';
import 'package:test/test.dart';

import 'strategy_diff_support.dart';
import 'support.dart';

List<StrategyOp> opsOf(StrategyDiff diff) => switch (diff) {
  DiffOps(:final ops) => ops,
  DiffRefused(:final refusal) => fail('refused: $refusal'),
};

DiffRefusal refusalOf(StrategyDiff diff) => switch (diff) {
  DiffRefused(:final refusal) => refusal,
  DiffOps(:final ops) => fail('expected a refusal, got ${ops.length} ops'),
};

String reachedOrWhy(
  StrategyRowSet stored,
  StrategyRowSet target,
  List<StrategyOp> ops,
) => switch (checkDiff(stored, target, ops)) {
  DiffReached(:final rows) => switch (diffStrategy(
    rows,
    target,
    editId: 'again',
  )) {
    DiffOps(ops: []) => 'reached',
    DiffOps(:final ops) => '${ops.length} ops left after reaching it',
    DiffRefused(:final refusal) => 'refused after reaching it: $refusal',
  },
  DiffMissed(:final what) => what,
};

void expectReached(StrategyRowSet stored, StrategyRowSet target) {
  final ops = opsOf(diffStrategy(stored, target, editId: 'edit'));
  expect(reachedOrWhy(stored, target, ops), 'reached');
  expect(opsOf(diffStrategy(target, target, editId: 'again')), isEmpty);
}

const _everyDiffOp = [
  OpType.strategyPatch,
  OpType.pageAdd,
  OpType.pagePatch,
  OpType.pageDelete,
  OpType.pageReorder,
  OpType.pageSettingsPatch,
  OpType.elementAdd,
  OpType.elementPatch,
  OpType.elementDelete,
  OpType.lineupGroupAdd,
  OpType.lineupGroupPatch,
  OpType.lineupGroupDelete,
];

void main() {
  group('A strategy diffed against itself', () {
    test('needs no op', () {
      final rows = Generator(1).strategy();
      expect(opsOf(diffStrategy(rows, rows, editId: 'e')), isEmpty);
    });

    test('needs no op when only revisions differ', () {
      final stored = strategyRows(
        elements: [element('jett', revision: 4)],
        pages: [page('page-a', sortIndex: 0, revision: 3)],
      );
      final target = strategyRows(
        elements: [element('jett')],
        pages: [page('page-a', sortIndex: 0)],
      );
      expect(opsOf(diffStrategy(stored, target, editId: 'e')), isEmpty);
    });
  });

  test('ops get ids derived from the edit, the same each time', () {
    final stored = strategyRows();
    final target = strategyRows(elements: [element('jett'), element('sova')]);
    final first = opsOf(diffStrategy(stored, target, editId: 'edit-1'));
    final again = opsOf(diffStrategy(stored, target, editId: 'edit-1'));
    final other = opsOf(diffStrategy(stored, target, editId: 'edit-2'));
    expect(
      [for (final op in first) op.opId],
      [for (final op in again) op.opId],
    );
    expect({for (final op in first) op.opId}, hasLength(2));
    expect(first.first.opId, isNot(other.first.opId));
  });

  test(
    'a moved item is a field merge naming what moved, at its stored revision',
    () {
      final stored = strategyRows(
        elements: [
          element('jett', fields: {'position': 1}, revision: 3),
          element('sova', sortIndex: 1),
        ],
      );
      final target = strategyRows(
        elements: [
          element('jett', fields: {'position': 2}),
          element('sova', sortIndex: 1),
        ],
      );
      final ops = opsOf(diffStrategy(stored, target, editId: 'e'));
      expect(ops, [
        isA<ElementPatchOp>()
            .having((op) => op.expectedElementRevision, 'revision', 3)
            .having((op) => op.merge?.fields, 'merge', ['position']),
      ]);
      expectReached(stored, target);
    },
  );

  test('a removed caption is written as cleared', () {
    final stored = strategyRows(
      elements: [
        element('jett', fields: {'caption': 'hold A'}),
      ],
    );
    final target = strategyRows(elements: [element('jett')]);
    final ops = opsOf(diffStrategy(stored, target, editId: 'e'));
    expect((ops.single as ElementPatchOp).payload!.data['caption'], '');
    expectReached(stored, target);
  });

  test('an auto-named page renamed by a move gets its name back', () {
    final stored = strategyRows(
      pages: [
        page('page-a', sortIndex: 0, name: 'Page 1', isAutoNamed: true),
        page('page-b', sortIndex: 1, name: 'Opening', isAutoNamed: true),
      ],
    );
    final target = strategyRows(
      pages: [
        page('page-b', sortIndex: 0, name: 'Opening', isAutoNamed: true),
        page('page-a', sortIndex: 1, name: 'Page 1', isAutoNamed: true),
      ],
    );
    expectReached(stored, target);
  });

  test('an empty strategy becomes a full one', () {
    final full = Generator(7).strategy();
    final empty = StrategyRowSet(strategy: full.strategy);
    final readableOnly = StrategyRowSet(
      strategy: full.strategy,
      pages: full.pages,
      settings: full.settings,
      elements: full.elements.whereType<LiveElement>(),
      lineupGroups: full.lineupGroups,
    );
    expectReached(empty, readableOnly);
  });

  group('A row this build cannot read', () {
    test('is carried untouched when the target leaves it out', () {
      final stored = strategyRows(
        elements: [unreadable('hologram'), element('jett')],
      );
      final target = strategyRows(elements: [element('jett', sortIndex: 2)]);
      final ops = opsOf(diffStrategy(stored, target, editId: 'e'));
      expect(ops.single, isA<ElementPatchOp>());
      expectReached(stored, target);
    });

    test('refuses a target that would rewrite it', () {
      final stored = strategyRows(elements: [unreadable('hologram')]);
      final target = strategyRows(elements: [element('hologram')]);
      expect(
        refusalOf(diffStrategy(stored, target, editId: 'e')),
        isA<RowNotReadable>().having(
          (refusal) => refusal.key,
          'key',
          const ElementKey('hologram'),
        ),
      );
    });

    test('refuses a target that holds one the stored rows do not', () {
      final target = strategyRows(elements: [unreadable('hologram')]);
      expect(
        refusalOf(diffStrategy(strategyRows(), target, editId: 'e')),
        isA<RowNotReadable>(),
      );
    });

    test('refuses a change to the page list that would move its page', () {
      final held = UnreadablePage(
        publicId: 'page-held',
        strategyPublicId: strategyId,
        sortIndex: 1,
        trashed: false,
        stored: {'publicId': 'page-held'},
        problem: 'damaged',
      );
      final stored = strategyRows(
        pages: [page('page-a', sortIndex: 0), held],
        pageSettings: [settings('page-a')],
      );
      final target = strategyRows(
        pages: [page('page-a', sortIndex: 0), page('page-new', sortIndex: 1)],
      );
      expect(
        refusalOf(diffStrategy(stored, target, editId: 'e')),
        isA<RowNotReadable>().having(
          (refusal) => refusal.key,
          'key',
          const PageKey('page-held'),
        ),
      );
    });
  });

  test('refuses to clear a door', () {
    final stored = strategyRows(
      elements: [
        itemOf(
          ElementKind.utility,
          'door',
          pageId: 'page-a',
          fields: {'mapDoor': 'summitA'},
        ),
      ],
    );
    final target = strategyRows(
      elements: [itemOf(ElementKind.utility, 'door', pageId: 'page-a')],
    );
    expect(
      refusalOf(diffStrategy(stored, target, editId: 'e')),
      isA<FieldNotClearable>().having((r) => r.field, 'field', 'mapDoor'),
    );
  });

  test('refuses a page that sits in the trash', () {
    final stored = strategyRows(
      pages: [
        page('page-a', sortIndex: 0),
        page('page-b', sortIndex: 1, deleted: true),
      ],
    );
    final target = strategyRows();
    expect(
      refusalOf(diffStrategy(stored, target, editId: 'e')),
      isA<RowInTrash>(),
    );
  });

  test('refuses a folder move, which is a library edit', () {
    final stored = strategyRows();
    final target = withStrategy(stored, folderPublicId: 'folder-1');
    expect(
      refusalOf(diffStrategy(stored, target, editId: 'e')),
      isA<FolderChanged>(),
    );
  });

  test('refuses a target with no page', () {
    final stored = strategyRows();
    final target = StrategyRowSet(strategy: stored.strategy);
    expect(
      refusalOf(diffStrategy(stored, target, editId: 'e')),
      isA<LastPageRemoved>(),
    );
  });

  group('A page removed from the target', () {
    final stored = strategyRows(
      elements: [
        element('jett'),
        element('sova', pageId: 'page-b'),
        element('omen', pageId: 'page-b', sortIndex: 1),
      ],
      lineupGroups: [lineupGroup('g1', pageId: 'page-b')],
    );

    test('goes to the trash with what is on it', () {
      final target = strategyRows(
        pages: [page('page-a', sortIndex: 0)],
        elements: [element('jett')],
      );
      final ops = opsOf(diffStrategy(stored, target, editId: 'e'));
      expect(ops.map((op) => op.type), [OpType.pageDelete]);
      expectReached(stored, target);
    });

    test('keeps an item the target moved to another page', () {
      final target = strategyRows(
        pages: [page('page-a', sortIndex: 0)],
        elements: [element('jett'), element('sova', sortIndex: 1)],
      );
      expectReached(stored, target);
    });

    test('in the trash with its content needs no op', () {
      final trashed = strategyRows(
        pages: [
          page('page-a', sortIndex: 0),
          page('page-b', sortIndex: 1, deleted: true),
        ],
        elements: [
          element('jett'),
          element('sova', pageId: 'page-b'),
        ],
        lineupGroups: [lineupGroup('g1', pageId: 'page-b')],
      );
      expect(opsOf(diffStrategy(trashed, trashed, editId: 'e')), isEmpty);
    });
  });

  group('Fields this build does not know', () {
    final plain = StrategyRowSet(
      strategy: strategyRow(),
      pages: [page('page-a', sortIndex: 0, name: 'Entry')],
      settings: [settings('page-a')],
      elements: [
        element(
          'jett',
          fields: {
            'position': {'dx': 1, 'dy': 2},
          },
        ),
      ],
      lineupGroups: [lineupGroup('g1', pageId: 'page-a', links: 2)],
    );
    final stored = withUnknownFields(plain);

    test('are not a reason to save', () {
      expect(opsOf(diffStrategy(stored, plain, editId: 'e')), isEmpty);
    });

    test('survive an edit of every row that holds them', () {
      final edited = StrategyRowSet(
        strategy: plain.strategy.rewritten(name: 'Renamed'),
        pages: [page('page-a', sortIndex: 0, name: 'Exit')],
        settings: [
          settings(
            'page-a',
            value: const PageSettings(
              agentSize: 40,
              abilitySize: 1,
              useNeutralTeamColors: false,
            ),
          ),
        ],
        elements: [
          element(
            'jett',
            fields: {
              'position': {'dx': 9, 'dy': 2},
            },
          ),
        ],
        lineupGroups: [
          lineupGroup('g1', pageId: 'page-a', links: 2, notes: 'jump throw'),
        ],
      );
      final ops = opsOf(diffStrategy(stored, edited, editId: 'e'));
      expect(ops.whereType<ElementPatchOp>().single.merge?.fields, [
        'position',
      ]);
      expect(ops.whereType<LineupGroupPatchOp>().single.merge?.fields, [
        'links/g1',
        'links/g1-k1',
      ]);
      expectReached(stored, edited);
    });
  });

  group('Page settings', () {
    test('that the target asks for on a page with none are refused', () {
      final stored = strategyRows(pageSettings: [settings('page-b')]);
      final target = strategyRows(
        pageSettings: [
          settings(
            'page-a',
            value: const PageSettings(
              agentSize: 40,
              abilitySize: 1,
              useNeutralTeamColors: false,
            ),
          ),
          settings('page-b'),
        ],
      );
      expect(
        refusalOf(diffStrategy(stored, target, editId: 'e')),
        isA<SettingsUnreachable>().having(
          (refusal) => refusal.key,
          'key',
          const PageKey('page-a'),
        ),
      );
    });

    test('that the target leaves out are refused', () {
      final stored = strategyRows();
      final target = strategyRows(pageSettings: [settings('page-b')]);
      expect(
        refusalOf(diffStrategy(stored, target, editId: 'e')),
        isA<SettingsUnreachable>(),
      );
    });
  });

  test('a page whose place and trash cannot be read stops a new page', () {
    final unknown = UnreadablePage(
      publicId: 'page-unknown',
      strategyPublicId: strategyId,
      sortIndex: null,
      trashed: null,
      stored: {'publicId': 'page-unknown'},
      problem: 'damaged',
    );
    final stored = strategyRows(
      pages: [page('page-a', sortIndex: 0), unknown],
      pageSettings: [settings('page-a')],
    );
    final target = strategyRows(
      pages: [page('page-a', sortIndex: 0), page('page-new', sortIndex: 1)],
    );
    expect(
      refusalOf(diffStrategy(stored, target, editId: 'e')),
      isA<RowNotReadable>().having(
        (refusal) => refusal.key,
        'key',
        const PageKey('page-unknown'),
      ),
    );
  });

  test('op ids do not depend on the order rows come in', () {
    final stored = strategyRows();
    final items = [
      for (var i = 0; i < 6; i++) element('item-$i', sortIndex: i),
    ];
    final forwards = strategyRows(elements: items);
    final backwards = strategyRows(elements: items.reversed.toList());
    String describe(StrategyDiff diff) =>
        [for (final op in opsOf(diff)) '${op.opId} ${op.toJson()}'].join('\n');
    expect(
      describe(diffStrategy(stored, backwards, editId: 'e')),
      describe(diffStrategy(stored, forwards, editId: 'e')),
    );
  });

  test('600 generated pairs each reach their target', () {
    final made = <OpType, int>{};
    var revived = 0;
    for (var seed = 0; seed < 600; seed++) {
      final generator = Generator(seed);
      final plain = generator.strategy();
      final target = generator.mutated(plain);
      final stored = seed.isEven ? withUnknownFields(plain) : plain;
      final diff = diffStrategy(stored, target, editId: 'seed-$seed');
      final ops = opsOf(diff);
      for (final op in ops) {
        made[op.type] = (made[op.type] ?? 0) + 1;
        if (op case ElementAddOp(expectedElementRevision: _?)) revived++;
      }
      expect(
        reachedOrWhy(stored, target, ops),
        'reached',
        reason: 'seed $seed',
      );
      expect(opsOf(diffStrategy(target, target, editId: 'again')), isEmpty);
    }
    expect(revived, greaterThan(20), reason: 'adds over a deleted item');
    expect(made.keys, containsAll(_everyDiffOp));
    for (final type in _everyDiffOp) {
      expect(made[type], greaterThan(20), reason: type.wireName);
    }
  });
}
