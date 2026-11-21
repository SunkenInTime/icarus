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

  test('a moved item is one whole write at its stored revision', () {
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
          .having((op) => op.merge, 'merge', isNull),
    ]);
    expectReached(stored, target);
  });

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

  test('600 generated pairs each reach their target', () {
    final made = <OpType, int>{};
    var revived = 0;
    for (var seed = 0; seed < 600; seed++) {
      final generator = Generator(seed);
      final stored = generator.strategy();
      final target = generator.mutated(stored);
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
