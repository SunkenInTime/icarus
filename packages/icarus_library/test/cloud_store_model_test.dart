import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:icarus_library/src/store/summary.dart' show PageTally;
import 'package:icarus_library/src/store/layout.dart'
    show PendingName, pendingPrefix, strategyArea;
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

final class FaultyLease extends ForwardingLease {
  FaultyLease(super.inner, this.model);

  final StoreModel model;

  @override
  Future<Committing> commit(List<Change> changes) async {
    model.commits++;
    if (!model.faults) return super.commit(changes);
    switch (model.random.nextInt(28)) {
      case 0 || 1:
        final landed = model.random.nextBool();
        count('commits answered unknown');
        model.log.add(
          'commit answered unknown; it ${landed ? 'landed' : 'did not land'}',
        );
        if (landed) await super.commit(changes);
        return const CommitUnknown(DeviceFailure('the reply was lost'));
      case 2:
        count('commits refused');
        model.log.add('commit refused');
        return const CommitRefused(DeviceFailure('the disk is full'));
      case _:
        return super.commit(changes);
    }
  }
}

Map<String, Object?> rowsWithRevisions(StrategyRowSet rows) => {
  for (final row in rows.rows)
    '${row.key}': switch (row.toJson()) {
      final Map<String, Object?> json => {
        for (final MapEntry(:key, :value) in json.entries)
          if (key != 'updatedAt' && key != 'deletedBy') key: value,
      },
      final other => other,
    },
};

final class DiskQueue {
  DiskQueue(Map<String, String> rows) {
    final pending = <(int, String)>[];
    for (final MapEntry(key: name, value: text) in rows.entries) {
      if (name.startsWith('pending/')) {
        pending.add((int.parse(name.substring('pending/'.length)), text));
      } else if (name.startsWith('attempt/')) {
        final number = int.parse(name.substring('attempt/'.length));
        attempts[number] = attemptToJson(
          (attemptFromText(number, text) as CloudRowRead<AttemptFact>).value,
        );
      } else if (name.startsWith('landed/')) {
        landed[name] = text;
      } else if (name == 'read/header') {
        groups[null] = text;
      } else if (name.startsWith('read/page/')) {
        final json = jsonDecode(text) as Map<String, Object?>;
        groups[json['page']! as String] = text;
      }
    }
    entries = switch (entriesFrom(pending)) {
      EntriesRead(:final entries) => [
        for (final entry in entries) entryToJson(entry),
      ],
      EntriesUnreadable(:final problem) => throw StateError(problem),
    };
    facts = switch (rows['cloud']) {
      final text? => switch (factsFromText(text)) {
        CloudRowRead(value: CloudFacts(:final owner, :final facts)) =>
          factsToJson(owner, facts),
        CloudRowUnreadable(:final problem) => throw StateError(problem),
      },
      null => null,
    };
  }

  late final List<Map<String, Object?>> entries;
  final attempts = <int, Map<String, Object?>>{};
  final landed = <String, String>{};
  final groups = <String?, String>{};
  late final Map<String, Object?>? facts;
}

final counted = <String, int>{};

void count(String what, [int by = 1]) =>
    counted[what] = (counted[what] ?? 0) + by;

final class StoreModel {
  StoreModel(this.seed, {required this.teammates}) : random = Random(seed);

  final int seed;
  final bool teammates;
  final Random random;
  MemoryStorage storage = MemoryStorage();
  final server = Server();
  final log = <String>[];
  final reference = <StrategyOp>[];
  final inFlight = <(int, String, List<StrategyOp>)>[];
  late LibraryStore store;
  DateTime clock = now;
  String clientId = 'client-0';
  String build = 'build-0';
  int restarts = 0;
  int nextId = 0;
  bool faults = true;
  int commits = 0;
  bool userRemoved = false;
  bool teammateEdited = false;
  String openPage = 'page-a';
  int live = 0;

  Future<void> liveIsCurrent() async =>
      live = (await sync()).queue.session.number;

