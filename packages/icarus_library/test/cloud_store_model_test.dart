import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:icarus_library/src/store/layout.dart'
    show PendingName, strategyArea;
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
      } else if (name == 'read/header' || name.startsWith('read/page/')) {
        final (page, group) =
            (groupFromText(text, header: name == 'read/header')
                    as CloudRowRead<(String?, EvidenceGroup)>)
                .value;
        groups[page] = group;
      }
    }
    entries = switch (entriesFrom(pending)) {
      EntriesRead(:final entries) => [
        for (final entry in entries) entryToJson(entry),
      ],
      EntriesUnreadable(:final problem) => throw StateError(problem),
    };
    facts = switch (rows['cloud']) {
      final text? => factsToJson(
        (factsFromText(text) as CloudRowRead<StrategyFacts>).value,
      ),
      null => null,
    };
    counters = switch (rows['counters']) {
      final text? => (countersFromText(text) as CloudRowRead<Counters>).value,
      null => null,
    };
  }

  late final List<Map<String, Object?>> entries;
  final attempts = <int, Map<String, Object?>>{};
  final groups = <String?, EvidenceGroup>{};
  late final Map<String, Object?>? facts;
  late final Counters? counters;
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
  bool userRemoved = false;
  bool teammateEdited = false;
  String openPage = 'page-a';

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
  }

  Future<CloudStrategy> sync() async => cloudOf(
    switch (await store.readStrategy(strategyId)) {
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
    final memory = (await sync()).queue;
    final disk = DiskQueue(storage.contents[strategyArea(strategyId)] ?? {});
    final want = {
      'entries': [for (final entry in memory.entries) entryToJson(entry)],
      'attempts': {
        for (final attempt in memory.attempts.values)
          '${attempt.number}': attemptToJson(attempt),
      },
      'facts': factsToJson(memory.strategy),
      'counters': [memory.nextAttempt, memory.nextRead],
    };
    final got = {
      'entries': disk.entries,
      'attempts': {
        for (final MapEntry(:key, :value) in disk.attempts.entries)
          '$key': value,
      },
      'facts': disk.facts,
      'counters': [disk.counters?.nextAttempt, disk.counters?.nextRead],
    };
    if (!const DeepCollectionEquality().equals(want, got)) {
      throw StateError('after $label the disk holds $got, memory $want');
    }
    final groups = evidenceGroups(memory.base);
    if (!const MapEquality<String?, EvidenceGroup>().equals(
      groups,
      disk.groups,
    )) {
      throw StateError(
        'after $label the evidence on disk differs from memory: '
        '${groups.keys} vs ${disk.groups.keys}',
      );
    }
    final mine = await visible();
    final summary = listOf(store).strategies.single;
    final reopened = await openCloudStore(
      MemoryEngine(MemoryStorage(storage.contents)),
      build: build,
      clock: () => clock,
    );
    final listed = listOf(reopened).strategies.single;
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

  Future<Recorded?> record(List<QueueEvent> events, String label) async {
    final result = await store.record(strategyId, events);
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
    if (!await settled(result, label)) return null;
    await diskEqualsMemory(label);
    final recorded = (result as Saved<Recorded, CommitRefusal>).value;
    for (final outcome in recorded.outcomes) {
      if (outcome case ReportApplied()) count('recorded');
    }
    return recorded;
  }

  Future<StrategyRowSet> visible() async {
    final content = strategyOf(await store.readStrategy(strategyId));
    final elements = <ElementRow>[];
    for (final page in content.pages) {
      elements.addAll(
        pageOf(await store.readPage(strategyId, page.publicId)).elements,
      );
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
    final before = {for (final entry in (await sync()).queue.entries) entry.id};
    final result = await store.commit(strategyId, op);
    log.add(
      'edit $opId ${op.type.wireName} ${targetOf(op)} -> ${describeSaving(result)}',
    );
    switch (result) {
      case Saved():
        reference.add(op);
        await diskEqualsMemory('edit $opId');
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
      case NothingToSave() || Refused() || NotSaved():
        break;
    }
  }

  Future<void> claim() async {
    final cloud = await sync();
    if (standingOf(cloud.queue) != Standing.good) return;
    String? owner;
    final ids = <String>[];
    for (final entry in cloud.queue.entries) {
      if (ids.length == 4) break;
      final view = cloud.views[entry.id];
      if (view == null || !view.sendable) continue;
      final mine = switch (view.state) {
        AnswerUnknown(:final clientId) => clientId,
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
    final started = await record([const ReadStarted()], 'start $label');
    if (started == null) return;
    final read = effectsOf(started).whereType<ReadNumbered>().single.read;
    await record([BaseArrived(base, read: read)], label);
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
      case Standing.good || Standing.deletedOnServer:
        break;
    }
    if (random.nextInt(4) == 0) {
      await staleRead();
    }
    await readOne(headerReadOf(server.rows), 'read strategy');
    final queue = (await sync()).queue;
    final views = entryViews(queue, clock);
    final pages = {
      openPage,
      for (final entry in queue.entries)
        if (entry is PendingOp &&
            (views[entry.id]!.state is Accepted ||
                views[entry.id]!.holds.any(
                  (hold) => hold is AwaitingRead || hold is AwaitingBase,
                )))
          ...pagesOf(entry),
    };
    for (final page in pages) {
      await readOne(pageReadOf(server.rows, page), 'read $page');
    }
    final after = await sync();
    final reissue = {
      for (final entry in after.queue.entries)
        if (after.views[entry.id]?.go is NeedsFreshId) entry.id: fresh('re'),
    };
    if (reissue.isNotEmpty) await record([Reissue(reissue)], 'reissue');
  }

  Future<void> staleRead() async {
    final first = await record([const ReadStarted()], 'start an early read');
    if (first == null) return;
    final early = effectsOf(first).whereType<ReadNumbered>().single.read;
    final earlyBase = headerReadOf(server.rows);
    if (teammates) teammate();
    final later = await record([const ReadStarted()], 'start a later read');
    if (later == null) return;
    final read = effectsOf(later).whereType<ReadNumbered>().single.read;
    if (await record([
          BaseArrived(headerReadOf(server.rows), read: read),
        ], 'the later read arrives first') ==
        null) {
      return;
    }
    final before = storage.contents;
    final result = await store.record(strategyId, [
      BaseArrived(earlyBase, read: early),
    ]);
    log.add('the early read arrives last -> ${describeSaving(result)}');
    if (!sameContents(before, storage.contents)) {
      throw StateError('a read older than one already taken wrote rows');
    }
    count('stale reads');
  }

  Future<void> newerRowArrives() async {
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
    final before = storage.contents;
    final refused = await store.commit(
      strategyId,
      pageAdd(fresh('op'), fresh('page-')),
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
    log.add('a newer build wrote a queue row and took it back');
    count('held by a newer row');
  }

  Future<void> strategyGone() async {
    final queue = (await sync()).queue;
    final rows = await visible();
    server.exists = false;
    await readOne(const StrategyGone(), 'the strategy is gone');
    final after = (await sync()).queue;
    if (standingOf(after) != Standing.deletedOnServer) {
      throw StateError('a gone strategy stands ${standingOf(after)}');
    }
    if (!const DeepCollectionEquality().equals(
      [for (final entry in after.entries) entryToJson(entry)],
      [for (final entry in queue.entries) entryToJson(entry)],
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
    final op = movePatch(
      fresh('t'),
      elementId: target.publicId,
      expected: target.revision,
      rotation: 30,
    );
    if (applyOp(server.rows, op) case final OpApplied done) {
      server.rows = server.rows.withRows(done.rows);
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
          EntryView(state: AnswerUnknown(backoff: RetriesExhausted())),
        ) =>
          UserRetried(entry.id),
        (PendingOp(), EntryView(state: ServerRefused())) ||
        (PendingOp(), EntryView(go: NeedsUser())) => UserDiscarded(entry.id),
        _ => null,
      };
      if (action == null) continue;
      if (!teammates && action is! UserRetried && !userRemoved) {
        throw StateError(
          'the user was asked $action for ${entry.id}: '
          '${view?.state}, ${view?.go}, ${view?.holds}',
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

  Future<void> check() async {
    final cloud = await sync();
    for (final entry in cloud.queue.entries) {
      if (entry is! PendingOp) continue;
      final state = cloud.views[entry.id]!.state;
      final bad = switch (state) {
        NeverSent() => server.landed(entry.id),
        ServerRefused() => server.landed(entry.id),
        Accepted() => server.refused(entry.id),
        Claimed() || AnswerUnknown() => false,
      };
      if (bad) throw StateError('${entry.id} is $state against the server');
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
      case 16:
        await userActs(draining: false);
      case 17:
        if (random.nextInt(6) == 0) {
          await newerRowArrives();
        } else {
          await reopen('between two commits');
        }
      case 18:
        final pages = [
          for (final page in (await visible()).pages) page.publicId,
        ];
        if (pages.isNotEmpty) openPage = pick(pages);
      case _:
        await record([
          random.nextBool()
              ? const ConnectionLost()
              : const ConnectionReturned(),
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
      throw StateError('did not drain: ${queue.entries}');
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
          want = want.withRows(done.rows);
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
      'rerun with CLOUD_STORE_MODEL_SEED=$seed\n'
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
    if (one != null) return;
    for (final what in [
      'commits answered unknown',
      'commits refused',
      'page copies',
      'copied page deletes',
      'stale reads',
      'held by a newer row',
      'strategies gone',
    ]) {
      expect(counted[what] ?? 0, greaterThan(0), reason: what);
    }
    expect(counted['doubtful edit lost'] ?? 0, greaterThan(0));
    expect(counted['doubtful edit landed'] ?? 0, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
