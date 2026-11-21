import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

final class SubsetLease extends ForwardingLease {
  SubsetLease(super.inner, this.model);

  final StoreModel model;

  @override
  Future<Committing> commit(List<Change> changes) async {
    if (model.faults && model.random.nextInt(14) == 0) {
      final subset = [
        for (final change in changes)
          if (model.random.nextBool()) change,
      ];
      model.subsets++;
      model.log.add(
        'commit answered unknown; ${subset.length} of '
        '${changes.length} changes landed',
      );
      if (subset.isNotEmpty) await super.commit(subset);
      return const CommitUnknown(DeviceFailure('the reply was lost'));
    }
    return super.commit(changes);
  }
}

final counted = <String, int>{};

void count(String what, [int by = 1]) =>
    counted[what] = (counted[what] ?? 0) + by;

final class StoreModel {
  StoreModel(this.seed, {required this.teammates}) : random = Random(seed);

  final int seed;
  final bool teammates;
  final Random random;
  final storage = MemoryStorage();
  final server = Server();
  final log = <String>[];
  final reference = <StrategyOp>[];
  final inFlight = <(int, String, List<StrategyOp>)>[];
  late LibraryStore store;
  DateTime clock = now;
  String clientId = 'client-0';
  String build = 'build-0';
  int restarts = 0;
  int subsets = 0;
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
        (lease) => SubsetLease(lease, this),
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
      if (await settled(result, 'add the cloud strategy')) break;
      count('add resumed');
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
        throw StateError('$label was not saved: $failure');
      case Refused(:final reason):
        log.add('$label refused: $reason');
        return false;
    }
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
    final roll = random.nextInt(12);
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
    } else if (roll == 10 && pages.isNotEmpty) {
      final page = rows.page(pick(pages))! as LivePage;
      op = PagePatchOp(
        opId: opId,
        pagePublicId: page.publicId,
        expectedPageRevision: page.revision,
        name: 'Renamed ${random.nextInt(100)}',
      );
    } else if (pages.length < 4) {
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
      case SaveInDoubt():
        count('save in doubt');
        await reopen('edit $opId was in doubt');
        final after = {
          for (final entry in (await sync()).queue.entries) entry.id,
        };
        final landed =
            after.contains(opId) || before.difference(after).isNotEmpty;
        log.add('edit $opId ${landed ? 'landed' : 'did not land'}');
        count(landed ? 'doubtful edit landed' : 'doubtful edit lost');
        if (landed) reference.add(op);
      case NothingToSave() || Refused():
        break;
      case NotSaved(:final failure):
        throw StateError('edit not saved: $failure');
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
    await record([BaseArrived(base, read: read, startedAt: clock)], label);
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
    await readOne(headerReadOf(server.rows), 'read strategy');
    final queue = (await sync()).queue;
    final views = entryViews(queue, clock);
    final pages = {
      openPage,
      for (final entry in queue.entries)
        if (entry is PendingOp &&
            (views[entry.id]!.state is Accepted ||
                views[entry.id]!.holds.any(
                  (hold) => hold is AwaitingPageRead || hold is AwaitingBase,
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
        await reopen('between two commits');
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

Future<void> runSeed(int seed, int steps) async {
  final model = StoreModel(seed, teammates: seed.isOdd);
  try {
    await model.start();
    for (var i = 0; i < steps; i++) {
      await model.stepOnce();
    }
    await model.drain();
    count('commits answered unknown', model.subsets);
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
  test('the model run through the store keeps every edit across reopens and '
      'commits that land in part', () async {
    for (final seed
        in one == null ? [for (var s = 1; s <= seeds; s++) s] : [one]) {
      await runSeed(seed, steps);
    }
    if (environment['CLOUD_STORE_MODEL_COUNTS'] == '1') {
      stdout.writeln(counted);
    }
    if (one != null) return;
    expect(counted['commits answered unknown'] ?? 0, greaterThan(20));
    expect(counted['doubtful edit lost'] ?? 0, greaterThan(0));
    expect(counted['doubtful edit landed'] ?? 0, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
