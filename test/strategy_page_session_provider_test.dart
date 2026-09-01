import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/transition_provider.dart'
    hide PageTransitionState;
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class _FakeRemoteEditorNotifier extends RemoteEditorSnapshotNotifier {
  _FakeRemoteEditorNotifier(
    this.initialSnapshot, {
    Map<String, RemotePageSnapshot>? pageCatalog,
  }) : pageCatalog = Map<String, RemotePageSnapshot>.from(
          pageCatalog ??
              <String, RemotePageSnapshot>{
                if (initialSnapshot.activePage != null)
                  initialSnapshot.activePage!.page.publicId:
                      initialSnapshot.activePage!,
              },
        );

  RemoteEditorSnapshot initialSnapshot;
  final Map<String, RemotePageSnapshot> pageCatalog;
  int refreshCount = 0;
  final List<String?> selectedPageIds = <String?>[];
  String? failingPageId;

  @override
  Future<RemoteEditorSnapshot?> build() async => initialSnapshot;

  void setSnapshot(RemoteEditorSnapshot snapshot) {
    initialSnapshot = snapshot;
    final active = snapshot.activePage;
    if (active != null) pageCatalog[active.page.publicId] = active;
    state = AsyncData(snapshot);
  }

  @override
  Future<RemotePageSnapshot?> setActivePage(String? pagePublicId) async {
    selectedPageIds.add(pagePublicId);
    if (pagePublicId == failingPageId) {
      throw StateError('Failed to load $pagePublicId');
    }
    final current = state.valueOrNull ?? initialSnapshot;
    final page = pagePublicId == null ? null : pageCatalog[pagePublicId];
    state = AsyncData(RemoteEditorSnapshot(
      shell: current.shell,
      activePage: page,
    ));
    return page;
  }

  @override
  Future<void> refresh() async {
    refreshCount += 1;
    state = AsyncData(initialSnapshot);
  }
}

class _FakeStrategyOpQueueNotifier extends StrategyOpQueueNotifier {
  _FakeStrategyOpQueueNotifier({this.blockFlush = false});

  final bool blockFlush;
  int flushNowCount = 0;

  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'test-client',
        durableLoaded: true,
      );

  @override
  void setActiveStrategy(
    String? strategyPublicId, {
    required String? accountId,
  }) {}

  @override
  Future<void> syncDesiredGenericOp({
    required EntitySyncKey entityKey,
    required StrategyOp? desiredOp,
    bool flushImmediately = false,
  }) async {
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    if (desiredOp == null) {
      queued.remove(entityKey);
    } else {
      queued[entityKey] = QueuedEntityIntent(
        entityKey: entityKey,
        pending: PendingOp(op: desiredOp, clientId: 'test-client'),
      );
    }
    state = state.copyWith(queuedByEntityKey: queued);
  }

  @override
  Future<void> syncDesiredOpsForPage({
    required String pageId,
    required Map<EntitySyncKey, StrategyOp> desiredOpsByEntityKey,
    bool clearMissing = true,
    bool flushImmediately = false,
  }) async {
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    if (clearMissing) {
      queued.removeWhere((key, _) =>
          key.pageId == pageId && !desiredOpsByEntityKey.containsKey(key));
    }
    for (final entry in desiredOpsByEntityKey.entries) {
      queued[entry.key] = QueuedEntityIntent(
        entityKey: entry.key,
        pending: PendingOp(op: entry.value, clientId: 'test-client'),
      );
    }
    state = state.copyWith(queuedByEntityKey: queued);
  }

  @override
  Future<void> flushNow() async {
    flushNowCount += 1;
    if (blockFlush) await Completer<void>().future;
  }

  void reject(StrategyOp op) {
    final key = EntitySyncKey.forStrategyOp(op)!;
    final pending = PendingOp(op: op, clientId: 'test-client');
    final ack = RejectedOpAck(
      opId: op.opId,
      rejectionReason: OpRejectionReason.revisionMismatch,
      current: const ElementCurrentSnapshot(revision: 2, value: {}),
    );
    state = state.copyWith(
      queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
      attentionByEntityKey: {
        key: QueuedEntityIntent(entityKey: key, pending: pending),
      },
      isFlushing: false,
      lastError: 'Some saved work needs attention.',
      lastAcks: [ack],
      lastAckBatch: [
        AckedEntityIntent(entityKey: key, op: op, ack: ack),
      ],
    );
  }

  void holdInFlight(EntitySyncKey key, StrategyOp op) {
    state = state.copyWith(
      inFlightByEntityKey: {
        key: InFlightEntityIntent(
          entityKey: key,
          pending: PendingOp(op: op, clientId: 'test-client'),
          sentAt: DateTime.utc(2026),
        ),
      },
    );
  }
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

