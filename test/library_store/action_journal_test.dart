import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/ops_follower.dart';
import 'package:icarus/library_store/ops_verdict.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart' hide UserAction;

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

StrategyPage _page(String id) => generatedPage(
      id: id,
      sortIndex: 0,
      optionals: Optionals.set,
      isAttack: true,
    ).copyWith();

StrategyData _strategy() => generatedStrategy(Optionals.unset).copyWith(
      id: 'journaled',
      pages: [_page('p0')],
    );

ActionObjectState _added(String id) => ActionObjectState.fromJson(
      ActionObjectKind.text,
      {
        ...ActionObjectState.text(_page('template').textData.single).toJson(),
        'id': id,
      },
    );

StrategyData _withTexts(StrategyData strategy, List<ActionObjectState> added) {
  final page = strategy.pages.single;
  return strategy.copyWith(
    pages: [
      page.copyWith(
        textData: [...page.textData, for (final o in added) o.text!],
      ),
    ],
  );
}

final class _Gate {
  Completer<void>? _closed;
  final _hit = <Completer<void>>[];

  void close() => _closed = Completer<void>();

  void open() {
    final closed = _closed;
    _closed = null;
    closed?.complete();
  }

  Future<void> get hit {
    final waiting = Completer<void>();
    _hit.add(waiting);
    return waiting.future;
  }

  Future<void> pass() async {
    final closed = _closed;
    if (closed == null) return;
    for (final waiting in _hit) {
      waiting.complete();
    }
    _hit.clear();
    await closed.future;
  }
}

final class _GatedEngine implements StorageEngine {
  _GatedEngine(this._inner, this._gate);

  final StorageEngine _inner;
  final _Gate _gate;

  @override
  Future<Leasing> lease() async => switch (await _inner.lease()) {
        Leased(:final lease) => Leased(_GatedLease(lease, _gate)),
        final other => other,
      };
}

final class _GatedLease implements StorageLease {
  _GatedLease(this._inner, this._gate);

  final StorageLease _inner;
  final _Gate _gate;

  @override
  int get maxKeyLength => _inner.maxKeyLength;

  @override
  LeaseStatus get status => _inner.status;