  String fresh(String prefix) => '$prefix${nextId++}';

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];

  Future<void> open() async {
    store = await openCloudStore(
      WrappingEngine(
        MemoryEngine(storage),
        (lease) => FaultyLease(lease, this),
      ),
      build: build,
      clock: () => clock,
    );
  }

  Future<void> start() async {
    await open();
    while (true) {
      final rows = initialRows();
      final result = await store.addCloudStrategy(
        testAccount,
        headerReadOf(rows),
        pageReadsOf(rows),
      );
      if (result case Refused(reason: StrategyAlreadyInStore())) {
        count('add in doubt landed');
        await diskEqualsMemory('add the cloud strategy, found landed');
        break;
      }
      if (result case Refused(:final reason)) {
        throw StateError('adding the cloud strategy was refused: $reason');
      }
      if (await settled(result, 'add the cloud strategy')) {
        await diskEqualsMemory('add the cloud strategy');
        await liveIsCurrent();
        break;
      }
      count('add tried again');
    }
  }

  Future<void> reopen(String why) async {
    log.add('reopen: $why');
    await store.close();
    await open();
    count('reopened');
    await restartSession();
  }

  Future<void> restartSession() async {
    for (var tries = 0; tries < 20; tries++) {
      final result = await store.record(testAccount, strategyId, [
        AppRestarted(build: build),
      ]);
      log.add('session after reopen -> ${describeSaving(result)}');
      switch (result) {
        case SaveInDoubt():
          await store.close();
          await open();
        case NotSaved():
          continue;
        case Saved():
          await liveIsCurrent();
          return;
        case _:
          return;
      }
    }
  }

  Future<T> reading<T>(Future<T> Function() read) async {
    final before = commits;
    final value = await read();
    if (commits != before) throw StateError('a read made a commit');
    count('reads checked for commits');
    return value;
  }

  Future<ResultSource> started() async => readFrom((await sync()).queue);

  Future<CloudStrategy> sync() async => cloudOf(
    switch (await reading(() => store.readStrategy(strategyId))) {
      Found(:final value) => value,
      final other => throw StateError('the strategy did not read: $other'),
    }.sync,
  );

  Future<bool> settled<S, R>(Saving<S, R> result, String label) async {
    switch (result) {
      case Saved() || NothingToSave():
        return true;
      case SaveInDoubt():
        count('save in doubt');
        await reopen('$label was in doubt');
        return false;
      case NotSaved(:final failure):
        log.add('$label was not saved: $failure');
        return false;
      case Refused(:final reason):
        log.add('$label refused: $reason');
        return false;
    }
  }

  Future<void> diskEqualsMemory(String label) async {
    final cloud = await sync();
    final memory = cloud.queue;
    final disk = DiskQueue(storage.contents[strategyArea(strategyId)] ?? {});
    final want = {
      'entries': [for (final entry in memory.entries) entryToJson(entry)],
      'attempts': {
        for (final attempt in memory.attempts.values)
          '${attempt.number}': attemptToJson(attempt),
      },
      'facts': factsToJson(cloud.owner, memory.strategy),
      'landed': [for (final work in memory.landed) landedToJson(work)],
      'counters': memory.nextAttempt,
    };
    final got = {
      'entries': disk.entries,
      'attempts': {
        for (final MapEntry(:key, :value) in disk.attempts.entries)
          '$key': value,
      },
      'facts': disk.facts,
      'landed': [
        for (final MapEntry(key: name, value: text)
            in (disk.landed.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key))))
          switch (name.split('/')) {
            [_, final attempt, final position] => landedToJson(
              (landedFromText(int.parse(attempt), int.parse(position), text)
                      as CloudRowRead<LandedWork>)
                  .value,
            ),
            _ => throw StateError(name),
          },
      ],
      'counters': switch (storage.contents['library']?['numbers']) {
        final text? => switch (countersFromText(text)) {
          CloudRowRead(value: final numbers)
              when numbers.nextSession <= memory.nextSession =>
            numbers.nextAttempt,
          CloudRowRead(value: final numbers) =>
            'session ${numbers.nextSession} stored ahead of memory',
          CloudRowUnreadable(:final problem) => problem,
        },
        null => null,
      },
    };
    if (!const DeepCollectionEquality().equals(want, got)) {
      throw StateError('after $label the disk holds $got, memory $want');
    }
    final stored = shownFromGroups(disk.groups);
    if (stored is! ShownRead || stored.shown != memory.shown.inNewSession()) {
      throw StateError(
        'after $label the results on disk differ from memory: '
        '${disk.groups.keys} vs ${memory.shown.content.keys}',
      );
    }
    final mine = await listMatchesPages(label);
    final summary = listOf(store).strategies.single;
    final reopened = await openCloudStore(
      MemoryEngine(MemoryStorage(storage.contents)),
      build: build,
      clock: () => clock,
    );
    final listedAsShown = listOf(reopened).strategies.single;
    final listed = switch (listedAsShown.sync) {
      CloudUnverified() => () {
        if (summary.sync case KeptInCloud(
          :final tally,
        ) when tally.standing != Standing.good || tally.total > 0) {
          throw StateError(
            'after $label a reopen lists unverified work that memory '
            'counts as $tally',
          );
        }
        count('reopened lists shown unverified');
        return listedAsShown.withSync(summary.sync);
      }(),
      _ => listedAsShown,
    };
    if (listed != summary) {
      throw StateError(
        'after $label the stored summary is ${listed.toJson()}, '
        'memory ${summary.toJson()}',
      );
    }
    if (listed.sync case KeptInCloud(
      :final tally,
    ) when tally != Tally.of(memory, clock)) {
      throw StateError('after $label the stored tally is $tally');
    }
    final saved = store;
    store = reopened;
    final theirs = await visible();
    store = saved;
    await reopened.close();
    if (!const DeepCollectionEquality().equals(
      rowsWithRevisions(theirs),
      rowsWithRevisions(mine),
    )) {
      throw StateError('after $label the stored rows differ from memory');
    }
    count('disk checked against memory');
  }

  Future<void> memoryAsBefore((CloudQueue, Object) before, String label) async {
    final (queue, rows) = before;
    if ((await sync()).queue != queue ||
        !const DeepCollectionEquality().equals(
          rowsWithRevisions(await visible()),
          rows,
        )) {
      throw StateError('after $label was not stored, memory changed');
    }
    count('memory checked after a call that was not stored');
  }

  Future<(CloudQueue, Object)> snapshot() async =>
      ((await sync()).queue, rowsWithRevisions(await visible()));

  Future<Recorded?> record(
    List<QueueEvent> events,
    String label, {
    bool again = true,
  }) async {
    final before = await snapshot();
    final result = await store.record(testAccount, strategyId, events);
    log.add(
      '$label -> ${switch (result) {
        Saved(:final value) => [for (final outcome in value.outcomes) switch (outcome) {
            ReportApplied(:final effects) => effects.isEmpty ? 'ok' : '$effects',
            ReportNotApplicable(:final why) => 'not applicable: $why',
            EditsGoThroughCommit() => 'edit',
          }].join(', '),
        final other => describeSaving(other),
      }}',
    );
    if (result case NotSaved() || Refused()) {
      await memoryAsBefore(before, label);
    }
    if (result case NotSaved() when again) {
      count('events delivered again after a commit that was not stored');
      return record(events, '$label again', again: false);
    }
    if (!await settled(result, label)) return null;
    await diskEqualsMemory(label);
    final recorded = (result as Saved<Recorded, CommitRefusal>).value;
    if (events.any(
      (event) =>
          event is AppRestarted ||
          event is ConnectionReturned ||
          event is AccountChanged,
    )) {
      live = (await sync()).queue.session.number;
    }
    for (final outcome in recorded.outcomes) {
      if (outcome case ReportApplied()) count('recorded');
    }
    return recorded;
  }

  Future<StrategyRowSet> listMatchesPages(
    String label, {
    bool beforeReads = true,
  }) async {
    await reading(() => store.readStrategy(strategyId));
    final before = listOf(store).strategies.single;
    final mine = await visible();
    final reported = <String, PageTally>{};
    for (final page in mine.pages) {
      if (page is! LivePage) continue;
      final content = pageOf(
        await reading(() => store.readPage(strategyId, page.publicId)),
      );
      reported[page.publicId] = PageTally.count(
        elements: content.elements,
        lineupGroups: content.lineupGroups,
        damaged: content.unplaced.length,
        newer: content.unknownKinds.length,
      );
    }
    final after = listOf(store).strategies.single;
    for (final (moment, summary) in [
      if (beforeReads) ('before the pages were read', before),
      ('after the pages were read', after),
    ]) {
      for (final MapEntry(key: page, value: tally) in reported.entries) {
        if (summary.tallies[page] ?? PageTally.empty case final listed
            when listed != tally) {
          throw StateError(
            'after $label, $moment, the list counts ${listed.toJson()} on '
            '$page, the page reports ${tally.toJson()}',
          );
        }
      }
    }
    return mine;
  }

  Future<List<Object>> observed() async {
    final cloud = await sync();
    return [
      rowsWithRevisions(await visible()),
      {
        for (final MapEntry(:key, :value) in cloud.views.entries)
          key: '${value.state} ${value.sendable} ${value.holds}',
      },
      {for (final subject in resultsNeeded(cloud.queue, clock)) '$subject'},
    ];
  }

  Future<void> unloadChangesNothing() async {
    final before = await observed();
    if (await store.unload(strategyId) is! Unloaded) {
      throw StateError('the strategy did not unload');
    }
    final after = await observed();
    if (!const DeepCollectionEquality.unordered().equals(before, after)) {
      throw StateError(
        'unloading and reloading changed what an observer sees:\n'
        '$before\nvs\n$after',
      );
    }
    count('unloads that changed nothing');
  }

  Future<void> damagedRowsArrive() async {
    final (pages, _) = await livePagesAndElements();
    if (pages.isEmpty) return;
    faults = false;
    await store.close();
    final contents = editable(storage.contents);
    final page = pick(pages);
    final id = fresh('damaged');
    contents[strategyArea(strategyId)]![elementName(page, id)] =
        '{"broken":true}';
    contents[strategyArea(
          strategyId,
        )]!['content/${digestOf(page)}/z/${digestOf(id)}'] =
        '{"kind":"from a newer build"}';
    storage = MemoryStorage(contents);
    await open();
    await restartSession();
    await listMatchesPages(
      'a damaged row and an unknown kind arrived',
      beforeReads: false,
    );
    faults = true;
    count('damaged and unknown rows compared against the list');
  }

  Future<void> readerLearnsAgents() async {
    faults = false;
    await store.close();
    final blind = switch (await LibraryStore.open(
      MemoryEngine(storage),
      canRead: CanRead(element: (_) => false, lineupGroup: (_) => true),
      clock: () => clock,
      build: build,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };
    final rebuilt = await blind.rebuildSummary(strategyId);
    log.add('a reader that cannot read agents rebuilt the summary -> $rebuilt');
    await blind.close();
    await open();
    await restartSession();
    await listMatchesPages(
      'a reader learned to read agents',
      beforeReads: false,
    );
    faults = true;
    count('readers that learned a payload');
  }

  Future<StrategyRowSet> visible() async {
    final content = strategyOf(
      await reading(() => store.readStrategy(strategyId)),
    );
    final elements = <ElementRow>[];
    final drawnOn = <String, String>{};
    for (final page in content.pages) {
      for (final row in pageOf(
        await reading(() => store.readPage(strategyId, page.publicId)),
      ).elements) {
        if (row is LiveElement) {
          if (drawnOn[row.publicId] case final other?) {
            throw StateError(
              '${row.publicId} is drawn on $other and ${page.publicId}',
            );
          }
          drawnOn[row.publicId] = page.publicId;
        }
        elements.add(row);
      }
    }
    return StrategyRowSet(
      strategy: headerOf(content),
      pages: content.pages,
      settings: content.settings.values,
      elements: elements,
    );
  }

  Future<void> edit() async {
    final rows = await visible();
    final pages = [
      for (final page in rows.pages)
        if (page is LivePage) page.publicId,
    ];
    final live = [
      for (final row in rows.elements)
        if (row case LiveElement(
          :final pagePublicId,
        ) when pages.contains(pagePublicId))
          row,
    ];
    final opId = fresh('op');
    final roll = random.nextInt(13);
    final StrategyOp op;
    if (roll < 5 && live.isNotEmpty) {
      final target = pick(live);
      op = ElementPatchOp(
        opId: opId,
        elementPublicId: target.publicId,
        expectedElementRevision: target.revision,
        payload: agentPayload(target.publicId, {
          ...target.payload.data.toJson(),
          'position': {'dx': random.nextInt(1000), 'dy': 0},
        }),
        sortIndex: target.sortIndex,
        merge: random.nextBool() ? FieldMerge(fields: ['position']) : null,
      );
    } else if (roll < 7 && live.isNotEmpty) {
      final target = pick(live);
      op = elementDelete(
        opId,
        elementId: target.publicId,
        pageId: target.pagePublicId,
        expected: target.revision,
      );
    } else if (roll < 10 && pages.isNotEmpty) {
      op = elementAdd(opId, elementId: fresh('e'), pageId: pick(pages));
    } else if (roll == 11 && pages.length < 4 && pages.isNotEmpty) {
      op = pageAdd(
        opId,
        fresh('copy-'),
        expected: rows.strategy.revision,
        sortIndex: pages.length,
        copyFrom: pick(pages),
      );
      count('page copies');
    } else if (roll == 11 && pages.any((page) => page.startsWith('copy-'))) {
      op = pageDelete(
        opId,
        pick([
          for (final page in pages)
            if (page.startsWith('copy-')) page,
        ]),
        expected: rows.strategy.revision,
      );
      count('copied page deletes');
    } else if (roll == 10 && pages.isNotEmpty) {
      final page = rows.page(pick(pages))! as LivePage;
      op = PagePatchOp(
        opId: opId,
        pagePublicId: page.publicId,
        expectedPageRevision: page.revision,
        name: 'Renamed ${random.nextInt(100)}',
      );
    } else if (roll == 12 && live.isNotEmpty && pages.length > 1) {
      op = moveToAnotherPage(opId, pick(live), pages);
    } else if (roll != 11 && pages.length < 4) {
      op = pageAdd(
        opId,
        fresh('page-'),
        expected: rows.strategy.revision,
        sortIndex: pages.length,
      );
    } else {
      return;
    }
    await commitOp(op);
  }

  ElementPatchOp moveToAnotherPage(
    String opId,
    LiveElement target,
    List<String> pages,
  ) {
    count('moves to another page');
    return ElementPatchOp(
      opId: opId,
      elementPublicId: target.publicId,
      expectedElementRevision: target.revision,
      pagePublicId: pick([
        for (final page in pages)
          if (page != target.pagePublicId) page,
      ]),
      payload: target.payload,
      sortIndex: 0,
    );
  }

  Future<bool> commitOp(StrategyOp op) async {
    final opId = op.opId;
    final before = {for (final entry in (await sync()).queue.entries) entry.id};
    final unchanged = await snapshot();
    final result = await store.commitAs(
      testAccount,
      strategyId,
      op,
      seen: await seenIn(store),
    );
    log.add(
      'edit $opId ${op.type.wireName} ${targetOf(op)} -> ${describeSaving(result)}',
    );
    switch (result) {
      case Saved():
        reference.add(op);
        await diskEqualsMemory('edit $opId');
        return true;
      case SaveInDoubt():
        count('save in doubt');
        await reopen('edit $opId was in doubt');
        final after = {
          for (final entry in (await sync()).queue.entries) entry.id,
        };
        final landed =
            after.difference(before).isNotEmpty ||
            before.difference(after).isNotEmpty;
        log.add('edit $opId ${landed ? 'landed' : 'did not land'}');
        count(landed ? 'doubtful edit landed' : 'doubtful edit lost');
        if (landed) reference.add(op);
        return landed;
      case Refused() || NotSaved():
        await memoryAsBefore(unchanged, 'edit $opId');
        return false;
      case NothingToSave():
        return false;
    }
  }

  Future<void> landNow() async {
    await claim();
    while (inFlight.isNotEmpty) {
      final (attempt, owner, ops) = inFlight.removeAt(0);
      await record([
        for (final op in ops) OpAnswered(attempt, server.apply(owner, op)),
      ], 'answers for $attempt');
    }
  }

  Future<(List<String>, List<LiveElement>)> livePagesAndElements() async {
    final rows = await visible();
    final pages = [
      for (final page in rows.pages)
        if (page is LivePage) page.publicId,
    ];
    return (
      pages,
      [
        for (final row in rows.elements)
          if (row case LiveElement(
            :final pagePublicId,
          ) when pages.contains(pagePublicId))
            row,
      ],
    );
  }

  Future<void> twoAcceptedMoves() async {
    final (pages, live) = await livePagesAndElements();
    if (pages.length < 2 || live.isEmpty) return;
    final target = pick(live);
    if (!await commitOp(moveToAnotherPage(fresh('op'), target, pages))) return;
    await landNow();
    if ((await visible()).element(target.publicId) case final LiveElement row) {
      if (!await commitOp(moveToAnotherPage(fresh('op'), row, pages))) return;
      await landNow();
      count('two accepted moves of one row');
    }
  }

  Future<void> editOfAcceptedAdd() async {
    final (pages, _) = await livePagesAndElements();
    if (pages.isEmpty) return;
    final id = fresh('e');
    if (!await commitOp(
      elementAdd(fresh('op'), elementId: id, pageId: pick(pages)),
    )) {
      return;
    }
    await landNow();
    if ((await visible()).element(id) case final LiveElement row) {
      if (await commitOp(
        movePatch(
          fresh('op'),
          elementId: id,
          expected: row.revision,
          x: random.nextInt(1000).toDouble(),
        ),
      )) {
        count('edits of a row shown only by accepted work');
      }
    }
  }

  Future<void> pageGoneUnderQueuedMove() async {
    if (!teammates) return;
    final (pages, live) = await livePagesAndElements();
    if (pages.length < 2 || live.isEmpty) return;
    final target = pick(live);
    if (!await commitOp(moveToAnotherPage(fresh('op'), target, pages))) return;
    final source = target.pagePublicId;
    final delete = pageDelete(
      fresh('t'),
      source,
      expected: server.rows.strategy.revision,
    );
    if (applyOp(server.rows, delete) case final OpApplied done) {
      server.write(done);
      teammateEdited = true;
      log.add('teammate deletes $source under a queued move');
      await readOne(PageGone(source), 'page $source is gone');
      count('pages gone under a queued move');
    }
  }

  Future<void> giveUpLostSends() async {
    final queue = (await sync()).queue;
    final carried = {for (final (attempt, _, _) in inFlight) attempt};
    final lost = [
      for (final attempt in queue.attempts.values)
        if (attempt.outcome is AttemptOpen && !carried.contains(attempt.number))
          attempt.number,
    ];
    if (lost.isEmpty) return;
    await record([
      for (final attempt in lost)
        TransportFailed(attempt, TransportFailure.timeout, at: clock),
    ], 'the sender gives up $lost');
    count('sends given up');
  }

  Future<void> claim() async {
    await giveUpLostSends();
    final cloud = await sync();
    if (standingOf(cloud.queue) != Standing.good) return;
    String? owner;
    final ids = <String>[];
    for (final entry in cloud.queue.entries) {
      if (ids.length == 4) break;
      final view = cloud.views[entry.id];
      if (view == null || !view.sendable) continue;
      final mine = switch (view.state) {
        Unanswered(:final clientId) => clientId,
        _ => owner ?? clientId,
      };
      if (owner != null && mine != owner) continue;
      owner = mine;
      ids.add(entry.id);
    }
    if (ids.isEmpty) return;
    final recorded = await record([
      BatchClaimed(clientId: owner!, opIds: ids, at: clock),
    ], 'claim $ids');
    if (recorded == null) return;
    final sent = effectsOf(recorded).whereType<SendBatch>().single;
    inFlight.add((sent.attempt, sent.clientId, sent.ops));
  }

  Future<void> deliver() async {
    if (inFlight.isEmpty) return;
    final (attempt, owner, ops) = inFlight.removeAt(
      random.nextInt(inFlight.length),
    );
    if (random.nextInt(8) == 0) {
      await record([
        TransportFailed(attempt, TransportFailure.network, at: clock),
      ], 'lost $attempt');
      return;
    }
    final answers = [for (final op in ops) server.apply(owner, op)];
    if (random.nextInt(4) == 0) {
      await record([
        for (final answer in answers) OpAnswered(attempt, answer),
        BaseArrived(
          headerReadOf(server.rows),
          session: live,
          from: await started(),
        ),
        const ConnectionReturned(),
      ], 'answers for $attempt with a header read in one call');
      count('mixed event lists');
      return;
    }
    await record([
      for (final answer in answers) OpAnswered(attempt, answer),
    ], 'answers for $attempt');
  }

  Future<void> restart() async {
    for (final (_, owner, ops) in inFlight) {
      if (random.nextBool()) {
        for (final op in ops) {
          server.apply(owner, op);
        }
      }
    }
    inFlight.clear();
    clientId = 'client-${++restarts}';
    if (random.nextInt(3) == 0) build = 'build-$restarts';
    await reopen('restart as $clientId on $build');
  }

  Future<void> readOne(ArrivedBase base, String label) async {
    await record([
      BaseArrived(base, session: live, from: await started()),
    ], label);
  }

  Future<void> lane() async {
    final cloud = await sync();
    switch (standingOf(cloud.queue)) {
      case Standing.editAccessLost:
        await record([
          EditAccessConfirmed(afterAttempt: cloud.queue.nextAttempt - 1),
        ], 'access confirmed');
      case Standing.upgradeRequired:
        build = 'build-up-${restarts++}';
        await reopen('upgraded to $build');
      case Standing.good || Standing.deletedOnServer || Standing.held:
        break;
    }
    if (random.nextInt(4) == 0) {
      await endedSessionRead();
    }
    await readOne(headerReadOf(server.rows), 'read strategy');
    final queue = (await sync()).queue;
    final drawn = await visible();
    String? holding(Target target) => switch (target) {
      ElementTarget(:final elementPublicId) =>
        drawn.element(elementPublicId)?.pagePublicId,
      LineupTarget(:final lineupPublicId) =>
        drawn.lineupGroup(lineupPublicId)?.pagePublicId,
      _ => null,
    };
    final pages = {
      openPage,
      for (final subject in resultsNeeded(queue, clock))
        ?switch (subject) {
          RowResult(:final page?) => page,
          RowResult(:final target) => holding(target),
          PageResult(:final page) => page,
          PageListResult() => null,
        },
      for (final work in queue.landed) ...[
        ...pagesNeeded(work.op),
        ?holding(targetOf(work.op)),
      ],
    }.where((page) => server.rows.page(page) != null).toSet();
    if (random.nextInt(3) == 0 && pages.isNotEmpty) {
      await record([
        for (final page in pages)
          BaseArrived(
            pageReadOf(server.rows, page),
            session: live,
            from: await started(),
          ),
      ], 'read ${pages.length} pages in one call');
      count('page reads in one call');
    } else {
      for (final page in pages) {
        await readOne(pageReadOf(server.rows, page), 'read $page');
      }
    }
  }

  Map<String, String> rowsAndResults(Contents contents) => {
    for (final MapEntry(:key, :value)
        in (contents[strategyArea(strategyId)] ?? const {}).entries)
      if (!key.startsWith(pendingPrefix)) key: value,
  };

  void refusedAsEnded(RecordResult result, int events, String label) {
    switch (result) {
      case NotSaved() || SaveInDoubt():
        return;
      case Saved(:final value)
          when value.outcomes.length == events &&
              value.outcomes.every(
                (outcome) =>
                    outcome is ReportNotApplicable &&
                    outcome.why is FromAnEndedSession,
              ):
        return;
      case _:
        throw StateError(
          '$label was not refused as from an ended session once per event: '
          '${describeSaving(result)}',
        );
    }
  }

  Future<void> endedSessionRead() async {
    final ended = (await sync()).queue.session.number;
    final endedFrom = await started();
    final livePages = [
      for (final page in server.rows.pages)
        if (page is LivePage) page.publicId,
    ];
    final page = livePages.isEmpty ? null : pick(livePages);
    final (ArrivedBase base, String kind) = switch ((random.nextInt(3), page)) {
      (0, final page?) => (pageReadOf(server.rows, page), 'page read'),
      (1, final page?) => (PageGone(page), 'page-gone answer'),
      _ => (headerReadOf(server.rows), 'header'),
    };
    if (teammates) teammate();
    if (await record([
          const ConnectionLost(),
          const ConnectionReturned(),
        ], 'reconnect') ==
        null) {
      return;
    }
    final before = storage.contents;
    final stale = [BaseArrived(base, session: ended, from: endedFrom)];
    final result = await store.record(testAccount, strategyId, stale);
    log.add(
      'a $kind from the ended session arrives -> ${describeSaving(result)}',
    );
    if (result is SaveInDoubt<Recorded, CommitRefusal>) {
      await reopen('the late $kind was in doubt');
      return;
    }
    refusedAsEnded(result, stale.length, 'a $kind from the ended session');
    if (!const MapEquality<String, String>().equals(
      rowsAndResults(before),
      rowsAndResults(storage.contents),
    )) {
      throw StateError('a $kind from a session that ended changed rows');
    }
    count('results from an ended session');
  }

  Future<void> sessionOpenedThenReopened() async {
    final opened = await record([
      const ConnectionReturned(),
    ], 'a session opened and never used');
    if (opened == null) return;
    final session = (await sync()).queue.session.number;
    final sessionFrom = await started();
    await reopen('before the session was used');
    if ((await sync()).queue.session.number == session) {
      throw StateError('a reopen handed out session $session again');
    }
    final before = storage.contents;
    final stale = [
      BaseArrived(
        pageReadOf(server.rows, openPage),
        session: session,
        from: sessionFrom,
      ),
    ];
    final result = await store.record(testAccount, strategyId, stale);
    log.add('a result from the unused session -> ${describeSaving(result)}');
    if (result is SaveInDoubt<Recorded, CommitRefusal>) {
      await reopen('the unused session result was in doubt');
      return;
    }
    refusedAsEnded(result, stale.length, 'a result from the unused session');
    if (!const MapEquality<String, String>().equals(
      rowsAndResults(before),
      rowsAndResults(storage.contents),
    )) {
      throw StateError('a result from an unused session changed rows');
    }
    count('results from an unused session');
  }

  Future<void> addedAgainWithAReadInFlight() async {
    final cloud = await sync();
    if (Tally.of(cloud.queue, clock).total > 0 || inFlight.isNotEmpty) return;
    faults = false;
    final old = cloud.queue.session.number;
    final oldFrom = readFrom(cloud.queue);
    final oldBase = headerReadOf(server.rows);
    final oldPage = pageReadOf(server.rows, openPage);
    final removed = await store.editLibrary([const RemoveStrategy(strategyId)]);
    if (removed is! Saved<LibraryEdited, LibraryRefusal>) {
      throw StateError('removing a strategy with nothing unsent: $removed');
    }
    if (teammates) teammate();
    final rows = server.rows;
    final reads = [
      for (final page in rows.pages)
        if (page is LivePage) pageReadOf(rows, page.publicId) as PageRead,
    ]..shuffle(random);
    final now = reads.take(random.nextInt(reads.length + 1)).toList();
    final added = await store.addCloudStrategy(
      testAccount,
      headerReadOf(rows),
      now,
    );
    if (added is! Saved<StrategySummary, LibraryRefusal>) {
      throw StateError('adding the strategy again: $added');
    }
    await liveIsCurrent();
    final later = reads.skip(now.length).toList();
    if (later.isNotEmpty) {
      await record([
        for (final read in later)
          BaseArrived(read, session: live, from: await started()),
      ], 'the rest of the import in a later call');
      count('imports in several calls');
    }
    final before = storage.contents;
    final stale = [
      BaseArrived(oldBase, session: old, from: oldFrom),
      if (oldPage is PageRead)
        BaseArrived(oldPage, session: old, from: oldFrom),
    ];
    final result = await store.record(testAccount, strategyId, stale);
    log.add(
      'a read from before the strategy was added again -> '
      '${describeSaving(result)}',
    );
    refusedAsEnded(result, stale.length, 'a read from the earlier copy');
    if (!const MapEquality<String, String>().equals(
      rowsAndResults(before),
      rowsAndResults(storage.contents),
    )) {
      throw StateError('a read from the strategy\'s earlier copy changed rows');
    }
    faults = true;
    count('added again with a read in flight');
  }

  Future<void> newerRowArrives() async {
    faults = false;
    final (pages, _) = await livePagesAndElements();
    if (pages.isNotEmpty) {
      await commitOp(
        elementAdd(fresh('op'), elementId: fresh('e'), pageId: pick(pages)),
      );
    }
    await store.close();
    final contents = editable(storage.contents);
    final area = strategyArea(strategyId);
    final name = PendingName(1 << 40).name;
    contents[area]![name] = '{"version":${cloudRowVersion + 1},"kind":"op"}';
    storage = MemoryStorage(contents);
    await open();
    final content = strategyOf(await store.readStrategy(strategyId));
    if (content.sync is! CloudHeld) {
      throw StateError('a newer queue row did not hold the strategy');
    }
    await listMatchesPages('a newer row held the queue');
    count('held queues compared against the list');
    await anotherAccountTries();
    final before = storage.contents;
    final refused = await store.commitAs(
      testAccount,
      strategyId,
      pageAdd(fresh('op'), fresh('page-')),
      seen: await seenIn(store),
    );
    if (refused case Refused(reason: QueueHeld())) {
    } else {
      throw StateError('a held strategy took an edit: $refused');
    }
    if (!sameContents(before, storage.contents)) {
      throw StateError('a held strategy wrote rows');
    }
    await store.close();
    contents[area]!.remove(name);
    storage = MemoryStorage(contents);
    await open();
    await restartSession();
    log.add('a newer build wrote a queue row and took it back');
    faults = true;
    count('held by a newer row');
  }

  Future<void> strategyGone() async {
    final queue = (await sync()).queue;
    final rows = await visible();
    server.exists = false;
    for (var tries = 0; tries < 20; tries++) {
      await readOne(const StrategyGone(), 'the strategy is gone');
      if (standingOf((await sync()).queue) == Standing.deletedOnServer) break;
    }
    final after = (await sync()).queue;
    if (standingOf(after) != Standing.deletedOnServer) {
      throw StateError('a gone strategy stands ${standingOf(after)}');
    }
    if (!const ListEquality<String>().equals(
      [for (final entry in after.entries) entry.id],
      [for (final entry in queue.entries) entry.id],
    )) {
      throw StateError('a gone strategy lost queue entries');
    }
    if (!const DeepCollectionEquality().equals(
      rowsWithRevisions(await visible()),
      rowsWithRevisions(rows),
    )) {
      throw StateError('a gone strategy lost rows');
    }
    count('strategies gone');
    await store.close();
  }

  void teammate() {
    final live = [
      for (final row in server.rows.elements)
        if (row is LiveElement) row,
    ];
    if (live.isEmpty) return;
    final target = pick(live);
    final elsewhere = [
      for (final page in server.rows.pages)
        if (page is LivePage && page.publicId != target.pagePublicId)
          page.publicId,
    ];
    final StrategyOp op = random.nextInt(4) == 0 && elsewhere.isNotEmpty
        ? ElementPatchOp(
            opId: fresh('t'),
            elementPublicId: target.publicId,
            expectedElementRevision: target.revision,
            pagePublicId: pick(elsewhere),
            payload: target.payload,
            sortIndex: 0,
          )
        : movePatch(
            fresh('t'),
            elementId: target.publicId,
            expected: target.revision,
            rotation: 30,
          );
    if (op case ElementPatchOp(pagePublicId: _?)) count('server moves');
    if (applyOp(server.rows, op) case final OpApplied done) {
      server.write(done);
      teammateEdited = true;
      log.add('teammate moves ${target.publicId}');
    }
  }

  Future<void> userActs({required bool draining}) async {
    final cloud = await sync();
    for (final entry in cloud.queue.entries) {
      final view = cloud.views[entry.id];
      final UserAction? action = switch ((entry, view)) {
        (
          PendingOp(),
          EntryView(state: NeedsUser(reason: RetriesExhausted())),
        ) =>
          UserRetried(entry.id),
        (PendingOp(), EntryView(state: NeedsUser())) => UserDiscarded(entry.id),
        _ => null,
      };
      if (action == null) continue;
      if (!teammates && action is! UserRetried && !userRemoved) {
        throw StateError(
          'the user was asked $action for ${entry.id}: '
          '${view?.state}, ${view?.holds}',
        );
      }
      if (await record([action], 'user ${action.runtimeType} ${entry.id}')
          case final recorded?) {
        if (action is UserDiscarded &&
            recorded.outcomes.single is ReportApplied) {
          userRemoved = true;
        }
      }
      return;
    }
  }

  Future<Object> observedState() async {
    final content = strategyOf(
      await reading(() => store.readStrategy(strategyId)),
    );
    return [
      switch (content.sync) {
        CloudStrategy(:final owner, :final queue) => [owner, queue],
        CloudHeld(:final owner, :final rows) => [
          owner,
          [for (final row in rows) '${row.ref.name}: ${row.problem}'],
        ],
        LocalStrategy() => throw StateError('the strategy reads as local'),
      },
      rowsWithRevisions(await visible()),
    ];
  }

  Future<void> anotherAccountTries() async {
    final content = strategyOf(
      await reading(() => store.readStrategy(strategyId)),
    );
    final held = content.sync is CloudHeld;
    final entries = switch (content.sync) {
      CloudStrategy(:final queue) => [
        for (final entry in queue.entries) entry.id,
      ],
      _ => <String>[],
    };
    final before = await observedState();
    final stored = {
      for (final MapEntry(:key, :value) in storage.contents.entries)
        key: {...value},
    };
    final commitsBefore = commits;
    final (_, live) = await livePagesAndElements();
    final target = live.isEmpty ? null : pick(live);
    final StrategyOp op = target == null
        ? pageAdd(fresh('b'), fresh('page-b'))
        : movePatch(
            fresh('b'),
            elementId: target.publicId,
            expected: target.revision,
            rotation: 45,
          );
    final attempt = inFlight.isEmpty ? 1 : inFlight.first.$1;
    final someEntry = entries.isEmpty ? 'op0' : pick(entries);
    final calls = <(String, Future<Saving<Object?, CommitRefusal>> Function())>[
      (
        'another account edits',
        () async => store.commitAs(
          otherAccount,
          strategyId,
          op,
          seen: await seenIn(store),
        ),
      ),
      (
        'another account edits in a batch',
        () async => store.commitAllAs(otherAccount, strategyId, [
          op,
        ], seen: await seenIn(store)),
      ),
      ('an edit naming no account', () => store.commit(strategyId, op)),
      (
        'another account claims $entries',
        () => store.record(otherAccount, strategyId, [
          BatchClaimed(clientId: clientId, opIds: entries, at: clock),
        ]),
      ),
      (
        'another account answers attempt $attempt',
        () => store.record(otherAccount, strategyId, [
          OpAnswered(
            attempt,
            AppliedAnswer(
              someEntry,
              revision: target?.revision ?? 1,
              life: fixtureLife,
            ),
          ),
        ]),
      ),
      (
        'another account chooses for $someEntry',
        () => store.record(otherAccount, strategyId, [
          random.nextBool() ? UserRetried(someEntry) : UserDiscarded(someEntry),
        ]),
      ),
      (
        'another account discards the queue',
        () => store.discardUnreadableQueue(
          otherAccount,
          strategyId,
          const DiscardsUnsentWork(),
        ),
      ),
      (
        'another account records that the account changed',
        () => store.record(otherAccount, strategyId, [const AccountChanged()]),
      ),
      (
        'another account records a connection',
        () => store.record(otherAccount, strategyId, [
          const ConnectionReturned(),
        ]),
      ),
      (
        'another account records a result of the current session',
        () => store.record(otherAccount, strategyId, [
          BaseArrived(
            headerReadOf(server.rows),
            session: this.live,
            from: ReadOfThisDevice(ReadStart(session: this.live, sequence: 0)),
          ),
        ]),
      ),
    ];
    final (label, call) = pick(calls);
    final result = await call();
    log.add('$label${held ? ' (held)' : ''} -> ${describeSaving(result)}');
    final namesNoAccount = label == 'an edit naming no account';
    switch (result) {
      case Refused(reason: AccountNeeded()) when namesNoAccount:
        count('refused for naming no account');
      case Refused(reason: WorkOfAnotherAccount(:final owner))
          when owner == OwnedBy(testAccount) && !namesNoAccount:
        count(
          held
              ? 'refused for another account while held'
              : 'refused for another account',
        );
        count(
          'refused for another account: ${label.split(' ').take(3).join(' ')}',
        );
      case _:
        throw StateError(
          '$label was not refused as it should be: ${describeSaving(result)}',
        );
    }
    if (commits != commitsBefore) throw StateError('$label made a commit');
    if (!const DeepCollectionEquality().equals(storage.contents, stored)) {
      throw StateError('$label changed what is stored');
    }
    if (!const DeepCollectionEquality().equals(await observedState(), before)) {
      throw StateError('$label changed what a read shows');
    }
  }

  void accountsCountedApart() {
    final strategies = [
      for (final summary in listOf(store).strategies)
        switch (summary.sync) {
          KeptInCloud(:final owner, :final tally) => (
            owner: owner,
            tally: tally,
          ),
          CloudUnverified(:final owner) => (owner: owner, tally: Tally.empty),
          KeptHere() => throw StateError('the cloud strategy is listed here'),
        },
    ];
    final (:owner, :tally) = strategies.single;
    if (owner != OwnedBy(testAccount)) {
      throw StateError('the strategy is listed as $owner');
    }
    final asMine =
        accountSyncState(
              strategies,
              network: Network.online,
              signedIn: SignedInAs(testAccount),
            )
            as SignedInSync;
    final asOther =
        accountSyncState(
              strategies,
              network: Network.online,
              signedIn: SignedInAs(otherAccount),
            )
            as SignedInSync;
    if (asMine.others.isNotEmpty ||
        !sameState(
          asMine.mine,
          syncStateOf(
            OwnedBy(testAccount),
            tally,
            network: Network.online,
            signedIn: SignedInAs(testAccount),
          ),
        ) ||
        asOther.mine is! AllSaved ||
        (tally.total == 0
            ? asOther.others.isNotEmpty
            : asOther.others[testAccount] != tally)) {
      throw StateError(
        'one account counted as the other: $tally as $asMine and $asOther',
      );
    }
    count('accounts counted apart');
  }

  Future<void> check() async {
    final cloud = await sync();
    for (final entry in cloud.queue.entries) {
      if (entry is! PendingOp) continue;
      final state = cloud.views[entry.id]!.state;
      final bad = switch (state) {
        Waiting() => server.landed(entry.id) || server.refused(entry.id),
        NeedsUser(reason: RefusedByServer()) => server.landed(entry.id),
        _ => false,
      };
      if (bad) throw StateError('${entry.id} is $state against the server');
    }
    accountsCountedApart();
    if (cloud.owner != testAccount) {
      throw StateError('the strategy reads as ${cloud.owner}\'s');
    }
    final listed = listOf(store).strategies.single.sync;
    if (listed case KeptInCloud(
      :final tally,
    ) when tally != Tally.of(cloud.queue, clock)) {
      throw StateError(
        'the library list says $tally, the queue ${Tally.of(cloud.queue, clock)}',
      );
    }
  }

  Future<void> stepOnce() async {
    clock = clock.add(Duration(milliseconds: random.nextInt(2000)));
    switch (random.nextInt(20)) {
      case < 7:
        await edit();
      case < 10:
        await claim();
      case < 13:
        await deliver();
      case 13:
        await restart();
      case 14:
        await lane();
      case 15:
        if (teammates) teammate();
      case 16 when random.nextBool():
        await anotherAccountTries();
      case 16 when random.nextInt(3) == 0:
        await unloadChangesNothing();
      case 16:
        await userActs(draining: false);
      case 17:
        if (random.nextInt(6) == 0) {
          await newerRowArrives();
        } else {
          await reopen('between two commits');
        }
      case 18 when random.nextInt(4) == 0:
        await addedAgainWithAReadInFlight();
      case 18 when random.nextInt(3) == 0:
        await sessionOpenedThenReopened();
      case 18 when random.nextInt(2) == 0:
        await switch (random.nextInt(5)) {
          0 => twoAcceptedMoves(),
          1 => editOfAcceptedAdd(),
          2 => random.nextBool() ? readerLearnsAgents() : damagedRowsArrive(),
          _ when teammates => pageGoneUnderQueuedMove(),
          _ => twoAcceptedMoves(),
        };
      case 18:
        final pages = [
          for (final page in (await visible()).pages) page.publicId,
        ];
        if (pages.isNotEmpty) openPage = pick(pages);
      case _:
        await record([
          switch (random.nextInt(5)) {
            0 => const AccountChanged(),
            1 || 2 => const ConnectionLost(),
            _ => const ConnectionReturned(),
          },
        ], 'connection');
    }
    await check();
  }

  Future<void> drain() async {
    faults = false;
    for (var round = 0; round < 200; round++) {
      final queue = (await sync()).queue;
      if (queue.entries.isEmpty) break;
      clock = clock.add(const Duration(minutes: 1));
      await lane();
      await userActs(draining: true);
      await claim();
      while (inFlight.isNotEmpty) {
        await deliver();
      }
    }
    final queue = (await sync()).queue;
    if (queue.entries.isNotEmpty) {
      final views = (await sync()).views;
      throw StateError(
        'did not drain: ${[for (final entry in queue.entries) '${entry.id} ${views[entry.id]?.state} ${views[entry.id]?.holds}'].join('; ')}',
      );
    }
    await readOne(headerReadOf(server.rows), 'final read');
    for (final page in server.rows.pages) {
      if (page is LivePage) {
        await readOne(pageReadOf(server.rows, page.publicId), 'final read');
      }
    }
    final shown = rowsWithRevisions(liveOnly(await visible()));
    final held = rowsWithRevisions(liveOnly(server.rows));
    if (!const DeepCollectionEquality().equals(shown, held)) {
      final keys = {...shown.keys, ...held.keys}.where(
        (key) => !const DeepCollectionEquality().equals(shown[key], held[key]),
      );
      throw StateError(
        'the store shows what the server does not hold: '
        '${[for (final key in keys) '$key: ${shown[key]} vs ${held[key]}'].join('; ')}',
      );
    }
    if (!teammateEdited && !userRemoved) {
      var want = initialRows();
      for (final op in reference) {
        if (applyOp(want, onVisible(want, op)) case final OpApplied done) {
          want = bornWhereNew(want, done.rows, addedLife);
        }
      }
      final wanted = liveContent(want);
      final got = liveContent(server.rows);
      if (!const DeepCollectionEquality().equals(wanted, got)) {
        final keys = {...wanted.keys, ...got.keys}.where(
          (key) =>
              !const DeepCollectionEquality().equals(wanted[key], got[key]),
        );
        throw StateError(
          'the server does not hold the user\'s edits: '
          '${[for (final key in keys) '$key: ${wanted[key]} vs ${got[key]}'].join('; ')}',
        );
      }
    }
    await store.close();
  }
}