RemotePage _page(String id, int index, {int revision = 1, String? name}) {
  final now = DateTime.utc(2026);
  return RemotePage(
    publicId: id,
    strategyPublicId: 'cloud-strategy',
    name: name ?? 'Page ${index + 1}',
    sortIndex: index,
    isAttack: true,
    revision: revision,
    createdAt: now,
    updatedAt: now,
  );
}

RemoteElement _textElement(
  String pageId,
  String id,
  String value, {
  int revision = 1,
  bool deleted = false,
}) {
  final text = PlacedText(id: id, position: const Offset(10, 20))..text = value;
  final payload = Map<String, dynamic>.from(text.toJson())
    ..['elementType'] = 'text';
  return RemoteElement(
    publicId: id,
    strategyPublicId: 'cloud-strategy',
    pagePublicId: pageId,
    elementType: 'text',
    payload: cloudElementPayload(kind: 'text', data: payload),
    sortIndex: 0,
    revision: revision,
    deleted: deleted,
  );
}

RemotePageSnapshot _pageSnapshot(
  RemotePage page, {
  String? text,
  int contentRevision = 1,
  CloudPayload settings = const {},
  List<RemoteElement>? elements,
  List<RemoteLineup> lineups = const [],
}) {
  final now = DateTime.utc(2026);
  return RemotePageSnapshot(
    page: page,
    content: RemotePageContent(
      settings: settings,
      revision: contentRevision,
      createdAt: now,
      updatedAt: now,
    ),
    elements: elements ??
        (text == null
            ? const []
            : [_textElement(page.publicId, 'text-${page.publicId}', text)]),
    lineups: lineups,
    assetsById: const {},
  );
}

RemoteLineup _lineup(String pageId, String id) {
  return RemoteLineup(
    publicId: id,
    strategyPublicId: 'cloud-strategy',
    pagePublicId: pageId,
    payload: <String, dynamic>{
      'kind': 'lineupGroup',
      'payloadVersion': 1,
      'data': <Object?, Object?>{
        'id': id,
        'agent': <Object?, Object?>{
          'id': 'agent-$id',
          'isDeleted': false,
          'position': <Object?, Object?>{'dx': 10, 'dy': 20},
          'type': 'sova',
          'isAlly': true,
          'state': 'none',
          'kind': 'plain',
          'lineUpID': id,
        },
        'items': <Object?>[
          <Object?, Object?>{
            'id': 'item-$id',
            'ability': <Object?, Object?>{
              'id': 'ability-$id',
              'isDeleted': false,
              'data': <Object?, Object?>{'type': 'sova', 'index': 2.0},
              'position': <Object?, Object?>{'dx': 30, 'dy': 40},
              'isAlly': true,
              'rotation': 0,
              'length': 0,
              'lineUpID': id,
              'visualState': <Object?, Object?>{
                'showRangeOutline': true,
                'showRangeFill': true,
                'showInnerOutline': true,
                'showInnerFill': true,
              },
              'armLengthsMeters': <Object?>[10, 10, 10, 10],
            },
            'youtubeLink': '',
            'notes': 'remote lineup',
            'images': <Object?>[],
          },
        ],
      },
    },
    sortIndex: 0,
    revision: 1,
    deleted: false,
  );
}

