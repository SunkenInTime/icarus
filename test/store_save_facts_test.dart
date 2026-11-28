import 'dart:math';

import 'package:flutter/painting.dart' show Offset, Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/canvas_shows.dart';
import 'package:icarus/strategy/store_save_facts.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus_library/icarus_library.dart';

import 'library_store/sender_world.dart';
import 'library_store/server_fixtures.dart';

class _SettledQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: strategyId,
        clientId: 'facts-client',
        durableLoaded: true,
      );

  @override
  void setActiveStrategy(
    String? strategyPublicId, {
    required String? accountId,
  }) {}

  void settleAgain() => state = state.copyWith(isFlushing: false);
}

class _NoMedia extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);

  void settleAgain() => state = CloudMediaUploadQueueState(
        jobs: List.empty(),
        isProcessing: false,
      );
}

class _ServedSnapshots extends RemoteEditorSnapshotNotifier {
  _ServedSnapshots(this.served);

  app.RemoteEditorSnapshot served;

  @override
  Future<app.RemoteEditorSnapshot?> build() async => served;

  void serve(app.RemoteEditorSnapshot next) {
    served = next;
    state = AsyncData(next);
  }

  @override
  Future<app.RemotePageSnapshot?> setActivePage(
    String? pagePublicId, {
    app.RemotePageSnapshot? fetched,
  }) async =>
      served.activePage;

  @override
  Future<void> refresh() async => state = AsyncData(served);

  @override
  bool answeredOnCurrentConnection(app.RemotePageSnapshot? page) => true;
}

app.RemoteEditorSnapshot _snapshotOf(StrategyRowSet rows) {
  final list = pageList(rows);
  return app.RemoteEditorSnapshot(
    shell: app.RemoteStrategyShell(
      header: list.header,
      pages: [for (final page in list.pages) page.page],
    ),
    activePage: pageSnapshot(rows),
  );
}

FakeServer _server() => FakeServer()
  ..owners[strategyId] = servedAccount
  ..rows[strategyId] = serverRows()
  ..clock = () => DateTime.now().toUtc();

