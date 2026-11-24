import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/media_bytes_source.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/collab/page_changes.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/canvas_shows.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a refresh after a failed page selection resumes its live read',
      () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');

    // A teammate deletes page a; reading b, where the editor moves, fails.
    repository.failPageReads = true;
    repository.shells.add(_shell(['b']));
    await _settle();
    expect(remote.activePagePublicId, 'b');
    expect(repository.watchedPages, isNot(contains('b')));

    repository.failPageReads = false;
    await Future.wait([remote.refresh(), remote.refresh()]);
    expect(repository.watchedPages.where((id) => id == 'b'), hasLength(1));
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      1,
    );

    repository.pageStreams['b']!.add(_page('b', revision: 2));
    await _settle();
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      2,
    );
  });

  test('a strategy closed while it was still opening stays closed', () async {
    // The editor's loading screen has a working home button, so a reader can
    // leave before the first read answers. The late answer used to open the
    // strategy anyway, with no editor showing it, and start its live reads.
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);

    final gate = Completer<void>();
    repository.pageReadGate = gate;
    final opening = remote.openStrategy('strategy', activePagePublicId: 'a');
    await _settle();
    remote.clear();
    gate.complete();
    await opening;

    expect(container.read(remoteEditorSnapshotProvider).valueOrNull, isNull);
    expect(repository.shells.hasListener, isFalse);
    expect(repository.watchedPages, isEmpty);
  });

  test(
      'a page answer counts as live only on the connection it came on, and '
      'never from the copy', () async {
    final repository = _Repository();
    final queue = _StampedOpQueue();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(() => queue),
      convexConnectionSnapshotProvider.overrideWithValue(true),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    RemotePageSnapshot? active() =>
        container.read(remoteEditorSnapshotProvider).valueOrNull?.activePage;
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');
    expect(remote.answeredOnCurrentConnection(active()), isTrue);

    // The connection drops and comes back: the page held was read before.
    queue.stamp = null;
    expect(remote.answeredOnCurrentConnection(active()), isFalse);
    queue.stamp = 1;
    expect(remote.answeredOnCurrentConnection(active()), isFalse);

    repository.pageStreams['a']!.add(_page('a', revision: 2));
    await _settle();
    expect(remote.answeredOnCurrentConnection(active()), isTrue);

    // Page b, read before another drop, is shown after it came back.
    final b = await remote.fetchPage('b');
    queue.stamp = 2;
    await remote.setActivePage('b', fetched: b);
    expect(active()?.page.publicId, 'b');
    expect(remote.answeredOnCurrentConnection(active()), isFalse);

    repository.pagesFromCopy = true;
    await remote.refresh();
    expect(active()?.fromCopy, isTrue);
    expect(remote.answeredOnCurrentConnection(active()), isFalse);
  });

  test(
      'a read answered with the page its watch delivered still counts from '
      'the connection that page came on', () async {
    final repository = _Repository();
    final queue = _StampedOpQueue();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(() => queue),
      convexConnectionSnapshotProvider.overrideWithValue(true),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    RemotePageSnapshot? active() =>
        container.read(remoteEditorSnapshotProvider).valueOrNull?.activePage;
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');

    // The watch delivers page a, and reads of a answer with that very
    // answer, as they do for a page watched in slices.
    final delivered = _page('a', revision: 2);
    repository.pageStreams['a']!.add(delivered);
    await _settle();
    repository.pageSnapshots['a'] = delivered;
    expect(remote.answeredOnCurrentConnection(active()), isTrue);

    // The connection drops and comes back before the watch answers again:
    // a read then hands back the answer from before the drop.
    queue.stamp = null;
    queue.stamp = 1;
    await remote.refresh();
    expect(active()?.page.revision, 2);
    expect(remote.answeredOnCurrentConnection(active()), isFalse);

    repository.pageStreams['a']!.add(_page('a', revision: 3));
    await _settle();
    expect(remote.answeredOnCurrentConnection(active()), isTrue);
  });

  test('a restored page is read fresh with the shell and watched again',
      () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');
    // A teammate deletes page a; the editor's live read moves to b.
    repository.shells.add(_shell(['b']));
    await _settle();
    expect(remote.activePagePublicId, 'b');

    // Restored on the server; the shell watched has not caught up yet.
    await remote.showRestoredPage('a');

    final snapshot = container.read(remoteEditorSnapshotProvider).valueOrNull;
    expect(snapshot?.activePage?.page.publicId, 'a');
    expect(snapshot?.pages.map((page) => page.publicId), ['a', 'b']);
    expect(repository.watchedPages.last, 'a');
    repository.pageStreams['a']!.add(_page('a', revision: 2));
    await _settle();
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      2,
    );
  });

  test('a read from before a restore finishing late changes nothing', () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');
    repository.shells.add(_shell(['b'], revision: 2));
    await _settle();

    // Restoring bumped the strategy's revision.
    repository.shellRevision = 3;
    // A refresh starts while the page is still deleted...
    final gate = Completer<void>();
    repository.staleShellGate = gate;
    final stale = remote.refresh();
    await remote.showRestoredPage('a');
    gate.complete();
    await stale;
    // The watched shell's last push, from before the restore, arrives late.
    repository.shells.add(_shell(['b'], revision: 2));
    await _settle();

    final snapshot = container.read(remoteEditorSnapshotProvider).valueOrNull;
    expect(snapshot?.activePage?.page.publicId, 'a');
    expect(snapshot?.pages.map((page) => page.publicId), ['a', 'b']);
    expect(remote.activePagePublicId, 'a');
  });

  test('a refresh never replaces a newer shell the live read brought',
      () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'b');

    // A refresh reads the shell from while a was deleted, then waits on b.
    repository.shellRevision = 2;
    repository.failPageReads = false;
    final gate = Completer<void>();
    repository.pageReadGate = gate;
    final refresh = remote.refresh();
    await _settle();
    // Meanwhile a teammate restores a; the live read brings it.
    repository.shells.add(_shell(['a', 'b'], revision: 3));
    await _settle();
    gate.complete();
    await refresh;

    final snapshot = container.read(remoteEditorSnapshotProvider).valueOrNull;
    expect(snapshot?.header.revision, 3);
    expect(snapshot?.pages.map((page) => page.publicId), ['a', 'b']);
  });

  test('a page read a restore overtook failing late changes nothing', () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');

    // A is deleted: the editor starts reading b, slowly, and it will fail.
    final gate = Completer<void>();
    repository.pageReadGate = gate;
    repository.failNextRead.add('b');
    final selectB = remote.setActivePage('b');
    await _settle();
    await remote.showRestoredPage('a');
    gate.complete();
    await selectB;

    final state = container.read(remoteEditorSnapshotProvider);
    expect(state.hasError, isFalse);
    expect(state.valueOrNull?.activePage?.page.publicId, 'a');
    repository.pageStreams['a']!.add(_page('a', revision: 2));
    await _settle();
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      2,
    );
  });

  test('a signed-out reader on a share link reads through the link', () async {
    final repository = _Repository();
    final auth = _SignedOutAuthProvider();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(() => auth),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    container.read(shareLinkViewProvider.notifier).state =
        (strategyPublicId: 'strategy', token: 'ICR-LINK');
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);

    await remote.openStrategy('strategy');
    expect(repository.readTokens, isNotEmpty);
    expect(repository.readTokens, everyElement('ICR-LINK'));

    // A refusal is the link's, not a broken session: there is no session,
    // so no auth incident opens, and the editor sees the error itself.
    repository.shellError = const ConvexFunctionException(
      code: ConvexErrorCode.unauthenticated,
      rawCode: 'UNAUTHENTICATED',
      message: 'Unauthenticated',
    );
    await remote.refresh();
    expect(auth.unauthenticatedReports, 0);
    expect(container.read(remoteEditorSnapshotProvider).hasError, isTrue);

    repository.shellError = const ConvexFunctionException(
      code: ConvexErrorCode.shareLinkRevoked,
      rawCode: 'SHARE_LINK_REVOKED',
      message: 'Share link revoked',
    );
    await remote.refresh();
    expect(auth.unauthenticatedReports, 0);
    expect(
      isShareLinkRevokedError(
        container.read(remoteEditorSnapshotProvider).error!,
      ),
      isTrue,
    );

    // A strategy opened any other way reads with the reader's own access.
    repository.shellError = null;
    repository.readTokens.clear();
    await remote.openStrategy('another-strategy');
    expect(repository.readTokens, everyElement(isNull));
  });

  group('checking which images to upload', () {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    // The editor lays out the pages it opens.
    setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

    // Like every desktop, this one keeps the image files of the strategy.
    Future<(ProviderContainer, _EnqueueRecordingMediaQueue)> desktop(
      _Repository repository, {
      StrategyOpQueueNotifier Function()? queue,
    }) async {
      final dir = await Directory.systemTemp.createTemp('remote_editor_media');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathProvider, (_) async => dir.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathProvider, null);
        await dir.delete(recursive: true);
      });
      for (final id in ['image-a', 'image-b']) {
        await PlacedImageProvider.writeImageBytes(
          imageBytes: Uint8List.fromList([137, 80, 78, 71]),
          strategyID: 'strategy',
          imageID: id,
          fileExtension: '.png',
        );
      }
      final mediaQueue = _EnqueueRecordingMediaQueue();
      final container = ProviderContainer(overrides: [
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        authProvider.overrideWith(_ReadyAuthProvider.new),
        strategyOpQueueProvider.overrideWith(queue ?? _IdleOpQueue.new),
        cloudMediaUploadQueueProvider.overrideWith(() => mediaQueue),
        cloudMediaAccountIdProvider.overrideWithValue('account-a'),
        durableCloudMediaOutboxStoreProvider
            .overrideWithValue(MemoryDurableCloudMediaOutboxStore()),
        imageFilesOnDeviceProvider.overrideWithValue(true),
        convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
      ]);
      addTearDown(container.dispose);
      return (container, mediaQueue);
    }

    // Page a shows image-a, whose picture the server already serves.
    Future<(ProviderContainer, _EnqueueRecordingMediaQueue)> openOnPageA(
      _Repository repository,
    ) async {
      final (container, mediaQueue) = await desktop(repository);
      repository.pageSnapshots['a'] = _page(
        'a',
        images: [_image('image-a')],
        assets: [_activeAsset('image-a')],
      );
      final remote = container.read(remoteEditorSnapshotProvider.notifier);
      await container.read(remoteEditorSnapshotProvider.future);
      await remote.openStrategy('strategy', activePagePublicId: 'a');
      container
          .read(placedImageProvider.notifier)
          .fromHive([_image('image-a')]);
      await mediaQueue.reconciled();
      expect(mediaQueue.enqueued, isEmpty);
      return (container, mediaQueue);
    }

    test('switching from a page with an image to one without uploads nothing',
        () async {
      final repository = _Repository();
      final (container, mediaQueue) = await openOnPageA(repository);

      // While page b is read, the canvas still shows page a.
      await container
          .read(remoteEditorSnapshotProvider.notifier)
          .setActivePage('b');
      await mediaQueue.reconciled();

      expect(mediaQueue.enqueued, isEmpty);
    });

    test("switching pages checks the next page's own images", () async {
      final repository = _Repository();
      final (container, mediaQueue) = await openOnPageA(repository);
      // Page b shows a copy of image-a, so its assets are page a's, and
      // image-b, whose upload never reached the server.
      repository.pageSnapshots['b'] = _page(
        'b',
        images: [
          _image('image-a-copy', assetId: 'image-a'),
          _image('image-b'),
        ],
        assets: [_activeAsset('image-a')],
      );

      await container
          .read(remoteEditorSnapshotProvider.notifier)
          .setActivePage('b');
      await mediaQueue.reconciled();

      expect(mediaQueue.enqueued, ['image-b']);
    });

    test('opening a strategy on a later page uploads nothing again', () async {
      final repository = _Repository();
      // Page b, not the first page, shows image-b, already on the server.
      repository.pageSnapshots['b'] = _page(
        'b',
        images: [_image('image-b')],
        assets: [_activeAsset('image-b')],
      );
      final (container, mediaQueue) = await desktop(repository);
      await container.read(remoteEditorSnapshotProvider.future);

      await container
          .read(strategyProvider.notifier)
          .openCloudStrategy('strategy', pageId: 'b');
      await mediaQueue.reconciled();

      expect(container.read(placedImageProvider).images.map((i) => i.id),
          ['image-b']);
      expect(mediaQueue.enqueued, isEmpty);
    });

    test(
        'a page of the strategy being left, clicked while a cloud open of '
        'another strategy reads, leaves that open to finish and queues '
        'nothing for the strategy opened', () async {
      final repository = _Repository();
      repository.pageSnapshots['a'] = _page(
        'a',
        images: [_image('image-a')],
        assets: [_activeAsset('image-a')],
      );
      final (container, _) = await desktop(repository);
      await container.read(remoteEditorSnapshotProvider.future);
      final strategies = container.read(strategyProvider.notifier);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);
      expect(container.read(placedImageProvider).images, isNotEmpty);
      expect(
        container.read(canvasShowsProvider),
        isA<ShowsPage>()
            .having((shows) => shows.strategyId, 'strategy', 'strategy')
            .having((shows) => shows.pageId, 'page', 'a'),
      );

      final disk = await Directory.systemTemp.createTemp('cloud_open_window');
      addTearDown(() => disk.delete(recursive: true));
      final reached = Completer<void>();
      final held = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async {
        if (!reached.isCompleted) {
          reached.complete();
          await held.future;
        }
        return disk.path;
      });
      final opening = strategies.openCloudStrategy('other');
      await reached.future;
      expect(container.read(strategyProvider).strategyId, 'strategy',
          reason: 'while the open waits, the strategy left is still open');
      final switching = strategies.selectPage('b');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      held.complete();
      await opening;
      await switching;

      expect(
        [
          for (final op in container.read(strategyOpQueueProvider).pending)
            op.op,
        ],
        isEmpty,
      );
      expect(container.read(strategyProvider).strategyId, 'other');
      expect(
        container.read(strategyPageSessionProvider).activePageId,
        'other-a',
      );
      expect(
        container.read(canvasShowsProvider),
        isA<ShowsPage>()
            .having((shows) => shows.strategyId, 'strategy', 'other')
            .having((shows) => shows.pageId, 'page', 'other-a'),
      );
    });

    test(
        'a cloud edit is handed over once on an ordinary page switch, as the '
        'page left holds it', () async {
      final repository = _Repository();
      final queue = _RecordingOpQueue();
      final (container, _) = await desktop(repository, queue: () => queue);
      await container.read(remoteEditorSnapshotProvider.future);
      final strategies = container.read(strategyProvider.notifier);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
            type: AgentType.jett,
            position: const Offset(300, 300),
            id: 'edited-on-a',
          ));
      queue.desired.clear();

      await strategies.setActivePage('b');

      final handedOver = [
        for (final desired in queue.desired)
          for (final MapEntry(:key, :value) in desired.entries)
            if (key.entityId == 'edited-on-a') value,
      ];
      expect(handedOver, hasLength(1));
      expect(handedOver.single, isA<ElementAddOp>());
      expect(container.read(strategyPageSessionProvider).activePageId, 'b');
    });

    test(
        'while a local open does its disk work, a cloud save that was waiting '
        'on the strategy\'s fields and an acknowledgment both find the cloud '
        'page whole, and queue no delete', () async {
      final repository = _Repository();
      repository.pageSnapshots['a'] = _page(
        'a',
        images: [_image('image-a')],
        assets: [_activeAsset('image-a')],
      );
      final queue = _RecordingOpQueue();
      final (container, _) = await desktop(repository, queue: () => queue);
      final disk = await openUnitHive();
      addTearDown(Hive.close);
      final local = generatedStrategy(Optionals.set).copyWith(id: 'local');
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(local.id, local);
      var holdDisk = false;
      final diskReached = Completer<void>();
      final diskReleased = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async {
        if (holdDisk && !diskReached.isCompleted) {
          diskReached.complete();
          await diskReleased.future;
        }
        return disk.path;
      });
      await container.read(remoteEditorSnapshotProvider.future);
      final strategies = container.read(strategyProvider.notifier);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);
      expect(container.read(placedImageProvider).images, isNotEmpty);
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
            type: AgentType.jett,
            position: const Offset(300, 300),
            id: 'sent-before',
          ));
      final session = container.read(strategyPageSessionProvider.notifier);
      await session.handOverForSyncStatus();
      final sent = queue.desired.last.values.whereType<ElementAddOp>().first;
      queue.desired.clear();

      queue.holdMetadata();
      final saving = session.handOverForSyncStatus();
      await queue.metadataReached!.future;
      holdDisk = true;
      final opening = strategies.loadFromHive(local.id);
      await diskReached.future;
      queue.releaseMetadata();
      await saving;
      queue.acknowledge(
        AckedEntityIntent(
          entityKey: EntitySyncKey.element('a', sent.elementPublicId),
          op: sent,
          ack: AppliedOpAck(opId: sent.opId, revision: 2),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      diskReleased.complete();
      expect(await opening, isTrue);

      final queued = [
        for (final desired in queue.desired) ...desired.values,
      ];
      expect(queued.whereType<ElementDeleteOp>(), isEmpty);
      expect(container.read(strategyProvider).strategyId, local.id);
    });

    void onEmptied(ProviderContainer container, void Function() act) {
      container.listen(canvasShowsProvider, (_, next) {
        if (next is ShowsNothing) act();
      });
    }

    test(
        'a cloud save that resumes after a reopen emptied the canvas and '
        'before its page is drawn hands nothing over and stays unsynced',
        () async {
      final repository = _Repository();
      repository.pageSnapshots['a'] = _page(
        'a',
        images: [_image('image-a')],
        assets: [_activeAsset('image-a')],
      );
      final queue = _RecordingOpQueue();
      final (container, _) = await desktop(repository, queue: () => queue);
      await container.read(remoteEditorSnapshotProvider.future);
      final strategies = container.read(strategyProvider.notifier);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);
      final session = container.read(strategyPageSessionProvider.notifier);
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
            type: AgentType.jett,
            position: const Offset(300, 300),
            id: 'sent-before',
          ));
      await session.handOverForSyncStatus();
      queue.desired.clear();

      queue.holdMetadata();
      final saving = session.handOverForSyncStatus();
      await queue.metadataReached!.future;
      onEmptied(container, queue.releaseMetadata);
      final opening = strategies.openCloudStrategy('strategy');
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
            type: AgentType.sova,
            position: const Offset(400, 300),
            id: 'made-while-reopening',
          ));
      strategies.setUnsaved();
      await saving;
      final heldAtSave =
          container.read(strategySaveStateProvider.notifier).canvasHeld;
      expect(await opening, isTrue);

      expect(heldAtSave, isTrue);
      expect(
        [for (final desired in queue.desired) ...desired.values]
            .whereType<ElementDeleteOp>(),
        isEmpty,
      );
    });

    test(
        'an acknowledgment that resumes after a reopen emptied the canvas and '
        'before its page is drawn queues no delete', () async {
      final repository = _Repository();
      repository.pageSnapshots['a'] = _page(
        'a',
        images: [_image('image-a')],
        assets: [_activeAsset('image-a')],
      );
      final queue = _RecordingOpQueue();
      final (container, _) = await desktop(repository, queue: () => queue);
      await container.read(remoteEditorSnapshotProvider.future);
      final strategies = container.read(strategyProvider.notifier);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
            type: AgentType.jett,
            position: const Offset(300, 300),
            id: 'sent-before',
          ));
      final session = container.read(strategyPageSessionProvider.notifier);
      await session.handOverForSyncStatus();
      final sent = queue.desired.last.values.whereType<ElementAddOp>().first;
      queue.desired.clear();
      container.read(strategySaveStateProvider.notifier).reset();

      final refreshRead = Completer<void>();
      repository.pageReadGate = refreshRead;
      queue.acknowledge(
        AckedEntityIntent(
          entityKey: EntitySyncKey.element('a', sent.elementPublicId),
          op: sent,
          ack: AppliedOpAck(opId: sent.opId, revision: 2),
        ),
      );
      await repository.pageReadHeld.future;
      onEmptied(container, refreshRead.complete);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(refreshRead.isCompleted, isTrue);
      expect(
        [for (final desired in queue.desired) ...desired.values]
            .whereType<ElementDeleteOp>(),
        isEmpty,
      );
    });

    test(
        'a page clicked after an edit made while the page clicked before it '
        'is selected but not drawn stays, and the editor ends on the first '
        'page drawn and saving', () async {
      final repository = _Repository()..pageIds = ['a', 'b', 'c'];
      final queue = _RecordingOpQueue();
      final (container, _) = await desktop(repository, queue: () => queue);
      await container.read(remoteEditorSnapshotProvider.future);
      final strategies = container.read(strategyProvider.notifier);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);

      final drawingB = Completer<void>();
      repository.unwatchGate = drawingB;
      final first = strategies.selectPage('b');
      await repository.unwatchHeld.future;
      expect(container.read(strategyPageSessionProvider).activePageId, 'b');
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
            type: AgentType.jett,
            position: const Offset(300, 300),
            id: 'made-while-b-reads',
          ));
      strategies.setUnsaved();
      final second = strategies.selectPage('c');
      drawingB.complete();
      await first;
      await second;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      const page = 'b';
      expect(container.read(strategyPageSessionProvider).activePageId, page);
      expect(
        container.read(canvasShowsProvider),
        isA<ShowsPage>().having((shows) => shows.pageId, 'page', page),
      );
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
            type: AgentType.sova,
            position: const Offset(400, 300),
            id: 'made-after',
          ));
      queue.desired.clear();
      await container
          .read(strategyPageSessionProvider.notifier)
          .handOverForSyncStatus();
      expect(container.read(strategySaveStateProvider.notifier).canvasHeld,
          isFalse);
      final handedOver = [
        for (final desired in queue.desired)
          for (final MapEntry(:key, :value) in desired.entries)
            if (key.entityId == 'made-after') (page: key.pageId, op: value),
      ];
      expect(handedOver.map((handed) => handed.page), [page]);
      expect(handedOver.single.op, isA<ElementAddOp>());
    });

    test(
        'a page clicked once the page clicked before it is selected but not '
        'drawn ends, as on main, on the first page, drawn', () async {
      final repository = _Repository()..pageIds = ['a', 'b', 'c'];
      repository.pageSnapshots['a'] = _page(
        'a',
        images: [_image('image-a')],
        assets: [_activeAsset('image-a')],
      );
      final (container, _) =
          await desktop(repository, queue: _RecordingOpQueue.new);
      await container.read(remoteEditorSnapshotProvider.future);
      final strategies = container.read(strategyProvider.notifier);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);

      final drawingB = Completer<void>();
      repository.unwatchGate = drawingB;
      final first = strategies.selectPage('b');
      await repository.unwatchHeld.future;
      expect(container.read(strategyPageSessionProvider).activePageId, 'b');
      final second = strategies.selectPage('c');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      drawingB.complete();
      for (final click in [first, second]) {
        await click.then((_) {}, onError: (Object _) {});
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(strategyPageSessionProvider).activePageId, 'b');
      expect(
        container.read(canvasShowsProvider),
        isA<ShowsPage>().having((shows) => shows.pageId, 'page', 'b'),
      );
      expect(container.read(placedImageProvider).images, isEmpty);
    });

    test(
        'a page deleted while it is selected but not drawn, after an edit to '
        'what is on screen, leaves the editor on the page before it', () async {
      final repository = _Repository()..pageIds = ['a', 'b'];
      final queue = _RecordingOpQueue();
      final (container, _) = await desktop(repository, queue: () => queue);
      await container.read(remoteEditorSnapshotProvider.future);
      final strategies = container.read(strategyProvider.notifier);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);

      final drawingB = Completer<void>();
      repository.unwatchGate = drawingB;
      final selecting = strategies.selectPage('b');
      await repository.unwatchHeld.future;
      expect(container.read(strategyPageSessionProvider).activePageId, 'b');
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
            type: AgentType.jett,
            position: const Offset(300, 300),
            id: 'made-while-b-reads',
          ));
      strategies.setUnsaved();
      final deleting = strategies.deletePage('b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      drawingB.complete();
      await selecting.then((_) {}, onError: (Object _) {});
      await deleting;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
          queue.queued.whereType<PageDeleteOp>().map((op) => op.pagePublicId),
          ['b']);
      expect(container.read(strategyPageSessionProvider).activePageId, 'a');
      expect(
        container.read(canvasShowsProvider),
        isA<ShowsPage>().having((shows) => shows.pageId, 'page', 'a'),
      );
    });

    group('with the canvas not showing the page on screen', () {
      final writers = <String, Future<Object?> Function(ProviderContainer)>{
        'a save': (container) => container
            .read(strategyPageSessionProvider.notifier)
            .handOverForSyncStatus(),
        'a page click': (container) =>
            container.read(strategyProvider.notifier).selectPage('b'),
        'copying an item to the next page': (container) => container
            .read(strategyProvider.notifier)
            .copyPlacedWidgetToAdjacentPage(
              widgetId: 'edited-here',
              direction: PageTransitionDirection.forward,
            ),
        'copying lineups to the next page': (container) =>
            container.read(strategyProvider.notifier).copyLineUpsToAdjacentPage(
              linkIds: {
                for (final link in container.read(lineUpProvider).links)
                  link.id,
              },
              direction: PageTransitionDirection.forward,
            ),
        'switching side on all pages': (container) =>
            container.read(strategyProvider.notifier).switchSide(
                  allPages: true,
                ),
        'adding a page': (container) =>
            container.read(strategyProvider.notifier).addPage(),
      };

      for (final MapEntry(key: step, value: write) in writers.entries) {
        test('$step queues nothing', () async {
          final repository = _Repository();
          final queue = _RecordingOpQueue();
          final (container, _) = await desktop(repository, queue: () => queue);
          await container.read(remoteEditorSnapshotProvider.future);
          final strategies = container.read(strategyProvider.notifier);
          expect(await strategies.openCloudStrategy('strategy'), isTrue);
          container.read(agentProvider.notifier).addAgent(PlacedAgent(
                type: AgentType.jett,
                position: const Offset(300, 300),
                id: 'edited-here',
              ));
          container
              .read(lineUpProvider.notifier)
              .fromHive(sharedSpotLineups('on-screen'));
          strategies.setUnsaved();
          queue.desired.clear();
          queue.queued.clear();

          container.read(canvasShowsProvider.notifier).emptied();
          await write(container).then<Object?>(
            (result) => result,
            onError: (Object error) =>
                error is StateError ? error : throw error,
          );

          expect(queue.queued, isEmpty);
          expect(queue.desired, isEmpty);
          expect(container.read(strategyPageSessionProvider).activePageId, 'a');
          expect(
            container.read(strategySaveStateProvider.notifier).canvasHeld ||
                container.read(strategySaveStateProvider).isDirty,
            isTrue,
          );
        });
      }
    });

    test('a strategy that cannot be read does not open as the one before it',
        () async {
      final repository = _Repository();
      final (container, _) = await desktop(repository);
      await container.read(remoteEditorSnapshotProvider.future);
      final strategies = container.read(strategyProvider.notifier);
      expect(await strategies.openCloudStrategy('strategy'), isTrue);

      // Its owner deleted it, say. The failed read leaves what was read
      // before beside the error, and the open used to go on with that: the
      // first strategy on screen, its edits addressed to this one.
      repository.shellError = StateError('not found');

      await expectLater(
        strategies.openCloudStrategy('deleted'),
        throwsStateError,
      );
    });
  });

  group('a refused read of the open strategy', () {
    const forbidden = ConvexFunctionException(
      code: ConvexErrorCode.forbidden,
      rawCode: 'FORBIDDEN',
      message: 'Forbidden',
    );

    Future<(ProviderContainer, RemoteEditorSnapshotNotifier, _Repository)>
        openStrategy({AuthProvider Function()? auth}) async {
      final repository = _Repository();
      final container = ProviderContainer(overrides: [
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        authProvider.overrideWith(auth ?? _ReadyAuthProvider.new),
        strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
        cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
        cloudMediaAccountIdProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);
      final remote = container.read(remoteEditorSnapshotProvider.notifier);
      await container.read(remoteEditorSnapshotProvider.future);
      await remote.openStrategy('strategy', activePagePublicId: 'a');
      return (container, remote, repository);
    }

    test('means access is gone once a fresh read confirms it', () async {
      final (container, _, repository) = await openStrategy();

      // The live read is refused; the editor reads the shell again.
      repository.shellError = forbidden;
      repository.shells.addError(forbidden);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final state = container.read(remoteEditorSnapshotProvider);
      expect(state.error, isA<StrategyAccessLost>());
      expect(container.read(strategyAccessLostProvider), isTrue);
      repository.shellError = null;
      repository.shells.add(_shell(['a', 'b'], revision: 5));
      await _settle();
      expect(container.read(strategyAccessLostProvider), isTrue);
    });

    test('is not lost access when the fresh read works', () async {
      final (container, _, repository) = await openStrategy();

      repository.shells.addError(forbidden);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final state = container.read(remoteEditorSnapshotProvider);
      expect(state.hasError, isFalse);
      expect(state.valueOrNull?.header.role, 'owner');
      expect(container.read(strategyAccessLostProvider), isFalse);
    });

    test('is not lost access when the network fails', () async {
      final (container, remote, repository) = await openStrategy();

      repository.shellError = StateError('offline');
      await remote.refresh();

      expect(container.read(remoteEditorSnapshotProvider).hasError, isTrue);
      expect(container.read(strategyAccessLostProvider), isFalse);
    });

    test('opens no lost-access state when the session broke', () async {
      final auth = _ReportingAuthProvider();
      final (container, remote, repository) =
          await openStrategy(auth: () => auth);

      repository.shellError = const ConvexFunctionException(
        code: ConvexErrorCode.unauthenticated,
        rawCode: 'UNAUTHENTICATED',
        message: 'Unauthenticated',
      );
      await remote.refresh();

      expect(auth.unauthenticatedReports, 1);
      expect(container.read(strategyAccessLostProvider), isFalse);
    });

    test('is the share link\'s for a reader on one, not lost access', () async {
      final auth = _SignedOutAuthProvider();
      final repository = _Repository();
      final container = ProviderContainer(overrides: [
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        authProvider.overrideWith(() => auth),
        strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
        cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
        cloudMediaAccountIdProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);
      container.read(shareLinkViewProvider.notifier).state =
          (strategyPublicId: 'strategy', token: 'ICR-LINK');
      final remote = container.read(remoteEditorSnapshotProvider.notifier);
      await container.read(remoteEditorSnapshotProvider.future);
      await remote.openStrategy('strategy');

      repository.shellError = forbidden;
      await remote.refresh();

      expect(container.read(remoteEditorSnapshotProvider).hasError, isTrue);
      expect(container.read(strategyAccessLostProvider), isFalse);
    });

    test('opening a strategy this account was refused is lost access',
        () async {
      final repository = _Repository()..shellError = forbidden;
      final container = ProviderContainer(overrides: [
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        authProvider.overrideWith(_ReadyAuthProvider.new),
        strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
        cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
        cloudMediaAccountIdProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);
      await container.read(remoteEditorSnapshotProvider.future);

      await container
          .read(remoteEditorSnapshotProvider.notifier)
          .openStrategy('strategy');

      expect(container.read(remoteEditorSnapshotProvider).error,
          isA<StrategyAccessLost>());
      expect(container.read(strategyAccessLostProvider), isTrue);
    });

    test('stays lost through an offline read, and ends when a read works',
        () async {
      final (container, remote, repository) = await openStrategy();
      repository.shellError = forbidden;
      await remote.refresh();
      expect(container.read(strategyAccessLostProvider), isTrue);

      repository.shellError = StateError('offline');
      await remote.refresh();
      expect(container.read(strategyAccessLostProvider), isTrue);

      // The owner added them back.
      repository.shellError = null;
      await remote.refresh();
      expect(container.read(strategyAccessLostProvider), isFalse);
      expect(
        container.read(remoteEditorSnapshotProvider).valueOrNull?.header.role,
        'owner',
      );
    });
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

RemotePage _remotePage(
  String id, {
  int revision = 1,
  String strategyPublicId = 'strategy',
}) =>
    RemotePage(
      publicId: id,
      strategyPublicId: strategyPublicId,
      name: id,
      sortIndex: 0,
      isAttack: true,
      revision: revision,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

RemoteStrategyShell _shell(
  List<String> pageIds, {
  int revision = 1,
  String publicId = 'strategy',
}) =>
    RemoteStrategyShell(
      header: RemoteStrategyHeader(
        publicId: publicId,
        name: 'Strategy',
        mapData: 'ascent',
        revision: revision,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        role: 'owner',
      ),
      pages: [
        for (final id in pageIds) _remotePage(id, strategyPublicId: publicId),
      ],
    );

RemotePageSnapshot _page(
  String id, {
  int revision = 1,
  List<PlacedImage> images = const [],
  List<RemoteImageAsset> assets = const [],
}) =>
    RemotePageSnapshot(
      page: _remotePage(id, revision: revision),
      content: RemotePageContent(
        revision: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
      elements: [
        for (final image in images)
          RemoteElement(
            publicId: image.id,
            strategyPublicId: 'strategy',
            pagePublicId: id,
            elementType: 'image',
            payload: cloudElementPayload(
              kind: 'image',
              data: cloudImagePayloadFromPlacedImage(image),
            ),
            sortIndex: 0,
            revision: 1,
            deleted: false,
          ),
      ],
      lineups: const [],
      assetsById: {for (final asset in assets) asset.publicId: asset},
    );

PlacedImage _image(String id, {String? assetId}) => PlacedImage(
      position: const Offset(100, 100),
      id: id,
      aspectRatio: 16 / 9,
      scale: 1,
      fileExtension: '.png',
      assetId: assetId,
    );

RemoteImageAsset _activeAsset(String id) => RemoteImageAsset(
      publicId: id,
      fileExtension: '.png',
      width: 16,
      height: 9,
      url: 'https://media.example.com/$id.png',
      legacyStoragePath: null,
      uploadStatus: 'active',
    );

class _Repository extends ConvexStrategyRepository {
  _Repository() : super(IcarusConvexApi(_UnusedTransport()));

  final shells = StreamController<RemoteStrategyShell>.broadcast();
  final pageStreams = <String, StreamController<RemotePageSnapshot>>{};
  final watchedPages = <String>[];

  /// The share token each read carried, in order.
  final readTokens = <String?>[];
  bool failPageReads = false;
  Object? shellError;

  /// While set, a shell read answers from before page a was restored, once
  /// the gate opens.
  Completer<void>? staleShellGate;

  int shellRevision = 1;

  List<String> pageIds = ['a', 'b'];

  /// While set, the next page read waits for it, then answers as usual.
  Completer<void>? pageReadGate;

  final pageReadHeld = Completer<void>();

  final failNextRead = <String>{};

  /// What reads of a page answer; an empty page when it has none.
  final pageSnapshots = <String, RemotePageSnapshot>{};

  /// While set, page reads answer from this computer's copy.
  bool pagesFromCopy = false;

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    readTokens.add(shareToken);
    if (shellError case final error?) throw error;
    final gate = staleShellGate;
    if (gate != null) {
      staleShellGate = null;
      await gate.future;
      return _shell(['b'], revision: 2);
    }
    if (strategyPublicId != 'strategy') {
      return _shell(
        ['$strategyPublicId-a', '$strategyPublicId-b'],
        revision: shellRevision,
        publicId: strategyPublicId,
      );
    }
    return _shell(failPageReads ? ['b'] : pageIds, revision: shellRevision);
  }

  @override
  Stream<RemoteStrategyShell> watchShell(
    String strategyPublicId, {
    String? shareToken,
  }) {
    readTokens.add(shareToken);
    return shells.stream;
  }

  @override
  Future<RemotePageSnapshot> fetchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) async {
    readTokens.add(shareToken);
    final gate = pageReadGate;
    if (gate != null) {
      pageReadGate = null;
      if (!pageReadHeld.isCompleted) pageReadHeld.complete();
      await gate.future;
    }
    if (failPageReads || failNextRead.remove(pagePublicId)) {
      throw StateError('offline');
    }
    final page = pageSnapshots[pagePublicId] ?? _page(pagePublicId);
    return pagesFromCopy
        ? RemotePageSnapshot(
            page: page.page,
            content: page.content,
            elements: page.elements,
            lineups: page.lineups,
            assetsById: page.assetsById,
            fromCopy: true,
          )
        : page;
  }

  @override
  Stream<RemotePageSnapshot> watchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) {
    readTokens.add(shareToken);
    watchedPages.add(pagePublicId);
    final watched = (pageStreams[pagePublicId] ??=
            StreamController<RemotePageSnapshot>.broadcast())
        .stream;
    late final StreamSubscription<RemotePageSnapshot> forwarding;
    final watch = StreamController<RemotePageSnapshot>(
      onListen: () {},
      onCancel: () async {
        await forwarding.cancel();
        final gate = unwatchGate;
        if (gate != null) {
          unwatchGate = null;
          unwatchHeld.complete();
          await gate.future;
        }
      },
    );
    forwarding = watched.listen(watch.add);
    return watch.stream;
  }

  Completer<void>? unwatchGate;

  final unwatchHeld = Completer<void>();
}

class _ReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: const <String, dynamic>{},
          userMetadata: const <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _ReportingAuthProvider extends _ReadyAuthProvider {
  int unauthenticatedReports = 0;

  @override
  Future<void> reportConvexUnauthenticated({
    required String source,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    unauthenticatedReports += 1;
  }
}

class _SignedOutAuthProvider extends AuthProvider {
  int unauthenticatedReports = 0;

  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );

  @override
  Future<void> reportConvexUnauthenticated({
    required String source,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    unauthenticatedReports += 1;
  }
}

class _IdleOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'strategy',
        clientId: 'client',
        durableLoaded: true,
      );

  @override
  void setActiveStrategy(
    String? strategyPublicId, {
    required String? accountId,
  }) {}
}

class _RecordingOpQueue extends _IdleOpQueue {
  final desired = <Map<EntitySyncKey, StrategyOp>>[];
  final queued = <StrategyOp>[];

  @override
  bool isDeletedHere(String pageId) =>
      queued.any((op) => op is PageDeleteOp && op.pagePublicId == pageId);

  @override
  Future<void> enqueue(StrategyOp op, {bool flushImmediately = false}) async =>
      queued.add(op);

  @override
  Future<void> enqueueAll(
    Iterable<StrategyOp> ops, {
    bool flushImmediately = false,
    SeenPage? seenPage,
  }) async =>
      queued.addAll(ops);

  @override
  Future<void> enqueuePageChange(
    StrategyOp op, {
    bool flushImmediately = false,
    SeenPage? seenPage,
  }) async =>
      queued.add(op);

  @override
  Future<bool> enqueuePageCopy(
    PageAddOp add,
    List<StrategyOp> content, {
    required String strategyPublicId,
  }) async {
    queued
      ..add(add)
      ..addAll(content);
    return true;
  }

  @override
  Future<bool> enqueueOffCanvas(
    StrategyOp op, {
    bool flushImmediately = false,
  }) async {
    queued.add(op);
    return true;
  }

  Completer<void>? metadataReached;
  Completer<void>? _metadataReleased;

  void holdMetadata() {
    metadataReached = Completer<void>();
    _metadataReleased = Completer<void>();
  }

  void releaseMetadata() => _metadataReleased?.complete();

  void acknowledge(AckedEntityIntent acked) => state = state.copyWith(
        lastAcks: [acked.ack],
        lastAckBatch: [acked],
      );

  @override
  Future<OutboxWrite> syncDesiredOpsForPage({
    required String pageId,
    required Map<EntitySyncKey, StrategyOp> desiredOpsByEntityKey,
    bool clearMissing = true,
    bool flushImmediately = false,
    int? madeLive,
  }) async {
    desired.add(Map.of(desiredOpsByEntityKey));
    return OutboxWrite.written;
  }

  @override
  Future<void> syncDesiredGenericOp({
    required EntitySyncKey entityKey,
    required StrategyOp? desiredOp,
    bool flushImmediately = false,
  }) async {
    if (metadataReached case final reached? when !reached.isCompleted) {
      reached.complete();
      await _metadataReleased!.future;
    }
  }
}

/// The queue, its connection stamp set by the test (see
/// StrategyOpQueueNotifier.liveStamp).
class _StampedOpQueue extends _IdleOpQueue {
  int? stamp = 0;

  @override
  int? get liveStamp => stamp;
}

class _IdleMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);
}

/// The real queue deciding which pictures need uploading. It records each
/// upload it queues instead of sending it.
class _EnqueueRecordingMediaQueue extends CloudMediaUploadQueueNotifier {
  final List<String> enqueued = [];
  final List<Future<void>> _reconciles = [];

  /// Waits for every page check started so far, file reads included.
  Future<void> reconciled() => Future.wait(_reconciles);

  @override
  Future<void> reconcilePageMedia({
    required String strategyPublicId,
    required Iterable<PlacedImage> placedImages,
    required Map<String, RemoteImageAsset> assetsById,
  }) {
    final reconcile = super.reconcilePageMedia(
      strategyPublicId: strategyPublicId,
      placedImages: placedImages,
      assetsById: assetsById,
    );
    _reconciles.add(reconcile);
    return reconcile;
  }

  @override
  Future<void> enqueueJobForLocalBytes({
    required String strategyPublicId,
    required String assetPublicId,
    required String fileExtension,
    String? mimeType,
    int? width,
    int? height,
  }) async {
    enqueued.add(assetPublicId);
  }
}

class _UnusedTransport implements ConvexTransport {
  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Stream<List<ConvexValue>> subscribeTogether(
    List<(String, ConvexObject)> queries,
  ) =>
      throw UnimplementedError();
}