StrategyRowSet liveOnly(StrategyRowSet rows) => StrategyRowSet(
  strategy: rows.strategy,
  pages: [
    for (final page in rows.pages)
      if (page is LivePage) page,
  ],
  settings: [
    for (final settings in rows.settings)
      if (rows.page(settings.pagePublicId) is LivePage) settings,
  ],
  elements: [
    for (final row in rows.elements)
      if (row is LiveElement && rows.page(row.pagePublicId) is LivePage) row,
  ],
  lineupGroups: [
    for (final row in rows.lineupGroups)
      if (row is LiveLineupGroup && rows.page(row.pagePublicId) is LivePage)
        row,
  ],
);

bool sameState(SyncState a, SyncState b) => switch ((a, b)) {
  (AllSaved(), AllSaved()) => true,
  (
    Outstanding(face: final x, tally: final t),
    Outstanding(:final face, :final tally),
  ) =>
    x == face && t == tally,
  _ => false,
};

Future<void> runSeed(int seed, int steps) async {
  final model = StoreModel(seed, teammates: seed.isOdd);
  try {
    await model.start();
    for (var i = 0; i < steps; i++) {
      await model.stepOnce();
    }
    if (seed % 9 == 0) {
      await model.strategyGone();
    } else {
      await model.drain();
    }
  } on StateError catch (error) {
    fail(
      'seed $seed failed: ${error.message}\n'
      'rerun with CLOUD_STORE_MODEL_SEED=$seed CLOUD_STORE_MODEL_STEPS=$steps\n'
      'steps:\n${model.log.join('\n')}',
    );
  }
}