  @override
  Future<KeyRead> read(String area, String key) => _inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      _inner.keys(area, prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _inner.entries(area, prefix);

  @override
  Future<Stored<List<String>>> areas(String prefix) => _inner.areas(prefix);

  @override
  Future<Committing> commit(List<Change> changes) async {
    await _gate.pass();
    return _inner.commit(changes);
  }

  @override
  Future<Releasing> release() => _inner.release();
}

typedef _Following = ({
  StoreMirror mirror,
  ActionJournal journal,
  LibraryStore store,
  Completer<void> gap,
  _Gate gate,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-journal-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    await openScratchHive(directory, strategies: [_strategy()]);
  });
  tearDown(() async {
    LocalLibrary.follower = null;
    ActionProvider.editFollower = null;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<_Following> following() async {
    final gap = Completer<void>();
    final gate = _Gate();
    var copied = false;
    final journal = ActionJournal();
    final mirror = StoreMirror(
      reads: HiveReads(),
      betweenAnimations: () => copied ? gap.future : Future<void>.value(),
      actions: journal,
    );
    LocalLibrary.follower = mirror;
    final store = switch (await LibraryStore.open(
      _GatedEngine(MemoryEngine(MemoryStorage()), gate),
      canRead: appCanRead,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('$problem'),
    };
    final writes = LibraryBoxWrites();
    await mirror.copyThenFollow(store, writes: writes);
    await writes.stop();
    copied = true;
    return (
      mirror: mirror,
      journal: journal,
      store: store,
      gap: gap,
      gate: gate,
    );
  }

  List<String> differencesOf(ActionJournal journal) => [
        for (final finding in journal.tally.findings)
          for (final difference in finding.differences) '$difference',
      ];

  Future<StrategyData> readBack(LibraryStore store, String id) async =>
      switch (await readStoredRows(store, id)) {
        StoredRowsRead(:final rows) => switch (strategyFromRows(rows)) {
            StrategyDataMade(:final strategy) => strategy,
            StrategyDataRefused(:final problems) => fail('$problems'),
          },
        StoredRowsNot(:final stored) => fail('$stored'),
      };

  StrategyData inEditorTerms(StrategyData strategy) =>
      switch (strategyToRows(strategyAsHiveHoldsIt(strategy))) {
        StrategyRowsMade(:final rows) => switch (strategyFromRows(rows)) {
            StrategyDataMade(:final strategy) => strategy,
            StrategyDataRefused(:final problems) => fail('$problems'),
          },
        StrategyRowsRefused(:final problems) => fail('$problems'),
      };

  test(
      'a burst of edits across two saves, all queued before the mirror runs, compares each save with exactly the ops of the actions before it, and both read back equal',
      () async {
    final (:mirror, :journal, :gap, store: _, gate: _) = await following();
    final first = _added('first');
    final second = _added('second');
    final third = _added('third');
    void act(ActionObjectState object) => mirror.journal(
          'journaled',
          'addition text',
          [ObjectAdded('p0', object)],
        );

    act(first);
    act(second);
    final afterTwo = _withTexts(_strategy(), [first, second]);
    final saving = const LocalLibrary().savePageOnScreen(afterTwo);
    act(third);
    await saving;
    await const LocalLibrary()
        .savePageOnScreen(_withTexts(_strategy(), [first, second, third]));

    expect(journal.tally.saves, 0);
    gap.complete();
    await mirror.drained();

    expect(journal.tally.actions, 3);
    expect(journal.tally.commits, 3);
    expect(journal.tally.commitsRefused, isEmpty);
    expect(journal.tally.gaps, isEmpty);
    expect(journal.tally.saves, 2);
    expect(journal.tally.readBackEqual, 2);
    expect(journal.tally.readBackUnequal, 0);
    expect(journal.tally.findings, isEmpty);
  });

  test(
      'a save that holds an edit no action reported reads back unequal and names the object',
      () async {
    final (:mirror, :journal, :gap, store: _, gate: _) = await following();
    final reported = _added('reported');
    final silent = _added('silent');
    mirror.journal('journaled', 'addition text', [ObjectAdded('p0', reported)]);
    await const LocalLibrary()
        .savePageOnScreen(_withTexts(_strategy(), [reported, silent]));
    gap.complete();
    await mirror.drained();

    expect(journal.tally.readBackUnequal, 1);
    expect(differencesOf(journal), ['text silent missing']);
    expect(journal.tally.findings.single.actions, ['addition text']);
  });

  test(
      'a delete leaves a deleted row the image save may not drop, so the strategy is removed and the image put fresh, and the store then reads back as exactly what Hive holds',
      () async {
    final (:mirror, :journal, :gap, :store, gate: _) = await following();
    final text =
        ActionObjectState.text(_strategy().pages.single.textData.single);
    mirror.journal('journaled', 'deletion text', [ObjectRemoved('p0', text)]);
    final page = _strategy().pages.single;
    await const LocalLibrary().savePageOnScreen(
      _strategy().copyWith(pages: [page.copyWith(textData: const [])]),
    );
    gap.complete();
    await mirror.drained();

    expect(journal.tally.readBackEqual, 1);
    expect(journal.tally.deletedRowsRemoved, 1);
    expect(mirror.refusedStrategies, isEmpty);
    final rows = switch (await readStoredRows(store, 'journaled')) {
      StoredRowsRead(:final rows) => rows,
      StoredRowsNot(:final stored) => fail('$stored'),
    };
    expect(rows.elements.whereType<DeletedElement>(), isEmpty);
    expect(
      readBackDifferences(
        inEditorTerms(const LocalLibrary().storedStrategy('journaled')!),
        await readBack(store, 'journaled'),
      ),
      isEmpty,
    );
  });

  test(
      'an ordinary mirror batch held in a commit does not write a later save of a strategy the journal has taken, so that save is compared against the actions alone',
      () async {
    final (:mirror, :journal, :store, :gate, :gap) = await following();
    gate.close();
    final reachedCommit = gate.hit;
    await const LocalLibrary().addFolder(
      Folder(id: 'f', name: 'F', dateCreated: DateTime.utc(2026, 2, 1)),
    );
    await const LocalLibrary().savePageOnScreen(_strategy());
    gap.complete();
    await reachedCommit;

    mirror.journal('journaled', 'edit text', const []);
    await const LocalLibrary()
        .savePageOnScreen(_withTexts(_strategy(), [_added('late')]));
    gate.open();
    await mirror.drained();

    expect(journal.tally.saves, 1);
    expect(journal.tally.commits, 0);
    expect(journal.tally.readBackUnequal, 1);
    expect(differencesOf(journal), ['text late missing']);
    expect(
      (await readBack(store, 'journaled'))
          .pages
          .single
          .textData
          .map((t) => t.id),
      contains('late'),
    );
  });

  test(
      'two queued renames of the same stored object are each compared with the name that save wrote',
      () async {
    final (:mirror, :journal, :gap, store: _, gate: _) = await following();
    mirror.journal('journaled', 'edit text', const []);
    final stored = const LocalLibrary().storedStrategy('journaled')!;
    final original = stored.name;
    await const LocalLibrary().renameStrategy(stored, 'New name');
    await const LocalLibrary().renameStrategy(stored, original);
    gap.complete();
    await mirror.drained();

    expect(journal.tally.saves, 2);
    expect(journal.tally.readBackUnequal, 2);
    expect(differencesOf(journal), [
      'strategy journaled name',
      'strategy journaled name',
    ]);
  });

  test('a Hive write that fails is counted as a failed save and never compared',
      () async {
    final (:mirror, :journal, :gap, store: _, gate: _) = await following();
    mirror.journal(
      'journaled',
      'addition text',
      [ObjectAdded('p0', _added('lost'))],
    );
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).close();
    final write = await const LocalLibrary()
        .savePageOnScreen(_withTexts(_strategy(), [_added('lost')]));
    expect(write, isA<LibraryWriteFailed>());
    gap.complete();
    await mirror.drained();

    expect(journal.tally.commits, 1);
    expect(journal.tally.savesFailed, 1);
    expect(journal.tally.saves, 0);
    expect(journal.tally.readBackEqual, 0);
  });

  test(
      'the first save of the strategy open in the editor is compared even when no action came before it',
      () async {
    final (:mirror, :journal, :gap, store: _, gate: _) = await following();
    journal.inEditor = (id) => id == 'journaled';
    await const LocalLibrary()
        .savePageOnScreen(_withTexts(_strategy(), [_added('silent')]));
    gap.complete();
    await mirror.drained();

    expect(journal.tally.followed, 1);
    expect(journal.tally.saves, 1);
    expect(differencesOf(journal), ['text silent missing']);
  });

  test(
      'an edit carries only the fields its action changed, so a silent change to another field of the same item still reads back unequal',
      () async {
    final (:mirror, :journal, :gap, store: _, gate: _) = await following();
    final text = _strategy().pages.single.textData.single;
    final silentlyTagged = ActionObjectState.text(text).text!
      ..tagColorValue = 0xFF22C55E;
    final before = ActionObjectState.text(silentlyTagged);
    final after = ActionObjectState.text(silentlyTagged)
      ..text!.caption = 'Plant B';
    mirror.journal(
      'journaled',
      'edit text',
      [ObjectChanged('p0', before, after)],
    );
    final page = _strategy().pages.single;
    await const LocalLibrary().savePageOnScreen(
      _strategy().copyWith(pages: [
        page.copyWith(textData: [ActionObjectState.text(after.text!).text!]),
      ]),
    );
    gap.complete();
    await mirror.drained();

    expect(differencesOf(journal), ['text ${text.id} tagColorValue']);
  });

  test(
      'a follower that throws leaves the edit alone, detaches itself and is counted as a fault',
      () async {
    final (:mirror, :journal, gap: _, store: _, gate: _) = await following();
    final follower = OpsFollower(
      mirror,
      () => throw StateError('no container'),
    );
    ActionProvider.editFollower = follower;

    follower.onAction(
      UserAction(type: ActionType.edit, id: 'x', group: ActionGroup.text),
      way: ActionWay.done,
    );
    follower.onPagesChanged(() => throw StateError('no page'), 'page add');

    expect(ActionProvider.editFollower, isNull);
    expect(journal.tally.followerFaults, hasLength(2));
    expect(journal.follows('journaled'), isFalse);
  });

  test(
      'the read-back compares the order of lineups inside each group, and the order of the groups, as separate differences',
      () {
    final page = generatedPage(
      id: 'lineups',
      sortIndex: 0,
      optionals: Optionals.unset,
      isAttack: true,
      lineups: sharedSpotLineups('pl'),
    ).copyWith();
    final graph = page.lineUpGraph;
    StrategyData withLinks(List<String> ids) => _strategy().copyWith(pages: [
          page.copyWith(
            lineUpGraph: LineUpGraph(
              origins: graph.origins,
              landings: graph.landings,
              links: [
                for (final id in ids)
                  graph.links.singleWhere((link) => link.id == 'pl-link-$id'),
              ],
            ),
          ),
        ]);
    List<String> between(List<String> expected, List<String> read) => [
          for (final difference
              in readBackDifferences(withLinks(expected), withLinks(read)))
            '$difference',
        ];

    expect(between(['a', 'b', 'c', 'd'], ['b', 'c', 'd', 'a']),
        ['lineup group pl-link-a order']);
    expect(between(['a', 'b', 'c', 'd'], ['d', 'a', 'b', 'c']),
        ['lineup groups lineups order']);
    expect(between(['a', 'b', 'c', 'd'], ['a', 'b', 'c', 'd']), isEmpty);
  });
}