RemoteEditorSnapshot _editorSnapshot({
  required List<RemotePage> pages,
  required RemotePageSnapshot activePage,
  int shellRevision = 1,
  String? mapData,
  String? themeProfileId,
}) {
  final now = DateTime.utc(2026);
  return RemoteEditorSnapshot(
    shell: RemoteStrategyShell(
      header: RemoteStrategyHeader(
        publicId: 'cloud-strategy',
        name: 'Cloud Strategy',
        mapData: mapData ?? Maps.mapNames[MapValue.ascent]!,
        revision: shellRevision,
        createdAt: now,
        updatedAt: now,
        themeProfileId: themeProfileId,
      ),
      pages: pages,
    ),
    activePage: activePage,
  );
}

Future<ProviderContainer> _cloudContainer({
  required _FakeRemoteEditorNotifier remote,
  required _FakeStrategyOpQueueNotifier queue,
}) async {
  final container = ProviderContainer(overrides: [
    remoteEditorSnapshotProvider.overrideWith(() => remote),
    strategyOpQueueProvider.overrideWith(() => queue),
  ]);
  addTearDown(container.dispose);
  container.read(strategyProvider.notifier).setFromState(const StrategyState(
        strategyId: 'cloud-strategy',
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      ));
  container.listen(strategyPageSessionProvider, (_, __) {});
  await container.read(remoteEditorSnapshotProvider.future);
  return container;
}

Future<ProviderContainer> _syncContainer({
  required _FakeRemoteEditorNotifier remote,
  required _FakeStrategyOpQueueNotifier queue,
}) async {
  final container = ProviderContainer(overrides: [
    remoteEditorSnapshotProvider.overrideWith(() => remote),
    strategyOpQueueProvider.overrideWith(() => queue),
  ]);
  addTearDown(container.dispose);
  await container.read(remoteEditorSnapshotProvider.future);
  return container;
}