void main() {
  final environment = Platform.environment;
  final steps =
      int.tryParse(environment['CLOUD_STORE_MODEL_STEPS'] ?? '') ?? 120;
  final one = int.tryParse(environment['CLOUD_STORE_MODEL_SEED'] ?? '');
  final seeds =
      int.tryParse(environment['CLOUD_STORE_MODEL_SEEDS'] ?? '') ?? 40;
  test('the model run through the store keeps every edit, with disk equal '
      'to memory after every commit, across reopens and failed '
      'commits', () async {
    for (final seed
        in one == null ? [for (var s = 1; s <= seeds; s++) s] : [one]) {
      await runSeed(seed, steps);
    }
    if (environment['CLOUD_STORE_MODEL_COUNTS'] == '1') {
      stdout.writeln(counted);
    }
    final fullSweep = seeds >= 40 && steps >= 120;
    if (one != null ||
        !(fullSweep || environment['CLOUD_STORE_MODEL_COVERAGE'] == '1')) {
      return;
    }
    for (final what in [
      'commits answered unknown',
      'commits refused',
      'page copies',
      'copied page deletes',
      'results from an ended session',
      'results from an unused session',
      'imports in several calls',
      'server moves',
      'reads checked for commits',
      'mixed event lists',
      'page reads in one call',
      'added again with a read in flight',
      'held by a newer row',
      'moves to another page',
      'two accepted moves of one row',
      'edits of a row shown only by accepted work',
      'pages gone under a queued move',
      'held queues compared against the list',
      'readers that learned a payload',
      'damaged and unknown rows compared against the list',
      'unloads that changed nothing',
      'events delivered again after a commit that was not stored',
      'memory checked after a call that was not stored',
      'strategies gone',
      'refused for another account',
      'refused for naming no account',
      'refused for another account while held',
      'accounts counted apart',
    ]) {
      expect(counted[what] ?? 0, greaterThan(0), reason: what);
    }
    expect(counted['doubtful edit lost'] ?? 0, greaterThan(0));
    expect(counted['doubtful edit landed'] ?? 0, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