void _teammateMoves(FakeServer server, Offset to) {
  final rows = server.rows[strategyId]!;
  final agent = rows.elements.whereType<LiveElement>().single;
  server.teammate(
    strategyId,
    ElementPatchOp(
      opId: 'teammate-${to.dx}',
      elementPublicId: agent.publicId,
      expectedElementRevision: agent.revision,
      payload: ElementPayload(
        kind: agent.payload.kind,
        payloadVersion: agent.payload.payloadVersion,
        data: {
          ...agent.payload.data.toJson(),
          'position': {'dx': to.dx, 'dy': to.dy},
        },
      ),
    ),
  );
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<(ProviderContainer, _ServedSnapshots)> _editorOn(
  FakeServer server,
) async {
  final remote = _ServedSnapshots(_snapshotOf(server.rows[strategyId]!));
  final container = ProviderContainer(overrides: [
    remoteEditorSnapshotProvider.overrideWith(() => remote),
    strategyOpQueueProvider.overrideWith(_SettledQueue.new),
    cloudMediaUploadQueueProvider.overrideWith(_NoMedia.new),
    cloudMediaAccountIdProvider.overrideWithValue(servedAccount.subject),
    cloudCopyScopeProvider.overrideWithValue(null),
  ]);
  addTearDown(container.dispose);
  container.read(strategyProvider.notifier).setFromState(const StrategyState(
        strategyId: strategyId,
        strategyName: 'B split',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      ));
  container.listen(strategyPageSessionProvider, (_, __) {});
  await container.read(remoteEditorSnapshotProvider.future);
  container.read(canvasShowsProvider.notifier).shown(strategyId, pageId);
  await container
      .read(strategyPageSessionProvider.notifier)
      .initializeForStrategy(
        strategyId: strategyId,
        source: StrategySource.cloud,
        selectFirstPageIfNeeded: true,
      );
  return (container, remote);
}

Offset _agentOnCanvas(ProviderContainer container) =>
    container.read(agentProvider).single.position;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  group('store ahead of server is the package\'s own answer', () {
    final owners = [OwnedBy(servedAccount), const OwnerUnreadable()];
    final signIns = [
      SignedInAs(servedAccount),
      SignedInAs(otherAccount),
      const SignedOut(),
    ];

    void agreesWithThePackage(Tally tally) {
      for (final owner in owners) {
        for (final signedIn in signIns) {
          final package = syncStateOf(
            owner,
            tally,
            network: Network.online,
            signedIn: signedIn,
          );
          final app = storeAheadOfServerOf(KeptInCloud(owner, tally), signedIn);
          expect(
            app is StoreMatchesServer,
            package is AllSaved,
            reason: '$tally owned by $owner for $signedIn: '
                'the package says $package, the app $app',
          );
        }
      }
    }

    Tally generated(Random random) {
      int some() => random.nextInt(4) == 0 ? random.nextInt(3) + 1 : 0;
      return Tally(
        standing: Standing.values[random.nextInt(4) == 0
            ? random.nextInt(Standing.values.length)
            : 0],
        waiting: {for (final why in Underway.values) why: some()},
        attention: {for (final why in Attention.values) why: some()},
        unreadable: some(),
        readsOwed: some(),
        readsRefused: some(),
        setAside: some(),
        notYetRead: some(),
      );
    }

    test('over generated tallies, matches the server only when all is saved',
        () {
      final random = Random(892);
      for (var i = 0; i < 3000; i++) {
        agreesWithThePackage(generated(random));
      }
      agreesWithThePackage(Tally.empty);
    });

    test('edits set aside alone are not matching the server', () {
      final tally = Tally(standing: Standing.good, setAside: 1);
      agreesWithThePackage(tally);
      expect(
        storeAheadOfServerOf(
          KeptInCloud(OwnedBy(servedAccount), tally),
          SignedInAs(servedAccount),
        ),
        isA<StoreNeedsUser>(),
      );
    });

    test('a refused read alone is not matching the server', () {
      final tally = Tally(standing: Standing.good, readsRefused: 1);
      agreesWithThePackage(tally);
      expect(
        storeAheadOfServerOf(
          KeptInCloud(OwnedBy(servedAccount), tally),
          SignedInAs(servedAccount),
        ),
        isA<StoreNeedsUser>(),
      );
    });

    for (final standing in Standing.values.where((s) => s != Standing.good)) {
      test(
          'standing ${standing.name} with nothing waiting is not matching '
          'the server', () {
        final tally = Tally(standing: standing);
        agreesWithThePackage(tally);
        expect(
          storeAheadOfServerOf(
            KeptInCloud(OwnedBy(servedAccount), tally),
            SignedInAs(servedAccount),
          ),
          isA<StoreNeedsUser>(),
        );
      });
    }

    test('counts what the package calls unsent work', () {
      final tally = Tally(
        standing: Standing.good,
        waiting: {Underway.unsent: 2},
        unreadable: 1,
        setAside: 1,
        readsOwed: 4,
      );
      expect(
        storeAheadOfServerOf(
          KeptInCloud(OwnedBy(servedAccount), tally),
          SignedInAs(servedAccount),
        ),
        isA<StoreNeedsUser>()
            .having((ahead) => ahead.ops, 'ops', tally.unsentWork),
      );
    });
  });

  group('store ahead of server', () {
    StrategySaveStateNotifier fedFrom(World world, ProviderContainer c) {
      final notifier = c.read(strategySaveStateProvider.notifier)
        ..beginStoreOwned();
      final feed = feedStoreAheadOfServer(
        world.store,
        strategyId,
        SignedInAs(servedAccount),
        notifier.noteStoreAheadOfServer,
      );
      addTearDown(feed.cancel);
      return notifier;
    }

    ProviderContainer container() {
      final c = ProviderContainer(overrides: [
        strategyOpQueueProvider.overrideWith(_SettledQueue.new),
        cloudMediaUploadQueueProvider.overrideWith(_NoMedia.new),
      ]);
      c.read(strategyProvider.notifier).setFromState(const StrategyState(
            strategyId: strategyId,
            strategyName: 'B split',
            source: StrategySource.cloud,
            storageDirectory: null,
            isOpen: true,
          ));
      return c;
    }

    StoreAheadOfServer aheadIn(ProviderContainer c) =>
        c.read(strategySaveStateProvider).storeOwned!.storeAheadOfServer;

    test(
        'is read from the store as work is committed offline and lands, and '
        'never marks the canvas unsaved', () {
      inWorld((world) {
        final c = container();
        addTearDown(c.dispose);
        fedFrom(world, c);
        world.settle();
        expect(aheadIn(c), isA<StoreMatchesServer>());

        world.connection = null;
        world.commitMove(1);
        world.settle();
        expect(aheadIn(c), isA<StoreSending>());
        expect((aheadIn(c) as StoreSending).ops, 1);
        final save = c.read(strategySaveStateProvider);
        expect(save.isDirty, isFalse);
        expect(save.storeOwned!.canvasAheadOfStore, isFalse);

        world.connection = 1;
        world.settle(const Duration(seconds: 5));
        expect(world.server.calls.single.opIds, ['move-1']);
        expect(aheadIn(c), isA<StoreMatchesServer>());
        expect(c.read(strategySaveStateProvider).isDirty, isFalse);
      });
    });

    test(
        'a store-owned strategy whose list shows a page it has never read, '
        'with nothing else outstanding, matches the server (the chip shows it '
        'synced)',
        () {
      inWorld((world) {
        final c = container();
        addTearDown(c.dispose);
        fedFrom(world, c);
        world.settle();
        world.secondPageOnServer();
        world.recordRead([world.server.headerOf(strategyId)]);
        expect(world.cloud().queue.shown.pages.keys, contains('p2'));
        expect(world.cloud().queue.shown.content.containsKey('p2'), isFalse);
        expect(aheadIn(c), isA<StoreMatchesServer>());
      });
    });

    test('names work the server refused as needing the user', () {
      inWorld((world) {
        final c = container();
        addTearDown(c.dispose);
        fedFrom(world, c);
        world.teammateMoves(1);
        world.sleep(const Duration(minutes: 1));
        world.commitMove(2);
        world.settle(const Duration(seconds: 5));
        expect(aheadIn(c), isA<StoreNeedsUser>());
        expect(c.read(strategySaveStateProvider).isDirty, isFalse);
      });
    });

    test('an edit marked after a handover started keeps the canvas ahead', () {
      final c = container();
      addTearDown(c.dispose);
      final notifier = c.read(strategySaveStateProvider.notifier)
        ..beginStoreOwned()
        ..markDirty();
      final marks = notifier.dirtyMarks;
      notifier.markDirty();
      notifier.noteStoreHoldsCanvas(marksBefore: marks);
      expect(
        c.read(strategySaveStateProvider).storeOwned!.canvasAheadOfStore,
        isTrue,
      );
      expect(c.read(strategySaveStateProvider).isDirty, isTrue);
      notifier.noteStoreHoldsCanvas(marksBefore: notifier.dirtyMarks);
      expect(
        c.read(strategySaveStateProvider).storeOwned!.canvasAheadOfStore,
        isFalse,
      );
      expect(c.read(strategySaveStateProvider).isDirty, isFalse);
    });
  });

  test(
      "the old queue and the media queue settling leave a store-owned "
      "canvas's unsaved edits unsaved", () {
    final c = ProviderContainer(overrides: [
      strategyOpQueueProvider.overrideWith(_SettledQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_NoMedia.new),
    ]);
    addTearDown(c.dispose);
    c.read(strategyProvider.notifier).setFromState(const StrategyState(
          strategyId: strategyId,
          strategyName: 'B split',
          source: StrategySource.cloud,
          storageDirectory: null,
          isOpen: true,
        ));
    c.read(strategySaveStateProvider.notifier)
      ..beginStoreOwned()
      ..markDirty();
    (c.read(strategyOpQueueProvider.notifier) as _SettledQueue).settleAgain();
    expect(c.read(strategySaveStateProvider).isDirty, isTrue);
    expect(
      c.read(strategySaveStateProvider).storeOwned!.canvasAheadOfStore,
      isTrue,
    );
    (c.read(cloudMediaUploadQueueProvider.notifier) as _NoMedia).settleAgain();
    expect(c.read(strategySaveStateProvider).isDirty, isTrue);
    expect(
      c.read(strategySaveStateProvider).storeOwned!.canvasAheadOfStore,
      isTrue,
    );
  });

  group('the redraw guard of a store-owned strategy reads only canvas ahead',
      () {
    test('a teammate change is drawn while the store holds unsent work',
        () async {
      final server = _server();
      final (c, remote) = await _editorOn(server);
      expect(_agentOnCanvas(c), const Offset(10, 20));
      c.read(strategySaveStateProvider.notifier)
        ..beginStoreOwned()
        ..noteStoreAheadOfServer(const StoreSending(1))
        ..setPendingCloudSync(true);

      _teammateMoves(server, const Offset(30, 40));
      remote.serve(_snapshotOf(server.rows[strategyId]!));
      await _settle();
      expect(_agentOnCanvas(c), const Offset(30, 40));
    });

    test('a teammate change waits while the canvas is ahead of the store',
        () async {
      final server = _server();
      final (c, remote) = await _editorOn(server);
      final save = c.read(strategySaveStateProvider.notifier)
        ..beginStoreOwned()
        ..markDirty();
      final marks = save.dirtyMarks;

      _teammateMoves(server, const Offset(30, 40));
      remote.serve(_snapshotOf(server.rows[strategyId]!));
      await _settle();
      expect(_agentOnCanvas(c), const Offset(10, 20));

      save.noteStoreHoldsCanvas(marksBefore: marks);
      await _settle();
      expect(_agentOnCanvas(c), const Offset(30, 40));
    });

    test('with the switch off, unsent work still holds the redraw', () async {
      final server = _server();
      final (c, remote) = await _editorOn(server);
      c.read(strategySaveStateProvider.notifier).setPendingCloudSync(true);

      _teammateMoves(server, const Offset(30, 40));
      remote.serve(_snapshotOf(server.rows[strategyId]!));
      await _settle();
      expect(_agentOnCanvas(c), const Offset(10, 20));
    });
  });
}