Future<Box<StrategyData>> _openStrategyBox() async {
  final temp = await Directory.systemTemp.createTemp('icarus-page-session-');
  Hive.init(temp.path);
  if (!Hive.isAdapterRegistered(9)) registerIcarusAdapters(Hive);
  final box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  addTearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });
  return box;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  test('cloud strategy metadata patch carries the remote shell revision',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page),
      shellRevision: 17,
      mapData: Maps.mapNames[MapValue.haven],
      themeProfileId: 'remote-theme',
    ));
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );

    await container
        .read(strategyProvider.notifier)
        .notifyCloudStrategyMutation();

    final op = container.read(strategyOpQueueProvider).pending.single.op;
    expect(op.entityType, StrategyOpEntityType.strategy);
    expect(op.expectedRevision, 17);
    expect(op.toConvexJson()['expectedStrategyRevision'], 17);
    expect(
      op.payload,
      containsPair('mapData', Maps.mapNames[MapValue.ascent]),
    );
    expect(op.payload, containsPair('clearThemeProfileId', true));
  });

  test('cloud page reorder is persisted as a page descriptor op', () async {
    final first = _page('page-1', 0);
    final second = _page('page-2', 1);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [first, second],
        activePage: _pageSnapshot(first),
        shellRevision: 17,
      )),
      queue: queue,
    );

    await container.read(strategyProvider.notifier).reorderPage(0, 2);

    final intent = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .single;
    final pending = intent.value.pending;
    expect(pending.op.entityType, StrategyOpEntityType.page);
    expect(pending.op.kind, StrategyOpKind.reorder);
    expect(pending.op.entityPublicId, 'page-1');
    expect(pending.op.sortIndex, 1);
    expect(pending.op.expectedRevision, 17);
    expect(intent.key, const EntitySyncKey.pageDescriptor('page-1'));
    expect(queue.flushNowCount, 1);
  });

  test('cloud page add is persisted with its descriptor and content', () async {
    final page = _page('page-1', 0);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page),
        shellRevision: 8,
      )),
      queue: queue,
    );

    await container.read(strategyProvider.notifier).addPage('Execute');

    final intent = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .single;
    final pending = intent.value.pending;
    expect(pending.op.entityType, StrategyOpEntityType.page);
    expect(pending.op.kind, StrategyOpKind.add);
    expect(pending.op.entityPublicId, isNotEmpty);
    expect(pending.op.sortIndex, 1);
    expect(pending.op.expectedRevision, 8);
    expect(pending.op.payload, {
      'name': 'Execute',
      'isAutoNamed': false,
      'isAttack': true,
      'settings': container.read(strategySettingsProvider).toJson(),
    });
    expect(
      intent.key,
      EntitySyncKey.pageDescriptor(pending.op.entityPublicId!),
    );
    expect(queue.flushNowCount, 1);
  });

  test('cloud page rename is persisted with the page revision', () async {
    final page = _page('page-1', 0, revision: 6);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page),
      )),
      queue: queue,
    );

    await container.read(strategyProvider.notifier).renamePage(
          'page-1',
          '  Retake  ',
        );

    final intent = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .single;
    final pending = intent.value.pending;
    expect(pending.op.entityType, StrategyOpEntityType.page);
    expect(pending.op.kind, StrategyOpKind.patch);
    expect(pending.op.entityPublicId, 'page-1');
    expect(pending.op.payload, {
      'name': 'Retake',
      'isAutoNamed': false,
    });
    expect(pending.op.expectedRevision, 6);
    expect(intent.key, const EntitySyncKey.pageDescriptor('page-1'));
    expect(queue.flushNowCount, 1);
  });

  test('cloud page delete is persisted with the shell revision', () async {
    final first = _page('page-1', 0);
    final second = _page('page-2', 1);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [first, second],
        activePage: _pageSnapshot(first),
        shellRevision: 12,
      )),
      queue: queue,
    );

    await container.read(strategyProvider.notifier).deletePage('page-2');

    final intent = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .single;
    final pending = intent.value.pending;
    expect(pending.op.entityType, StrategyOpEntityType.page);
    expect(pending.op.kind, StrategyOpKind.delete);
    expect(pending.op.entityPublicId, 'page-2');
    expect(pending.op.expectedRevision, 12);
    expect(intent.key, const EntitySyncKey.pageDescriptor('page-2'));
    expect(queue.flushNowCount, 1);
  });

  test('tombstone restore op carries the remote entity revision', () async {
    final page = _page('page-1', 0);
    final element = _textElement(
      page.publicId,
      'restored-text',
      'deleted remotely',
      revision: 4,
      deleted: true,
    );
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, elements: [element]),
    ));
    final container = await _syncContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: element.publicId, position: const Offset(10, 20))
        ..text = 'restored locally',
    ]);
    container.read(activePageLiveSyncProvider.notifier).markPageHydrated(
          strategyPublicId: 'cloud-strategy',
          pageId: page.publicId,
        );

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    final op = desired![EntitySyncKey.element(page.publicId, element.publicId)];
    expect(op, isNotNull);
    expect(op!.kind, StrategyOpKind.add);
    expect(op.expectedRevision, 4);
    expect(op.toConvexJson()['expectedElementRevision'], 4);
  });

  test('active page update rehydrates without a strategy revision change',
      () async {
    final page = _page('page-1', 0);
    final before = _editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
      shellRevision: 4,
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    expect(container.read(textProvider).single.text, 'before');

    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'after', contentRevision: 2),
      shellRevision: 4,
    ));
    await _settle();
    expect(container.read(textProvider).single.text, 'after');
  });

  test('failed animated page switch restores the previous idle page', () async {
    final pageOne = _page('page-1', 0);
    final pageTwo = _page('page-2', 1);
    final pageOneSnapshot = _pageSnapshot(pageOne, text: 'one');
    final pageTwoSnapshot = _pageSnapshot(pageTwo, text: 'two');
    final remote = _FakeRemoteEditorNotifier(
      _editorSnapshot(
        pages: [pageOne, pageTwo],
        activePage: pageOneSnapshot,
      ),
      pageCatalog: {
        pageOne.publicId: pageOneSnapshot,
        pageTwo.publicId: pageTwoSnapshot,
      },
    );
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    remote.failingPageId = pageTwo.publicId;

    await expectLater(
      container
          .read(strategyPageSessionProvider.notifier)
          .setActivePageAnimated(
            pageTwo.publicId,
            direction: PageTransitionDirection.forward,
          ),
      throwsStateError,
    );

    final session = container.read(strategyPageSessionProvider);
    expect(session.activePageId, pageOne.publicId);
    expect(session.transitionState, PageTransitionState.idle);
    expect(container.read(transitionProvider).active, isFalse);
    expect(remote.selectedPageIds, [pageTwo.publicId, pageOne.publicId]);
    expect(
      container.read(activePageLiveSyncProvider).hydratedPageId,
      pageOne.publicId,
    );
  });

  test('remote hydration waits until an unchanged text draft is dismissed',
      () async {
    final page = _page('page-1', 0);
    final before = _editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    const textId = 'text-page-1';
    container.read(textDraftProvider.notifier).setDraft(textId, 'before');
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'after', contentRevision: 2),
    ));
    await _settle();

    expect(container.read(textProvider).single.text, 'before');
    expect(container.read(textDraftProvider)[textId], 'before');

    container.read(textDraftProvider.notifier).clearDraft(textId);
    await _settle();

    expect(container.read(textProvider).single.text, 'after');
  });

  test('remote hydration preserves and queues a committed text draft',
      () async {
    final page = _page('page-1', 0);
    final before = _editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    const textId = 'text-page-1';
    container.read(textDraftProvider.notifier).setDraft(textId, 'local-intent');
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage:
          _pageSnapshot(page, text: 'remote-change', contentRevision: 2),
    ));
    await _settle();

    container.read(textDraftProvider.notifier).commitDraft(textId);
    await _settle();

    expect(container.read(textProvider).single.text, 'local-intent');
    expect(container.read(textDraftProvider), isEmpty);
    final pending = container.read(strategyOpQueueProvider).pending;
    expect(pending, isNotEmpty);
    expect(
      pending.any((item) =>
          item.op.entityPublicId == textId &&
          item.op.payload.toString().contains('local-intent')),
      isTrue,
    );
  });

  test('rejected local intent stays visible and requires attention', () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'server-before'),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(textProvider.notifier).commitText(
          'text-page-1',
          'local-losing-intent',
        );
    await _settle();
    final op = container
        .read(strategyOpQueueProvider)
        .pending
        .map((pending) => pending.op)
        .firstWhere((op) => op.entityPublicId == 'text-page-1');

    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        text: 'server-winner',
        contentRevision: 2,
      ),
    ));
    queue.reject(op);
    await _settle();

    expect(container.read(textProvider).single.text, 'local-losing-intent');
    expect(container.read(strategyOpQueueProvider).needsAttention, isTrue);
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      hasLength(1),
    );
    expect(container.read(strategyConflictProvider), hasLength(1));
    expect(container.read(strategyConflictProvider).single.opId, op.opId);
  });

  test('inactive page shell update does not rehydrate the active canvas',
      () async {
    final pageOne = _page('page-1', 0);
    final pageTwo = _page('page-2', 1);
    final before = _editorSnapshot(
      pages: [pageOne, pageTwo],
      activePage: _pageSnapshot(pageOne, text: 'remote'),
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local', position: const Offset(5, 5))..text = 'local',
    ]);

    remote.setSnapshot(_editorSnapshot(
      pages: [pageOne, _page('page-2', 1, revision: 2, name: 'Renamed')],
      activePage: _pageSnapshot(pageOne, text: 'remote'),
      shellRevision: 2,
    ));
    await _settle();
    expect(container.read(textProvider).single.text, 'local');
  });

  test('outbound diff waits for the matching active-page remote base',
      () async {
    final pageOne = _page('page-1', 0);
    final pageTwo = _page('page-2', 1);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [pageOne, pageTwo],
      activePage: _pageSnapshot(pageTwo, text: 'remote-two'),
    ));
    final container = await _syncContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local-one', position: const Offset(5, 5))
        ..text = 'local-one',
    ]);

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: 'page-1',
            );

    expect(desired, isNull);
  });

  test('final side is emitted while the opposite side is in flight', () async {
    final page = _page('page-1', 0, revision: 7);
    final queue = _FakeStrategyOpQueueNotifier();
    const key = EntitySyncKey.pageDescriptor('page-1');
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page),
      )),
      queue: queue,
    );
    container.read(strategyOpQueueProvider);
    queue.holdInFlight(
      key,
      const PagePatchOp(
        opId: 'defense-in-flight',
        pagePublicId: 'page-1',
        payload: {'isAttack': false},
        expectedPageRevision: 7,
      ),
    );
    container.read(activePageLiveSyncProvider.notifier).markPageHydrated(
          strategyPublicId: 'cloud-strategy',
          pageId: page.publicId,
        );

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    final sideOp = desired![key] as PagePatchOp;
    expect(sideOp.payload, {'isAttack': true});
    expect(sideOp.expectedPageRevision, 7);
    expect(
      desired.keys.where((candidate) =>
          candidate.kind == EntitySyncKeyKind.element ||
          candidate.kind == EntitySyncKeyKind.lineup),
      isEmpty,
    );
  });

  test('side switch authors exactly one Page descriptor operation', () async {
    final page = _page('page-1', 0, revision: 11);
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(
          page,
          settings: const {
            'agentSize': 35.0,
            'abilitySize': 25.0,
            'useNeutralTeamColors': false,
          },
        ),
      )),
      queue: _FakeStrategyOpQueueNotifier(),
    );
    container.read(activePageLiveSyncProvider.notifier).markPageHydrated(
          strategyPublicId: 'cloud-strategy',
          pageId: page.publicId,
        );

    container.read(mapProvider.notifier).switchSide();
    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    expect(desired, hasLength(1));
    final entry = desired!.entries.single;
    expect(entry.key, const EntitySyncKey.pageDescriptor('page-1'));
    final op = entry.value as PagePatchOp;
    expect(op.payload, {'isAttack': false});
    expect(op.expectedPageRevision, 11);
  });

  test('remote lineup survives hydration and an unrelated outbound diff',
      () async {
    final page = _page('page-1', 0);
    final lineup = _lineup(page.publicId, 'lineup-1');
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'remote', lineups: [lineup]),
    ));
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    expect(container.read(lineUpProvider).groups.single.id, 'lineup-1');
    container.read(textProvider).single.position = const Offset(50, 60);

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    expect(desired, isNotNull);
    expect(desired![EntitySyncKey.lineup(page.publicId, 'lineup-1')], isNull);
    expect(
      desired[EntitySyncKey.element(page.publicId, 'text-page-1')]?.kind,
      StrategyOpKind.patch,
    );
  });

  test('unhydrated canvas cannot author a remote lineup deletion', () async {
    final page = _page('page-1', 0);
    final lineup = _lineup(page.publicId, 'lineup-1');
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, lineups: [lineup]),
      )),
      queue: _FakeStrategyOpQueueNotifier(),
    );
    container.read(activePageLiveSyncProvider.notifier).setContext(
          strategyPublicId: 'cloud-strategy',
          activePageId: page.publicId,
        );

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    expect(desired, isNull);
  });

  test('new remote lineup is not inferred as a local deletion', () async {
    final page = _page('page-1', 0);
    final before = _editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'remote'),
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(strategySaveStateProvider.notifier).markDirty();
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        text: 'remote',
        contentRevision: 2,
        lineups: [_lineup(page.publicId, 'lineup-1')],
      ),
    ));

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    expect(desired, isNotNull);
    expect(
      desired![EntitySyncKey.lineup(page.publicId, 'lineup-1')],
      isNull,
    );
  });

  test('page switch persists old intent and never waits indefinitely',
      () async {
    final pageOne = _page('page-1', 0);
    final pageTwo = _page('page-2', 1);
    final first = _pageSnapshot(pageOne, text: 'one');
    final second = _pageSnapshot(pageTwo, text: 'two');
    final remote = _FakeRemoteEditorNotifier(
      _editorSnapshot(pages: [pageOne, pageTwo], activePage: first),
      pageCatalog: {'page-1': first, 'page-2': second},
    );
    final queue = _FakeStrategyOpQueueNotifier(blockFlush: true);
    final container = await _cloudContainer(remote: remote, queue: queue);
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'text-page-1', position: const Offset(5, 5))..text = 'one',
    ]);
    container
        .read(textDraftProvider.notifier)
        .setDraft('text-page-1', 'unsent draft');

    await session.setActivePage('page-2').timeout(const Duration(seconds: 2));
    expect(session.activePageId, 'page-2');
    expect(remote.selectedPageIds, contains('page-2'));
    expect(container.read(textProvider).single.text, 'two');
    expect(container.read(textDraftProvider), isEmpty);
    expect(queue.flushNowCount, 1);
    expect(
      container.read(strategyOpQueueProvider).pending.any((pending) =>
          pending.op.entityPublicId == 'text-page-1' &&
          pending.op.payload.toString().contains('unsent draft')),
      isTrue,
    );
  });

  test('persisted overlay wins over a late remote active-page base', () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'remote-before'),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local', position: const Offset(5, 5))
        ..text = 'local-intent',
    ]);
    await session.flushCurrentPage();

    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'remote-after'),
    ));
    await _settle();
    expect(container.read(textProvider).single.text, 'local-intent');
    expect(container.read(strategyOpQueueProvider).pending, isNotEmpty);
  });

  test('local mode page switching keeps its shipped Hive shape', () async {
    final box = await _openStrategyBox();
    final now = DateTime.utc(2026);
    StrategyPage localPage(String id, int index, String value) => StrategyPage(
          id: id,
          name: 'Page ${index + 1}',
          drawingData: const [],
          agentData: const [],
          abilityData: const [],
          textData: [
            PlacedText(id: 'text-$id', position: const Offset(1, 2))
              ..text = value,
          ],
          imageData: const [],
          utilityData: const [],
          sortIndex: index,
          isAttack: true,
          settings: StrategySettings(),
        );
    await box.put(
      'local-strategy',
      StrategyData(
        id: 'local-strategy',
        name: 'Local',
        mapData: MapValue.ascent,
        versionNumber: 1,
        lastEdited: now,
        folderID: null,
        pages: [
          localPage('page-1', 0, 'one'),
          localPage('page-2', 1, 'two'),
        ],
      ),
    );
    final container = ProviderContainer(overrides: [
      strategyOpQueueProvider.overrideWith(
        () => _FakeStrategyOpQueueNotifier(),
      ),
    ]);
    addTearDown(container.dispose);
    container.read(strategyProvider.notifier).setFromState(const StrategyState(
          strategyId: 'local-strategy',
          strategyName: 'Local',
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ));
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'local-strategy',
      source: StrategySource.local,
      selectFirstPageIfNeeded: true,
    );
    expect(container.read(textProvider).single.text, 'one');
    await session.setActivePage('page-2');
    expect(container.read(textProvider).single.text, 'two');
    expect(box.get('local-strategy')!.pages, hasLength(2));
  });
}
