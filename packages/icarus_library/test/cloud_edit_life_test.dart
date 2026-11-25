import 'dart:async';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_set_aside_test.dart'
    show laterLife, replaced, setAsideIds, setsAside;
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

final class PausesSetAside extends ForwardingLease {
  PausesSetAside(super.inner, this.paused, this.resume);

  final Completer<void> paused;
  final Future<void> resume;

  @override
  Future<Committing> commit(List<Change> changes) async {
    if (setsAside(changes) && !paused.isCompleted) {
      paused.complete();
      await resume;
    }
    return super.commit(changes);
  }
}

void main() {
  group('an edit names the strategy life its view showed', () {
    test('an edit made on the view of the replaced life, arriving after the '
        'record adopted the new one, is set aside and not queued', () {
      final client = Client();
      client.read(replaced(initialRows()));
      final step = client.step(
        UserEdited(
          (client.editEvent(movePatch('late')) as UserEdited).edit,
          madeOn: viewedLife,
        ),
      );
      expect(step, isA<Stepped>());
      expect(client.queue.entries, isEmpty);
      expect(setAsideIds(client.queue), ['late']);
      final generation =
          (client.queue.strategy.setAside as SetAside).generations.single;
      expect(generation.writtenIn, viewedLife);
      expect(generation.replacedBy, laterLife);
    });

    test('an edit naming the record\'s own life is queued as before', () {
      final client = Client();
      client.read(replaced(initialRows()));
      client.must(
        UserEdited(
          (client.editEvent(movePatch('now')) as UserEdited).edit,
          madeOn: laterLife,
        ),
      );
      expect([for (final entry in client.queue.entries) entry.id], ['now']);
      expect(setAsideIds(client.queue), isEmpty);
    });

    test('an edit naming a later life than the record\'s is kept aside and '
        'never applied, as one naming an earlier life is', () {
      final client = Client();
      final step = client.step(
        UserEdited(
          (client.editEvent(movePatch('ahead')) as UserEdited).edit,
          madeOn: laterLife,
        ),
      );
      expect(step, isA<Stepped>());
      expect(client.queue.entries, isEmpty);
      expect(setAsideIds(client.queue), ['ahead']);
      final generation =
          (client.queue.strategy.setAside as SetAside).generations.single;
      expect(generation.writtenIn, laterLife);
      expect(generation.replacedBy, viewedLife);
    });

    test('through the store: an edit made on the old view is refused to the '
        'caller as an edit of a replaced strategy, kept aside across a '
        'restart, and never written onto the new strategy', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      final oldView = await seenIn(store);
      await recordAll(store, [
        BaseArrived(
          headerReadOf(replaced(initialRows())),
          session: await sessionOf(store),
          point: tick(),
        ),
      ]);
      final committed = await store.commitAs(
        testAccount,
        strategyId,
        movePatch('late', x: 77),
        seen: oldView,
      );
      expect(
        committed,
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<EditOfAReplacedStrategy>(),
        ),
      );
      final queue = (await syncOf(store)).queue;
      expect(queue.entries, isEmpty);
      expect(setAsideIds(queue), ['late']);
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      expect(setAsideIds((await syncOf(store)).queue), ['late']);
      final claimed = await store.record(testAccount, strategyId, [
        BatchClaimed(clientId: clientId, opIds: const ['late'], at: now),
      ]);
      expect(
        (claimed as Saved<Recorded, CommitRefusal>).value.outcomes.single,
        isA<ReportNotApplicable>(),
      );
    });

    test('a rename submitted from the old view while the adoption is being '
        'written is set aside with the old edits, never claimed under the '
        'replacement\'s life, though both lives are at revision 1', () async {
      final storage = MemoryStorage();
      final setup = await openCloudStore(MemoryEngine(storage));
      await addCloud(setup, initialRows());
      await recordAll(setup, [const AppRestarted(build: build)]);
      savedValue(
        await setup.commitAs(
          testAccount,
          strategyId,
          movePatch('move', x: 31),
          seen: await seenIn(setup),
        ),
      );
      await setup.close();
      final paused = Completer<void>();
      final release = Completer<void>();
      final store = await openCloudStore(
        WrappingEngine(
          MemoryEngine(storage),
          (lease) => PausesSetAside(lease, paused, release.future),
        ),
      );
      await recordAll(store, [const AppRestarted(build: build)]);
      final replacement = replaced(initialRows());
      expect(replacement.strategy.revision, 1);
      final oldView = await seenIn(store);
      final adoption = store.record(testAccount, strategyId, [
        BaseArrived(
          headerReadOf(replacement),
          session: await sessionOf(store),
          point: tick(),
        ),
      ]);
      await paused.future;
      final rename = store.commitAs(
        testAccount,
        strategyId,
        const StrategyPatchOp(
          opId: 'rename',
          expectedStrategyRevision: 1,
          name: 'Retake B',
        ),
        seen: oldView,
      );
      release.complete();
      savedValue(await adoption);
      expect(
        await rename,
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<EditOfAReplacedStrategy>(),
        ),
      );
      final queue = (await syncOf(store)).queue;
      expect(queue.entries, isEmpty);
      expect(setAsideIds(queue), ['move', 'rename']);
      final claimed = await store.record(testAccount, strategyId, [
        BatchClaimed(clientId: clientId, opIds: const ['rename'], at: now),
      ]);
      expect(
        (claimed as Saved<Recorded, CommitRefusal>).value.outcomes.single,
        isA<ReportNotApplicable>(),
      );
      final header = await store.readStrategy(strategyId);
      expect(
        ((header as Found<StrategyContent>).value.strategy as ReadableStrategy)
            .name,
        replacement.strategy.name,
      );
    });
  });
}
