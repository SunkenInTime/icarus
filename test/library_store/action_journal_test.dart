import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

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
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<({StoreMirror mirror, ActionJournal journal, Completer<void> gap})>
      following() async {
    final gap = Completer<void>();
    var copied = false;
    final journal = ActionJournal();
    final mirror = StoreMirror(
      reads: HiveReads(),
      betweenAnimations: () => copied ? gap.future : Future<void>.value(),
      actions: journal,
    );
    LocalLibrary.follower = mirror;
    final store = switch (await LibraryStore.open(
      MemoryEngine(MemoryStorage()),
      canRead: appCanRead,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('$problem'),
    };
    final writes = LibraryBoxWrites();
    await mirror.copyThenFollow(store, writes: writes);
    await writes.stop();
    copied = true;
    return (mirror: mirror, journal: journal, gap: gap);
  }

  test(
      'a burst of edits across two saves, all queued before the mirror runs, compares each save with exactly the ops of the actions before it, and both read back equal',
      () async {
    final (:mirror, :journal, :gap) = await following();
    final first = _added('first');
    final second = _added('second');
    final third = _added('third');
    void act(ActionObjectState object) => mirror.journal(
          'journaled',
          'addition text',
          Future.value([ObjectAdded('p0', object)]),
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
    final (:mirror, :journal, :gap) = await following();
    final reported = _added('reported');
    final silent = _added('silent');
    mirror.journal(
      'journaled',
      'addition text',
      Future.value([ObjectAdded('p0', reported)]),
    );
    await const LocalLibrary()
        .savePageOnScreen(_withTexts(_strategy(), [reported, silent]));
    gap.complete();
    await mirror.drained();

    expect(journal.tally.readBackUnequal, 1);
    expect(
      [
        for (final finding in journal.tally.findings)
          for (final difference in finding.differences) '$difference',
      ],
      ['text silent missing'],
    );
    expect(journal.tally.findings.single.actions, ['addition text']);
  });

  test(
      'a delete leaves a deleted row the image save may not drop, so the strategy is removed and the image put fresh, and the store ends exactly as Hive',
      () async {
    final (:mirror, :journal, :gap) = await following();
    final text =
        ActionObjectState.text(_strategy().pages.single.textData.single);
    mirror.journal(
      'journaled',
      'deletion text',
      Future.value([ObjectRemoved('p0', text)]),
    );
    final page = _strategy().pages.single;
    await const LocalLibrary().savePageOnScreen(
      _strategy().copyWith(pages: [page.copyWith(textData: const [])]),
    );
    gap.complete();
    await mirror.drained();

    expect(journal.tally.readBackEqual, 1);
    expect(journal.tally.deletedRowsRemoved, 1);
    expect(mirror.refusedStrategies, isEmpty);
  });
}
