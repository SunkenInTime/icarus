import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/transition_provider.dart'
    hide PageTransitionState;
import 'package:icarus/providers/user_preferences_provider.dart';
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
  bool failDiscard = false;

  /// While set, page writes wait on it before publishing, like the real
  /// queue's durable write.
  Completer<void>? writeGate;
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
    final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.successorByEntityKey,
    );
    if (desiredOp != null &&
        state.attentionByEntityKey.containsKey(entityKey)) {
      successors[entityKey] = QueuedEntityIntent(
        entityKey: entityKey,
        pending: PendingOp(op: desiredOp, clientId: 'test-client'),
      );
      state = state.copyWith(successorByEntityKey: successors);
      return;
    }
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
    final gate = writeGate;
    if (gate != null) await gate.future;
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.successorByEntityKey,
    );
    if (clearMissing) {
      queued.removeWhere((key, _) =>
          key.pageId == pageId && !desiredOpsByEntityKey.containsKey(key));
    }
    for (final entry in desiredOpsByEntityKey.entries) {
      if (state.attentionByEntityKey.containsKey(entry.key)) {
        successors[entry.key] = QueuedEntityIntent(
          entityKey: entry.key,
          pending: PendingOp(op: entry.value, clientId: 'test-client'),
        );
        continue;
      }
      queued[entry.key] = QueuedEntityIntent(
        entityKey: entry.key,
        pending: PendingOp(op: entry.value, clientId: 'test-client'),
      );
    }
    state = state.copyWith(
      queuedByEntityKey: queued,
      successorByEntityKey: successors,
    );
  }

  @override
  Future<void> flushNow() async {
    flushNowCount += 1;
    if (blockFlush) await Completer<void>().future;
  }

  @override
  Future<Set<EntitySyncKey>> discardRejected(
    Set<EntitySyncKey> entityKeys,
  ) async {
    if (failDiscard) return {};
    final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.attentionByEntityKey,
    );
    final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.successorByEntityKey,
    );
    final discarded = attention.keys.toSet().intersection(entityKeys);
    for (final key in discarded) {
      attention.remove(key);
      successors.remove(key);
    }
    state = state.copyWith(
      attentionByEntityKey: attention,
      successorByEntityKey: successors,
      clearError: attention.isEmpty,
    );
    return discarded;
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

  void clearInFlight() {
    state = state.copyWith(
      inFlightByEntityKey: const <EntitySyncKey, InFlightEntityIntent>{},
    );
  }
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

RemotePage _page(String id, int index,
    {int revision = 1, String? name, bool isAttack = true}) {
  final now = DateTime.utc(2026);
  return RemotePage(
    publicId: id,
    strategyPublicId: 'cloud-strategy',
    name: name ?? 'Page ${index + 1}',
    sortIndex: index,
    isAttack: isAttack,
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
  int sortIndex = 0,
  bool worldSized = false,
  bool deleted = false,
}) {
  final text = PlacedText(id: id, position: const Offset(10, 20))..text = value;
  if (worldSized) text.markSizeAsWorld();
  final payload = Map<String, dynamic>.from(text.toJson())
    ..['elementType'] = 'text';
  return RemoteElement(
    publicId: id,
    strategyPublicId: 'cloud-strategy',
    pagePublicId: pageId,
    elementType: 'text',
    payload: cloudElementPayload(kind: 'text', data: payload),
    sortIndex: sortIndex,
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

RemoteLineup _lineup(
  String pageId,
  String id, {
  Offset agentPosition = const Offset(10, 20),
  int revision = 1,
  int sortIndex = 0,
  String? nestedLineUpId,
}) {
  final lineUpId = nestedLineUpId ?? id;
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
          'position': <Object?, Object?>{
            'dx': agentPosition.dx,
            'dy': agentPosition.dy,
          },
          'type': 'sova',
          'isAlly': true,
          'state': 'none',
          'kind': 'plain',
          'lineUpID': lineUpId,
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
              'lineUpID': lineUpId,
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
    sortIndex: sortIndex,
    revision: revision,
    deleted: false,
  );
}

RemoteEditorSnapshot _editorSnapshot({
  required List<RemotePage> pages,
  required RemotePageSnapshot activePage,
  int shellRevision = 1,
  String? mapData,
  String? themeProfileId,
  String role = 'owner',
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
        role: role,
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
          snapshot: container.read(remoteEditorSnapshotProvider).requireValue!,
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

  test(
      'using cloud after a conflict replaces the canvas without resubmitting it',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(page.publicId, 'text-page-1', 'server-before',
              worldSized: true),
        ],
      ),
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

    const textId = 'text-page-1';
    const key = EntitySyncKey.element('page-1', textId);
    container.read(textProvider.notifier).commitText(
          textId,
          'local-losing-intent',
        );
    await _settle();
    final rejectedOp = container
        .read(strategyOpQueueProvider)
        .pending
        .map((pending) => pending.op)
        .firstWhere((op) => op.entityPublicId == textId);
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(page.publicId, textId, 'server-winner',
              worldSized: true),
        ],
        contentRevision: 2,
      ),
    ));
    queue.reject(rejectedOp);
    await _settle();
    container
        .read(textDraftProvider.notifier)
        .setDraft(textId, 'draft-in-progress');
    container
        .read(textDraftProvider.notifier)
        .setDraft('unrelated-text', 'keep-this-draft');

    final resolved = await container
        .read(strategyPageSessionProvider.notifier)
        .useCloudVersionsForRejected();
    await _settle();

    expect(resolved, isTrue);
    expect(container.read(textProvider).single.text, 'server-winner');
    expect(container.read(textDraftProvider), {
      'unrelated-text': 'keep-this-draft',
    });
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      isNot(contains(key)),
    );
    expect(
      container.read(activePageLiveSyncProvider).overlayByEntityKey,
      isNot(contains(key)),
    );
    expect(
      container
          .read(strategyOpQueueProvider)
          .pending
          .map((pending) => pending.op.entityPublicId),
      isNot(contains(textId)),
    );

    container.read(textDraftProvider.notifier).clearDraft(textId);
    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );
    expect(desired, isNotNull);
    expect(desired, isNot(contains(key)));
    await queue.syncDesiredOpsForPage(
      pageId: page.publicId,
      desiredOpsByEntityKey: desired!,
      flushImmediately: false,
    );
    expect(
      container
          .read(strategyOpQueueProvider)
          .pending
          .map((pending) => pending.op.entityPublicId),
      isNot(contains(textId)),
    );
  });

  for (final failDiscard in [false, true]) {
    test('use cloud preserves unrelated edits when discard fails=$failDiscard',
        () async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, elements: [
          _textElement(page.publicId, 'conflicted', 'server-before',
              worldSized: true),
          _textElement(page.publicId, 'unrelated', 'server-original',
              worldSized: true),
        ]),
      ));
      final queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      final session = container.read(strategyPageSessionProvider.notifier);
      queue.failDiscard = failDiscard;
      await session.initializeForStrategy(
        strategyId: 'cloud-strategy',
        source: StrategySource.cloud,
        selectFirstPageIfNeeded: true,
      );
      container
          .read(textProvider.notifier)
          .commitText('conflicted', 'local-loser');
      await _settle();
      final rejected = container
          .read(strategyOpQueueProvider)
          .pending
          .map((p) => p.op)
          .firstWhere((op) => op.entityPublicId == 'conflicted');
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, contentRevision: 2, elements: [
          _textElement(page.publicId, 'conflicted', 'server-winner',
              worldSized: true),
          _textElement(page.publicId, 'unrelated', 'server-original',
              worldSized: true),
        ]),
      ));
      queue.reject(rejected);
      await _settle();
      container
          .read(textProvider.notifier)
          .commitText('unrelated', 'keep-my-edit');
      container.read(mapProvider.notifier).fromHive(MapValue.haven, true);
      container
          .read(strategyThemeProvider.notifier)
          .fromStrategy(profileId: 'local-theme');
      await _settle();
      expect(container.read(strategyOpQueueProvider).queuedByEntityKey,
          contains(const EntitySyncKey.element('page-1', 'unrelated')));
      expect(await session.useCloudVersionsForRejected(), !failDiscard);
      await _settle();
      final canvas = {
        for (final text in container.read(textProvider)) text.id: text.text
      };
      final desired =
          container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
                strategyPublicId: 'cloud-strategy',
                pageId: 'page-1',
              )!;
      await queue.syncDesiredOpsForPage(
          pageId: 'page-1', desiredOpsByEntityKey: desired);
      expect(canvas['unrelated'], 'keep-my-edit');
      expect(
          canvas['conflicted'], failDiscard ? 'local-loser' : 'server-winner');
      expect(container.read(mapProvider).currentMap, MapValue.haven);
      expect(container.read(strategyThemeProvider).profileId, 'local-theme');
      final queued = container.read(strategyOpQueueProvider).queuedByEntityKey;
      expect(
          queued[const EntitySyncKey.element('page-1', 'unrelated')]!
              .pending
              .op
              .payload
              .toString(),
          contains('keep-my-edit'));
      expect(queued,
          isNot(contains(const EntitySyncKey.element('page-1', 'conflicted'))));
    });
  }

  test('using cloud with no remaining attention is a silent no-op', () async {
    final page = _page('page-1', 0);
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, text: 'remote'),
      )),
      queue: _FakeStrategyOpQueueNotifier(),
    );
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );

    expect(await session.useCloudVersionsForRejected(), isTrue);
  });

  test('failed cloud hydration keeps the rejected work available', () async {
    final page = _page('page-1', 0);
    const textId = 'text-page-1';
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );
    container.read(textProvider.notifier).commitText(textId, 'local-edit');
    await _settle();
    final rejectedOp = container
        .read(strategyOpQueueProvider)
        .pending
        .map((pending) => pending.op)
        .firstWhere((op) => op.entityPublicId == textId);
    final malformedLineup = RemoteLineup(
      publicId: 'bad-lineup',
      strategyPublicId: 'cloud-strategy',
      pagePublicId: page.publicId,
      payload: const {
        'kind': 'lineupGroup',
        'payloadVersion': 1,
        'data': {'broken': true},
      },
      sortIndex: 0,
      revision: 1,
      deleted: false,
    );
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(page.publicId, textId, 'server-winner'),
        ],
        lineups: [malformedLineup],
      ),
    ));
    queue.reject(rejectedOp);
    await _settle();

    await expectLater(
      session.useCloudVersionsForRejected(),
      throwsA(isA<FormatException>()),
    );

    final key = EntitySyncKey.element(page.publicId, textId);
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      contains(key),
    );
    expect(
      container.read(activePageLiveSyncProvider).overlayByEntityKey,
      contains(key),
    );
  });

  test('using cloud for a strategy conflict restores remote map and theme',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page),
      shellRevision: 3,
      mapData: Maps.mapNames[MapValue.haven],
      themeProfileId: 'remote-theme',
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

    container.read(mapProvider.notifier).updateMap(MapValue.ascent);
    container.read(strategyThemeProvider.notifier).setProfile('local-theme');
    await _settle();
    final rejectedOp = container
        .read(strategyOpQueueProvider)
        .pending
        .map((pending) => pending.op)
        .firstWhere((op) => op.entityType == StrategyOpEntityType.strategy);
    queue.reject(rejectedOp);
    await _settle();

    final resolved = await container
        .read(strategyPageSessionProvider.notifier)
        .useCloudVersionsForRejected();
    await _settle();

    expect(resolved, isTrue);
    expect(container.read(mapProvider).currentMap, MapValue.haven);
    expect(container.read(strategyThemeProvider).profileId, 'remote-theme');
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      isNot(contains(const EntitySyncKey.strategy())),
    );

    await container
        .read(strategyProvider.notifier)
        .notifyCloudStrategyMutation(flushImmediately: false);
    expect(
      container
          .read(strategyOpQueueProvider)
          .pending
          .map((pending) => pending.op.entityType),
      isNot(contains(StrategyOpEntityType.strategy)),
    );
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
          snapshot: container.read(remoteEditorSnapshotProvider).requireValue!,
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

  test('final text is emitted while an earlier edit is in flight', () async {
    final page = _page('page-1', 0);
    const textId = 'text-page-1';
    final remoteText = _textElement(
      page.publicId,
      textId,
      'before',
      worldSized: true,
    );
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, elements: [remoteText]),
      )),
      queue: queue,
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    const key = EntitySyncKey.element('page-1', textId);
    final firstEdit = ElementPatchOp(
      opId: 'first-edit-in-flight',
      elementPublicId: textId,
      pagePublicId: page.publicId,
      payload: _textElement(
        page.publicId,
        textId,
        'first-edit',
        worldSized: true,
      ).payload,
      sortIndex: 0,
      expectedElementRevision: 1,
    );
    queue.holdInFlight(key, firstEdit);
    container.read(textDraftProvider.notifier).setDraft(textId, 'final-edit');

    final beforeAck =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            )![key] as ElementPatchOp;
    expect(beforeAck.payload.toString(), contains('final-edit'));
    expect(beforeAck.expectedElementRevision, 1);

    container.read(activePageLiveSyncProvider.notifier).recordAckBatch([
      AckedEntityIntent(
        entityKey: key,
        op: firstEdit,
        ack: const AppliedOpAck(
          opId: 'first-edit-in-flight',
          revision: 2,
        ),
      ),
    ]);
    queue.clearInFlight();

    final afterAck =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            )![key] as ElementPatchOp;
    expect(afterAck.payload.toString(), contains('final-edit'));
    expect(afterAck.expectedElementRevision, 2);
  });

  test('an ack after leaving a page advances its retained overlay revision',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, elements: [
        _textElement('page-1', 'text-a', 'before', worldSized: true),
      ]),
    ));
    final container = await _syncContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    final sync = container.read(activePageLiveSyncProvider.notifier);
    sync.markPageHydrated(
        strategyPublicId: 'cloud-strategy',
        pageId: 'page-1',
        snapshot: remote.initialSnapshot);
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'text-a', position: const Offset(10, 20))
        ..text = 'my edit'
        ..markSizeAsWorld(),
    ]);
    const key = EntitySyncKey.element('page-1', 'text-a');
    final op = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: 'page-1',
    )![key]!;
    sync.setContext(strategyPublicId: 'cloud-strategy', activePageId: 'page-2');
    sync.recordAckBatch([
      AckedEntityIntent(
          entityKey: key, op: op, ack: AppliedOpAck(opId: op.opId, revision: 2))
    ]);
    expect(
        container
            .read(activePageLiveSyncProvider)
            .overlayByEntityKey[key]!
            .baseRevision,
        2);

    remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, elements: [
          _textElement('page-1', 'text-a', 'my edit',
              revision: 2, worldSized: true),
        ])));
    sync.markPageHydrated(
        strategyPublicId: 'cloud-strategy',
        pageId: 'page-1',
        snapshot: remote.initialSnapshot);
    container.read(textProvider.notifier).commitText('text-a', 'next edit');
    final next = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: 'page-1',
    )![key] as ElementPatchOp;
    expect(next.expectedElementRevision, 2);
    expect(next.payload.toString(), contains('next edit'));
  });

  test('rename acks preserve the side baseline during a remote side change',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page),
    ));
    final container = await _syncContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    final sync = container.read(activePageLiveSyncProvider.notifier);
    container.read(mapProvider.notifier).fromHive(MapValue.ascent, true);
    sync.markPageHydrated(
        strategyPublicId: 'cloud-strategy',
        pageId: 'page-1',
        snapshot: remote.initialSnapshot);
    const key = EntitySyncKey.pageDescriptor('page-1');
    sync.recordAckBatch([
      const AckedEntityIntent(
        entityKey: key,
        op: PagePatchOp(
            opId: 'rename',
            pagePublicId: 'page-1',
            payload: {'name': 'Renamed'},
            expectedPageRevision: 1),
        ack: AppliedOpAck(opId: 'rename', revision: 2),
      )
    ]);
    final changed =
        _page('page-1', 0, revision: 3, name: 'Renamed', isAttack: false);
    remote.setSnapshot(_editorSnapshot(
      pages: [changed],
      activePage: _pageSnapshot(changed),
    ));
    final desired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: 'page-1',
    )!;
    expect(desired, isNot(contains(key)));
    expect(
        sync
            .projectPageState(
              strategyPublicId: 'cloud-strategy',
              pageId: 'page-1',
            )!
            .isAttack,
        isFalse);
  });

  test('a final delete is emitted behind an in-flight local add', () async {
    final page = _page('page-1', 0);
    const textId = 'new-local-text';
    const key = EntitySyncKey.element('page-1', textId);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page),
      )),
      queue: queue,
    );
    final sync = container.read(activePageLiveSyncProvider.notifier);
    sync.markPageHydrated(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
      snapshot: container.read(remoteEditorSnapshotProvider).requireValue!,
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: textId, position: const Offset(10, 20))
        ..text = 'first'
        ..markSizeAsWorld(),
    ]);

    final firstDesired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
    );
    final add = firstDesired![key] as ElementAddOp;
    queue.holdInFlight(key, add);
    container.read(textProvider.notifier).removeText(textId);

    final finalDesired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
    );

    final delete = finalDesired![key] as ElementDeleteOp;
    expect(delete.expectedElementRevision, 0);
  });

  test('restart retains a queued add missing from canvas and remote', () async {
    final page = _page('page-1', 0);
    const textId = 'queued-before-restart';
    const key = EntitySyncKey.element('page-1', textId);
    final add = ElementAddOp(
      opId: 'add-before-restart',
      elementPublicId: textId,
      pagePublicId: page.publicId,
      payload: _textElement(page.publicId, textId, 'unsent').payload,
      sortIndex: 0,
    );
    final store = MemoryDurableStrategyOutboxStore();
    final firstContainer = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
      strategyOutboxSessionProvider.overrideWithValue(
        const StrategyOutboxSession(
          accountId: null,
          isReady: false,
          hasAuthIncident: false,
        ),
      ),
    ]);
    firstContainer
        .read(cloudCollabModeProvider.notifier)
        .setForceLocalFallback(true);
    final firstQueue = firstContainer.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('cloud-strategy', accountId: 'account-a');
    await firstQueue.enqueue(add, flushImmediately: false);
    expect(store.load().records.single.pending.op.opId, 'add-before-restart');
    firstContainer.dispose();

    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page),
    ));
    final restarted = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
      strategyOutboxSessionProvider.overrideWithValue(
        const StrategyOutboxSession(
          accountId: null,
          isReady: false,
          hasAuthIncident: false,
        ),
      ),
      remoteEditorSnapshotProvider.overrideWith(() => remote),
    ]);
    addTearDown(restarted.dispose);
    restarted
        .read(cloudCollabModeProvider.notifier)
        .setForceLocalFallback(true);
    final restartedQueue = restarted.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('cloud-strategy', accountId: 'account-a');
    await restarted.read(remoteEditorSnapshotProvider.future);
    final sync = restarted.read(activePageLiveSyncProvider.notifier);
    sync.markPageHydrated(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
      snapshot: restarted.read(remoteEditorSnapshotProvider).requireValue!,
    );

    final desired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
    );

    final retained = desired![key] as ElementAddOp;
    expect(retained.opId, 'add-before-restart');
    expect(retained.payload, add.payload);
    await restartedQueue.syncDesiredOpsForPage(
      pageId: page.publicId,
      desiredOpsByEntityKey: desired,
      flushImmediately: false,
    );
    expect(
      restarted
          .read(strategyOpQueueProvider)
          .queuedByEntityKey[key]!
          .pending
          .op,
      isA<ElementAddOp>(),
    );
    final durable = store.load().records.singleWhere(
          (record) => record.entityKey == key,
        );
    expect(durable.pending.op.opId, 'add-before-restart');
  });

  test('hydration keeps the exact snapshot used to load the canvas', () async {
    const textId = 'text-page-1';
    final hydratedPage = _page('page-1', 0);
    final hydratedSnapshot = _editorSnapshot(
      pages: [hydratedPage],
      activePage: _pageSnapshot(
        hydratedPage,
        elements: [
          _textElement(
            hydratedPage.publicId,
            textId,
            'hydrated-value',
            worldSized: true,
          ),
        ],
      ),
    );
    final newerPage = _page('page-1', 0, revision: 2);
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [newerPage],
        activePage: _pageSnapshot(
          newerPage,
          elements: [
            _textElement(
              newerPage.publicId,
              textId,
              'newer-remote-value',
              revision: 2,
              worldSized: true,
            ),
          ],
        ),
      )),
      queue: _FakeStrategyOpQueueNotifier(),
    );
    final hydratedText = PlacedText(
      id: textId,
      position: const Offset(10, 20),
    )
      ..text = 'hydrated-value'
      ..markSizeAsWorld();
    container.read(textProvider.notifier).fromHive([hydratedText]);

    final sync = container.read(activePageLiveSyncProvider.notifier);
    sync.markPageHydrated(
      strategyPublicId: 'cloud-strategy',
      pageId: hydratedPage.publicId,
      snapshot: hydratedSnapshot,
    );
    container.read(textDraftProvider.notifier).setDraft(textId, 'local-edit');

    final desired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: hydratedPage.publicId,
    );

    final op = desired![EntitySyncKey.element(hydratedPage.publicId, textId)]
        as ElementPatchOp;
    expect(op.payload.toString(), contains('local-edit'));
    expect(op.expectedElementRevision, 1);
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
          snapshot: container.read(remoteEditorSnapshotProvider).requireValue!,
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

    expect(container.read(lineUpProvider).origins.single.id, 'lineup-1');
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

  group('switching side on all cloud pages', () {
    Future<(ProviderContainer, _FakeStrategyOpQueueNotifier)>
        openTwoPages() async {
      final first = _page('page-a', 0, revision: 4);
      final second = _page('page-b', 1, revision: 7);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [first, second],
        activePage: _pageSnapshot(first),
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
      return (container, queue);
    }

    bool? queuedSideOf(_FakeStrategyOpQueueNotifier queue, String pageId) {
      final op = queue.state
          .queuedByEntityKey[EntitySyncKey.pageDescriptor(pageId)]?.pending.op;
      return op is PagePatchOp ? op.payload['isAttack'] as bool? : null;
    }

    test('a second toggle supersedes the first while it is still queued',
        () async {
      final (container, queue) = await openTwoPages();
      final notifier = container.read(strategyProvider.notifier);

      await notifier.switchSide(allPages: true);
      expect(queuedSideOf(queue, 'page-b'), isFalse);

      // The server has not taken the first change yet: page B still reads
      // Attack remotely, the side this toggle asks for.
      await notifier.switchSide(allPages: true);

      expect(container.read(mapProvider).isAttack, isTrue);
      expect(queuedSideOf(queue, 'page-b'), isTrue);
      await _settle();
    });

    test('a second toggle follows a side change that is in flight', () async {
      final (container, queue) = await openTwoPages();
      final notifier = container.read(strategyProvider.notifier);
      const key = EntitySyncKey.pageDescriptor('page-b');

      await notifier.switchSide(allPages: true);
      final sent = queue.state.queuedByEntityKey[key]!.pending.op;
      queue.state = queue.state.copyWith(
        queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
      );
      queue.holdInFlight(key, sent);

      await notifier.switchSide(allPages: true);

      expect(queuedSideOf(queue, 'page-b'), isTrue);
      await _settle();
    });

    test('overlapping toggles reconcile across unpublished durable writes',
        () async {
      final first = _page('page-a', 0, revision: 4);
      final second = _page('page-b', 1, revision: 7);
      final third = _page('page-c', 2, revision: 9);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [first, second, third],
        activePage: _pageSnapshot(first),
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
      final notifier = container.read(strategyProvider.notifier);

      queue.writeGate = Completer<void>();
      final toDefense = notifier.switchSide(allPages: true);
      // Starts before the first toggle's writes have published anything.
      final backToAttack = notifier.switchSide(allPages: true);
      queue.writeGate!.complete();
      await Future.wait([toDefense, backToAttack]);

      expect(container.read(mapProvider).isAttack, isTrue);
      expect(queuedSideOf(queue, 'page-b'), isTrue);
      expect(queuedSideOf(queue, 'page-c'), isTrue);
      await _settle();
    });
  });

  group('lineup history through the cloud projection', () {
    const placedAt = Offset(100, 100);
    late _FakeStrategyOpQueueNotifier queue;

    /// Page settings that round-trip exactly, so live sync authors nothing
    /// for them; the agent size marks which server revision is on screen.
    CloudPayload settingsFor(int contentRevision) =>
        StrategySettings(agentSize: 30 + contentRevision.toDouble()).toJson();

    Future<(ProviderContainer, _FakeRemoteEditorNotifier, RemotePage)>
        openEmpty() async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, settings: settingsFor(1)),
      ));
      queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      return (container, remote, page);
    }

    /// Places a lineup the way the editor does.
    LineUpLink place(ProviderContainer container) {
      final lineUps = container.read(lineUpProvider.notifier)..startFresh();
      lineUps.setDraftAgent(PlacedAgent(
        id: 'agent-x',
        type: AgentType.sova,
        position: placedAt,
      ));
      lineUps.setDraftAbility(PlacedAbility(
        id: 'ability-x',
        data: AgentData.agents[AgentType.sova]!.abilities[2],
        position: const Offset(300, 300),
      ));
      return lineUps.commitPlacement()!;
    }

    Map<EntitySyncKey, StrategyOp> desiredOps(
      ProviderContainer container,
      RemotePage page,
    ) {
      return container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
                strategyPublicId: 'cloud-strategy',
                pageId: page.publicId,
              ) ??
          const {};
    }

    /// The lineups the server stores once [ops] apply to [previous]: the
    /// real projection the client sent, JSON round-tripped.
    /// [teammate] edits each stored lineup's data in the same round, as a
    /// teammate's change landing alongside ours would.
    List<RemoteLineup> apply(
      Iterable<StrategyOp> ops,
      RemotePage page, {
      required int revision,
      required List<RemoteLineup> previous,
      void Function(Map<String, dynamic> data)? teammate,
    }) {
      final byId = {for (final lineup in previous) lineup.publicId: lineup};
      for (final op in ops) {
        final (id, payload) = switch (op) {
          LineupAddOp(:final lineupPublicId, :final payload) => (
              lineupPublicId,
              payload
            ),
          LineupPatchOp(:final lineupPublicId, :final payload) => (
              lineupPublicId,
              payload ?? byId[lineupPublicId]!.payload
            ),
          LineupDeleteOp(:final lineupPublicId) => (lineupPublicId, null),
          _ => (null, null),
        };
        if (id == null) continue;
        if (payload == null) {
          byId.remove(id);
          continue;
        }
        byId[id] = RemoteLineup(
          publicId: id,
          strategyPublicId: 'cloud-strategy',
          pagePublicId: page.publicId,
          payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
          sortIndex: 0,
          revision: revision,
          deleted: false,
        );
      }
      if (teammate != null) {
        for (final lineup in byId.values) {
          teammate(lineup.payload['data'] as Map<String, dynamic>);
        }
      }
      return byId.values.toList();
    }

    RemoteEditorSnapshot serverSnapshot(
      RemotePage page,
      List<RemoteLineup> lineups,
      int contentRevision, {
      List<RemotePage>? pages,
    }) {
      return _editorSnapshot(
        pages: pages ?? [page],
        activePage: _pageSnapshot(
          page,
          settings: settingsFor(contentRevision),
          contentRevision: contentRevision,
          lineups: lineups,
        ),
      );
    }

    Future<void> settleSync(
        ProviderContainer container, int contentRevision) async {
      // Ack reconciliation refreshes, re-syncs and rehydrates in turn.
      for (var i = 0; i < 10; i++) {
        await _settle();
      }
      expect(
        container.read(strategySettingsProvider).agentSize,
        30 + contentRevision,
        reason: 'the page rehydrated from the server',
      );
    }

    Map<EntitySyncKey, StrategyOp> queuedOps() => {
          for (final entry in queue.state.queuedByEntityKey.entries)
            entry.key: entry.value.pending.op,
        };

    /// One queue update drains [ops] and publishes their acks.
    void publishAcks(Map<EntitySyncKey, StrategyOp> ops, int revision) {
      final acks = [
        for (final entry in ops.entries)
          AckedEntityIntent(
            entityKey: entry.key,
            op: entry.value,
            ack: AppliedOpAck(opId: entry.value.opId, revision: revision),
          ),
      ];
      queue.state = queue.state.copyWith(
        queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
        lastAcks: [for (final intent in acks) intent.ack],
        lastAckBatch: acks,
      );
    }

    /// The edits' scheduled sync queues ops; one queue update then drains
    /// them and publishes their acks (which also marks the page saved), and
    /// the session reconciles the acks, refreshes from the server and
    /// rehydrates, as in production. Returns what the server holds.
    Future<List<RemoteLineup>> land(
      ProviderContainer container,
      _FakeRemoteEditorNotifier remote,
      RemotePage page, {
      required List<RemoteLineup> previous,
      required int revision,
      required int contentRevision,
      void Function(Map<String, dynamic> data)? teammate,
    }) async {
      await _settle();
      final pending = queuedOps();
      final lineups = apply(pending.values, page,
          revision: revision, previous: previous, teammate: teammate);
      // The session fetches this on the refresh that follows the acks.
      remote.initialSnapshot = serverSnapshot(page, lineups, contentRevision);
      publishAcks(pending, revision);
      await settleSync(container, contentRevision);
      return lineups;
    }

    Map<String, dynamic> firstItem(Map<String, dynamic> data) =>
        (data['items'] as List).first as Map<String, dynamic>;

    void expectNoEmptyGroups(Map<EntitySyncKey, StrategyOp> ops) {
      for (final op in ops.values) {
        final payload = switch (op) {
          LineupAddOp(:final payload) => payload,
          LineupPatchOp(:final payload) => payload,
          _ => null,
        };
        if (payload == null) continue;
        final data = cloudPayloadData(payload);
        expect(data['items'] as List, isNotEmpty, reason: '$op');
      }
    }

    test('undoing a details edit made before the first hydration', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      container
          .read(lineUpProvider.notifier)
          .updateLink(link.copyWith(notes: 'jump throw'));
      await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);

      container.read(actionProvider.notifier).undoAction();

      final lineUps = container.read(lineUpProvider);
      expect(lineUps.links.single.notes, '');
      expect(lineUps.landingById(lineUps.links.single.landingId), isNotNull);
      expect(lineUps.landings, hasLength(1));
      final afterUndo = desiredOps(container, page);
      expectNoEmptyGroups(afterUndo);
      expect(afterUndo.values.whereType<LineupDeleteOp>(), isEmpty);
      expect(afterUndo.values.whereType<LineupPatchOp>(), hasLength(1));
      await _settle();
    });

    test('a landing keeps its id through the projection', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      container
          .read(lineUpProvider.notifier)
          .updateLandingPosition(link.landingId, const Offset(320, 340));
      await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);

      expect(container.read(lineUpProvider).landings.single.id, link.landingId);

      // The pre-hydration landing move still undoes, onto the same landing.
      container.read(actionProvider.notifier).undoAction();
      expect(
        container.read(lineUpProvider).landings.single.ability.position,
        const Offset(300, 300),
      );
      // Undoing the placement removes the whole lineup, leaving no node.
      container.read(actionProvider.notifier).undoAction();
      final empty = container.read(lineUpProvider);
      expect(empty.links, isEmpty);
      expect(empty.origins, isEmpty);
      expect(empty.landings, isEmpty);
      await _settle();
    });

    test('undoing a move keeps a teammate weapon on the same origin', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      var lineups = await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);
      container
          .read(lineUpProvider.notifier)
          .updateOriginAgentPosition(link.originId, const Offset(500, 500));
      lineups = await land(container, remote, page,
          previous: lineups, revision: 2, contentRevision: 3);

      // Then a teammate arms the same origin.
      final armed = jsonDecode(jsonEncode(lineups.single.payload))
          as Map<String, dynamic>;
      ((armed['data'] as Map)['agent'] as Map)['weapon'] = 'vandal';
      remote.setSnapshot(serverSnapshot(
          page,
          [
            RemoteLineup(
              publicId: lineups.single.publicId,
              strategyPublicId: 'cloud-strategy',
              pagePublicId: page.publicId,
              payload: armed,
              sortIndex: 0,
              revision: 3,
              deleted: false,
            ),
          ],
          4));
      await settleSync(container, 4);
      expect(
        container.read(lineUpProvider).originById(link.originId)!.agent.weapon,
        WeaponType.vandal,
      );

      container.read(actionProvider.notifier).undoAction();

      final origin = container.read(lineUpProvider).originById(link.originId)!;
      expect(origin.agent.position, placedAt);
      expect(origin.agent.weapon, WeaponType.vandal);
      final patch =
          desiredOps(container, page).values.whereType<LineupPatchOp>().single;
      final agent = cloudPayloadData(patch.payload)['agent'] as Map;
      expect(agent['weapon'], 'vandal');
      await _settle();
    });

    test('an edit before a deletion stays undoable after the deletion lands',
        () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      final lineups = await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);
      final lineUps = container.read(lineUpProvider.notifier);
      const moved = Offset(500, 500);

      lineUps.updateOriginAgentPosition(link.originId, moved);
      lineUps.deleteOrigin(link.originId);
      final after = await land(container, remote, page,
          previous: lineups, revision: 2, contentRevision: 3);
      expect(after, isEmpty);

      final history = container.read(actionProvider.notifier);
      Offset? originPosition() => container
          .read(lineUpProvider)
          .originById(link.originId)
          ?.agent
          .position;

      history.undoAction();
      expect(originPosition(), moved);
      history.undoAction();
      expect(originPosition(), placedAt);
      history.redoAction();
      expect(originPosition(), moved);
      history.redoAction();
      expect(originPosition(), isNull);
      await _settle();
    });
    test(
        'undoing a deletion rebuilds a lineup whose shared landing was renamed',
        () async {
      final (container, remote, page) = await openEmpty();
      final a = place(container);
      final lineUps = container.read(lineUpProvider.notifier)
        ..startToLanding(a.landingId);
      lineUps.setDraftAgent(PlacedAgent(
        id: 'agent-y',
        type: AgentType.sova,
        position: const Offset(150, 150),
      ));
      final b = lineUps.commitPlacement()!;
      expect(b.landingId, a.landingId, reason: 'B fans in to A\'s landing');
      lineUps.deleteOrigin(a.originId);
      // The first hydration renames the surviving landing to B's link id.
      await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);
      expect(container.read(lineUpProvider).landings.single.id, b.id);

      container.read(actionProvider.notifier).undoAction();

      final restored = container.read(lineUpProvider);
      expect(restored.links, hasLength(2));
      for (final link in restored.links) {
        expect(restored.landingById(link.landingId), isNotNull,
            reason: link.id);
      }
      expect(
        restored
            .landingById(restored.linkById(a.id)!.landingId)!
            .ability
            .position,
        const Offset(300, 300),
      );
      final ops = desiredOps(container, page);
      expectNoEmptyGroups(ops);
      expect(ops.values.whereType<LineupDeleteOp>(), isEmpty);
      final restoredA = ops[EntitySyncKey.lineup(page.publicId, a.originId)];
      expect(restoredA, isA<LineupAddOp>());
      expect(
        container.read(activePageLiveSyncProvider).unsyncableLineupKeys,
        isEmpty,
      );
      await _settle();
    });

    test('a lineup whose landing is missing is refused, loudly', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);
      final graph = container.read(lineUpProvider).graph;
      // A graph that projects an origin with links but no items.
      container.read(lineUpProvider.notifier).fromHive(
            LineUpGraph(origins: graph.origins, links: graph.links),
          );

      final ops = desiredOps(container, page);

      final key = EntitySyncKey.lineup(page.publicId, link.originId);
      expect(ops[key], isNull);
      expectNoEmptyGroups(ops);
      // Drives the attention status (see cloud_sync_button_test).
      expect(
        container.read(activePageLiveSyncProvider).unsyncableLineupKeys,
        {key},
      );

      // Restoring the landing clears the refusal.
      container.read(lineUpProvider.notifier).fromHive(graph);
      desiredOps(container, page);
      expect(
        container.read(activePageLiveSyncProvider).unsyncableLineupKeys,
        isEmpty,
      );
      await _settle();
    });

    test('undoing a notes edit keeps an image a teammate added', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      var lineups = await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);
      container
          .read(lineUpProvider.notifier)
          .updateLink(link.copyWith(notes: 'jump throw'));
      lineups = await land(
        container,
        remote,
        page,
        previous: lineups,
        revision: 2,
        contentRevision: 3,
        teammate: (data) => firstItem(data)['images'] = [
          {'id': 'teammate-image', 'fileExtension': '.png'},
        ],
      );
      expect(
        container.read(lineUpProvider).links.single.images.map((i) => i.id),
        ['teammate-image'],
      );

      container.read(actionProvider.notifier).undoAction();

      final restored = container.read(lineUpProvider).links.single;
      expect(restored.notes, '');
      expect(restored.images.map((image) => image.id), ['teammate-image']);
      final patch =
          desiredOps(container, page).values.whereType<LineupPatchOp>().single;
      final item = firstItem(cloudPayloadData(patch.payload));
      expect(item['notes'], '');
      expect(
        (item['images'] as List).map((image) => (image as Map)['id']),
        ['teammate-image'],
      );
      await _settle();
    });

    List<String> imageIds(ProviderContainer container) => container
        .read(lineUpProvider)
        .links
        .single
        .images
        .map((image) => image.id)
        .toList();

    List<SimpleImageData> images(List<String> ids) => [
          for (final id in ids) SimpleImageData(id: id, fileExtension: '.png'),
        ];

    test('undo and redo of image removals keep the image order', () async {
      final (container, remote, page) = await openEmpty();
      final placed = place(container);
      final lineUps = container.read(lineUpProvider.notifier);
      lineUps.updateLink(placed.copyWith(images: images(['a', 'b', 'c', 'd'])));
      var lineups = await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);
      // Remove the first image, then two from the middle.
      lineUps.updateLink(container
          .read(lineUpProvider)
          .links
          .single
          .copyWith(images: images(['b', 'c', 'd'])));
      lineUps.updateLink(container
          .read(lineUpProvider)
          .links
          .single
          .copyWith(images: images(['d'])));
      lineups = await land(container, remote, page,
          previous: lineups, revision: 2, contentRevision: 3);
      final history = container.read(actionProvider.notifier);

      history.undoAction();
      expect(imageIds(container), ['b', 'c', 'd']);
      history.undoAction();
      expect(imageIds(container), ['a', 'b', 'c', 'd']);
      final patch =
          desiredOps(container, page).values.whereType<LineupPatchOp>().single;
      expect(
        (firstItem(cloudPayloadData(patch.payload))['images'] as List)
            .map((image) => (image as Map)['id']),
        ['a', 'b', 'c', 'd'],
      );
      history.redoAction();
      expect(imageIds(container), ['b', 'c', 'd']);
      history.redoAction();
      expect(imageIds(container), ['d']);
      history.undoAction();
      history.undoAction();
      expect(imageIds(container), ['a', 'b', 'c', 'd']);
      await _settle();
    });

    test('undoing an image removal keeps an image a teammate added between',
        () async {
      final (container, remote, page) = await openEmpty();
      final placed = place(container);
      final lineUps = container.read(lineUpProvider.notifier);
      lineUps.updateLink(placed.copyWith(images: images(['a', 'b', 'c'])));
      var lineups = await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);
      lineUps.updateLink(container
          .read(lineUpProvider)
          .links
          .single
          .copyWith(images: images(['a', 'c'])));
      // Our removal of b lands, and a teammate adds x right after a.
      lineups = await land(
        container,
        remote,
        page,
        previous: lineups,
        revision: 2,
        contentRevision: 3,
        teammate: (data) => (firstItem(data)['images'] as List)
            .insert(1, {'id': 'x', 'fileExtension': '.png'}),
      );
      expect(imageIds(container), ['a', 'x', 'c']);
      final history = container.read(actionProvider.notifier);

      history.undoAction();
      expect(imageIds(container), ['a', 'x', 'b', 'c']);
      history.redoAction();
      expect(imageIds(container), ['a', 'x', 'c']);
      history.undoAction();
      expect(imageIds(container), ['a', 'x', 'b', 'c']);
      await _settle();
    });

    test('undoing a visibility toggle keeps a teammate toggle', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      var lineups = await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);
      final landing = container.read(lineUpProvider).landings.single;
      container.read(lineUpProvider.notifier).updateLandingAbilityVisualState(
            landingId: link.landingId,
            visualState:
                landing.ability.visualState.copyWith(showRangeOutline: false),
          );
      lineups = await land(
        container,
        remote,
        page,
        previous: lineups,
        revision: 2,
        contentRevision: 3,
        teammate: (data) => ((firstItem(data)['ability'] as Map)['visualState']
            as Map)['showRangeFill'] = false,
      );

      container.read(actionProvider.notifier).undoAction();

      final visual = container
          .read(lineUpProvider)
          .landingById(link.landingId)!
          .ability
          .visualState;
      expect(visual.showRangeOutline, isTrue);
      expect(visual.showRangeFill, isFalse);
      await _settle();
    });

    test('an ack refresh that already holds a teammate change shows it',
        () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      var lineups = await land(container, remote, page,
          previous: const [], revision: 1, contentRevision: 2);
      const moved = Offset(500, 500);
      container
          .read(lineUpProvider.notifier)
          .updateOriginAgentPosition(link.originId, moved);
      // Our move lands and, in the same server state, a teammate arms it.
      lineups = await land(
        container,
        remote,
        page,
        previous: lineups,
        revision: 2,
        contentRevision: 3,
        teammate: (data) =>
            (data['agent'] as Map<String, dynamic>)['weapon'] = 'vandal',
      );

      final origin = container.read(lineUpProvider).originById(link.originId)!;
      expect(origin.agent.position, moved);
      expect(origin.agent.weapon, WeaponType.vandal);
      final ops = desiredOps(container, page);
      expect(ops[EntitySyncKey.lineup(page.publicId, link.originId)], isNull);
      await _settle();
    });

    test('an ack while another page is active does not revive the old lineup',
        () async {
      final first = _page('page-1', 0);
      final second = _page('page-2', 1);
      final secondSnapshot = _pageSnapshot(second, settings: settingsFor(9));
      final remote = _FakeRemoteEditorNotifier(
        _editorSnapshot(
          pages: [first, second],
          activePage: _pageSnapshot(first, settings: settingsFor(1)),
        ),
        pageCatalog: {
          first.publicId: _pageSnapshot(first, settings: settingsFor(1)),
          second.publicId: secondSnapshot,
        },
      );
      queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      final session = container.read(strategyPageSessionProvider.notifier);
      await session.initializeForStrategy(
        strategyId: 'cloud-strategy',
        source: StrategySource.cloud,
        selectFirstPageIfNeeded: true,
      );
      final link = place(container);
      await _settle();
      var ops = queuedOps();
      var lineups = apply(ops.values, first, revision: 1, previous: const []);
      remote.initialSnapshot =
          serverSnapshot(first, lineups, 2, pages: [first, second]);
      remote.pageCatalog[first.publicId] = remote.initialSnapshot.activePage!;
      publishAcks(ops, 1);
      await settleSync(container, 2);

      const moved = Offset(500, 500);
      container
          .read(lineUpProvider.notifier)
          .updateOriginAgentPosition(link.originId, moved);
      await session.setActivePage(second.publicId);
      await _settle();
      expect(container.read(strategySettingsProvider).agentSize, 39);

      // Page 1's move lands with a teammate's weapon change while page 2 is
      // on screen.
      ops = queuedOps();
      expect(ops.keys.where((key) => key.pageId == first.publicId), isNotEmpty);
      lineups = apply(
        ops.values,
        first,
        revision: 2,
        previous: lineups,
        teammate: (data) =>
            (data['agent'] as Map<String, dynamic>)['weapon'] = 'vandal',
      );
      remote.pageCatalog[first.publicId] = _pageSnapshot(
        first,
        settings: settingsFor(3),
        contentRevision: 3,
        lineups: lineups,
      );
      remote.initialSnapshot = _editorSnapshot(
        pages: [first, second],
        activePage: secondSnapshot,
      );
      publishAcks(ops, 2);
      await settleSync(container, 9);

      await session.setActivePage(first.publicId);
      await settleSync(container, 3);

      final origin = container.read(lineUpProvider).originById(link.originId)!;
      expect(origin.agent.position, moved);
      expect(origin.agent.weapon, WeaponType.vandal);
      expect(
        desiredOps(container, first)[
            EntitySyncKey.lineup(first.publicId, link.originId)],
        isNull,
      );
      await _settle();
    });
  });

  group('lineup history across rehydration', () {
    Future<(ProviderContainer, _FakeRemoteEditorNotifier, RemotePage)>
        openWithLineup() async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(
          page,
          lineups: [_lineup(page.publicId, 'lineup-a')],
        ),
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
      expect(container.read(lineUpProvider).origins.single.id, 'lineup-a');
      return (container, remote, page);
    }

    /// The server accepted the local edit and the page rehydrates from the
    /// new snapshot, keeping history (a cloud ack).
    Future<void> ackAndRehydrate(
      ProviderContainer container,
      _FakeRemoteEditorNotifier remote,
      RemotePage page,
      List<RemoteLineup> lineups,
    ) async {
      container.read(strategySaveStateProvider.notifier).markPersisted();
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, contentRevision: 2, lineups: lineups),
      ));
      await _settle();
    }

    test('undoing a lineup delete still restores it after an ack', () async {
      final (container, remote, page) = await openWithLineup();

      container.read(lineUpProvider.notifier).deleteOrigin('lineup-a');
      expect(container.read(lineUpProvider).origins, isEmpty);
      await ackAndRehydrate(container, remote, page, const []);
      expect(container.read(lineUpProvider).origins, isEmpty);

      container.read(actionProvider.notifier).undoAction();

      final lineUps = container.read(lineUpProvider);
      expect(lineUps.origins.single.id, 'lineup-a');
      expect(lineUps.links.single.id, 'item-lineup-a');
      expect(lineUps.landings, hasLength(1));

      container.read(actionProvider.notifier).redoAction();
      expect(container.read(lineUpProvider).links, isEmpty);
      await _settle();
    });

    test('undoing a marker move keeps a teammate lineup that arrived since',
        () async {
      final (container, remote, page) = await openWithLineup();
      const moved = Offset(200, 220);

      container
          .read(lineUpProvider.notifier)
          .updateOriginAgentPosition('lineup-a', moved);
      // The move lands and a teammate's lineup B arrives with it.
      await ackAndRehydrate(container, remote, page, [
        _lineup(page.publicId, 'lineup-a', agentPosition: moved, revision: 2),
        _lineup(page.publicId, 'lineup-b', sortIndex: 1),
      ]);
      expect(
        container.read(lineUpProvider).origins.map((origin) => origin.id),
        ['lineup-a', 'lineup-b'],
      );

      container.read(actionProvider.notifier).undoAction();

      final lineUps = container.read(lineUpProvider);
      expect(
        lineUps.origins.map((origin) => origin.id),
        ['lineup-a', 'lineup-b'],
      );
      expect(
        lineUps.originById('lineup-a')!.agent.position,
        const Offset(10, 20),
      );
      final desired =
          container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
                strategyPublicId: 'cloud-strategy',
                pageId: page.publicId,
              );
      expect(desired, isNotNull);
      expect(desired!.values.whereType<LineupDeleteOp>(), isEmpty);
      expect(
        desired[EntitySyncKey.lineup(page.publicId, 'lineup-a')],
        isA<LineupPatchOp>(),
      );
      expect(desired[EntitySyncKey.lineup(page.publicId, 'lineup-b')], isNull);
      await _settle();
    });
  });

  test('a lineup uploaded with stale nested ids hydrates without an edit',
      () async {
    final page = _page('page-1', 0);
    // Migrated before nested references followed a reassigned group id.
    final lineup = _lineup(
      page.publicId,
      'lineup-2',
      nestedLineUpId: 'lineup-1',
    );
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
    container.read(textProvider).single.position = const Offset(50, 60);

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    expect(desired, isNotNull);
    expect(desired![EntitySyncKey.lineup(page.publicId, 'lineup-2')], isNull);
    expect(
      desired[EntitySyncKey.element(page.publicId, 'text-page-1')]?.kind,
      StrategyOpKind.patch,
    );
    await _settle();
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

  test(
      'collaborator edits stay based on the page this client actually hydrated',
      () async {
    final page = _page('page-1', 0);
    const localTextId = 'local-text';
    const collaboratorTextId = 'collaborator-text';
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(
            page.publicId,
            localTextId,
            'shared-before',
            worldSized: true,
          ),
          _textElement(
            page.publicId,
            collaboratorTextId,
            'collaborator-before',
            sortIndex: 1,
            worldSized: true,
          ),
        ],
      ),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );

    container.read(textProvider.notifier).commitText(
          localTextId,
          'this-client-edit',
        );
    await _settle();

    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(
            page.publicId,
            localTextId,
            'collaborator-winner',
            revision: 2,
            worldSized: true,
          ),
          _textElement(
            page.publicId,
            collaboratorTextId,
            'collaborator-after',
            revision: 2,
            sortIndex: 1,
            worldSized: true,
          ),
        ],
      ),
    ));
    await _settle();

    expect(
      container
          .read(textProvider)
          .firstWhere((text) => text.id == collaboratorTextId)
          .text,
      'collaborator-before',
    );

    await session.flushCurrentPage();

    final elementOps = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .where((entry) => entry.key.kind == EntitySyncKeyKind.element)
        .toList(growable: false);
    expect(elementOps, hasLength(1));
    expect(elementOps.single.key.entityId, localTextId);
    expect(elementOps.single.value.pending.op.expectedRevision, 1);
    expect(
      elementOps.single.value.pending.op.payload.toString(),
      contains('this-client-edit'),
    );
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

  group('undo on a shared page keeps teammates\' work', () {
    /// Page settings that round-trip exactly, so live sync authors nothing
    /// for them unless undo changes them.
    CloudPayload settingsWith({
      double agentSize = 30,
      double abilitySize = 20,
    }) =>
        StrategySettings(agentSize: agentSize, abilitySize: abilitySize)
            .toJson();

    Map<String, dynamic> payloadOf(Object value) {
      return switch (value) {
        PlacedAgentNode() => {...value.toJson(), 'elementType': 'agent'},
        PlacedAbility() => {...value.toJson(), 'elementType': 'ability'},
        DrawingElement() => {
            ...(jsonDecode(DrawingProvider.objectToJson([value])) as List)
                .single as Map<String, dynamic>,
            'elementType': 'drawing',
          },
        PlacedText() => {...value.toJson(), 'elementType': 'text'},
        PlacedImage() => {
            ...cloudImagePayloadFromPlacedImage(value),
            'elementType': 'image',
          },
        PlacedUtility() => {...value.toJson(), 'elementType': 'utility'},
        _ => throw ArgumentError(value.runtimeType),
      };
    }

    String idOf(Object value) => switch (value) {
          PlacedWidget() => value.id,
          DrawingElement() => value.id,
          _ => throw ArgumentError(value.runtimeType),
        };

    RemoteElement element(
      RemotePage page,
      Object value, {
      int revision = 1,
      int sortIndex = 0,
    }) {
      final payload = payloadOf(value);
      final kind = payload['elementType'] as String;
      return RemoteElement(
        publicId: idOf(value),
        strategyPublicId: 'cloud-strategy',
        pagePublicId: page.publicId,
        elementType: kind,
        payload: cloudElementPayload(kind: kind, data: payload),
        sortIndex: sortIndex,
        revision: revision,
        deleted: false,
      );
    }

    /// Everything on the local canvas outside lineups.
    List<Object> canvasOf(ProviderContainer container) => [
          ...container.read(agentProvider),
          ...container.read(abilityProvider),
          ...container.read(drawingProvider).elements,
          ...container.read(textProvider),
          ...container.read(placedImageProvider).images,
          ...container.read(utilityProvider),
        ];

    Future<(ProviderContainer, _FakeRemoteEditorNotifier, RemotePage)> open(
      List<Object> objects, {
      List<RemoteLineup> lineups = const [],
    }) async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(
          page,
          settings: settingsWith(),
          elements: [
            for (var i = 0; i < objects.length; i++)
              element(page, objects[i], sortIndex: i),
          ],
          lineups: lineups,
        ),
      ));
      final container = await _cloudContainer(
        remote: remote,
        queue: _FakeStrategyOpQueueNotifier(),
      );
      // Let queued sync work finish before the container is disposed.
      addTearDown(_settle);
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      return (container, remote, page);
    }

    /// This client's edits land and the page rehydrates with the server's
    /// copy: the local canvas as sent, with [teammate] applied on top (a
    /// teammate's change arriving in the same round).
    Future<void> land(
      ProviderContainer container,
      _FakeRemoteEditorNotifier remote,
      RemotePage page, {
      List<Object> Function(List<Object> canvas)? teammate,
      CloudPayload? settings,
      List<RemoteLineup> lineups = const [],
    }) async {
      final canvas = canvasOf(container);
      final stored = teammate == null ? canvas : teammate(canvas);
      container.read(strategySaveStateProvider.notifier).markPersisted();
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(
          page,
          contentRevision: 2,
          settings:
              settings ?? container.read(strategySettingsProvider).toJson(),
          elements: [
            for (var i = 0; i < stored.length; i++)
              element(page, stored[i], revision: 2, sortIndex: i),
          ],
          lineups: lineups,
        ),
      ));
      await _settle();
    }

    Map<EntitySyncKey, StrategyOp> desiredOps(
      ProviderContainer container,
      RemotePage page,
    ) {
      return container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
                strategyPublicId: 'cloud-strategy',
                pageId: page.publicId,
              ) ??
          const {};
    }

    /// [id] is on the canvas and live sync authors no deletion for it.
    void expectKept(ProviderContainer container, RemotePage page, String id) {
      expect(canvasOf(container).map(idOf), contains(id));
      expect(
        desiredOps(container, page)[EntitySyncKey.element(page.publicId, id)],
        isNot(isA<ElementDeleteOp>()),
      );
    }

    PlacedAgent jett(String id) => PlacedAgent(
          id: id,
          type: AgentType.jett,
          position: const Offset(10, 20),
        );

    PlacedUtility cone(String id) => PlacedUtility(
          id: id,
          type: UtilityType.viewCone90,
          position: const Offset(40, 40),
        );

    ActionProvider history(ProviderContainer container) =>
        container.read(actionProvider.notifier);

    test('undoing an agent move keeps an agent a teammate added', () async {
      final (container, remote, page) = await open([jett('jett')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(200, 200), 'jett');
      await land(container, remote, page,
          teammate: (canvas) => [...canvas, jett('sova')]);

      history(container).undoAction();

      expect(
        container
            .read(agentProvider)
            .firstWhere((a) => a.id == 'jett')
            .position,
        const Offset(10, 20),
      );
      expectKept(container, page, 'sova');
    });

    test('undoing an agent move keeps a teammate marking it dead', () async {
      final (container, remote, page) = await open([jett('jett')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(200, 200), 'jett');
      await land(container, remote, page,
          teammate: (canvas) => [
                for (final object in canvas)
                  if (object is PlacedAgent)
                    (object.copyWith()..state = AgentState.dead)
                  else
                    object,
              ]);

      history(container).undoAction();

      final agent = container.read(agentProvider).single;
      expect(agent.position, const Offset(10, 20));
      expect(agent.state, AgentState.dead);

      history(container).redoAction();
      final redone = container.read(agentProvider).single;
      expect(redone.position, const Offset(200, 200));
      expect(redone.state, AgentState.dead);
    });

    // A move, undone and redone, against a teammate's change to another
    // field of the same object: [field] set to [value] in its payload.
    final moveCases = <(String, Object, String, Object)>[
      (
        'ability',
        PlacedAbility(
          id: 'mine',
          data: AgentData.agents[AgentType.jett]!.abilities.first,
          position: const Offset(10, 20),
        ),
        'isAlly',
        false,
      ),
      (
        'text',
        PlacedText(id: 'mine', position: const Offset(10, 20))..text = 'mine',
        'text',
        'theirs',
      ),
      (
        'image',
        PlacedImage(
          id: 'mine',
          position: const Offset(10, 20),
          aspectRatio: 1,
          scale: ImageScalePolicy.defaultWidth,
          fileExtension: '.png',
        ),
        'scale',
        ImageScalePolicy.defaultWidth + 40,
      ),
      (
        'utility',
        PlacedUtility(
          id: 'mine',
          type: UtilityType.viewCone90,
          position: const Offset(10, 20),
        ),
        'isAlly',
        false,
      ),
    ];
    for (final (kind, object, field, value) in moveCases) {
      test('undoing a $kind move keeps a teammate change to its $field',
          () async {
        final (container, remote, page) = await open([object]);
        void move(Offset to) => switch (kind) {
              'ability' => container
                  .read(abilityProvider.notifier)
                  .updatePosition(to, 'mine'),
              'text' => container
                  .read(textProvider.notifier)
                  .updatePosition(to, 'mine'),
              'image' => container
                  .read(placedImageProvider.notifier)
                  .updatePosition(to, 'mine'),
              _ => container
                  .read(utilityProvider.notifier)
                  .updatePosition(to, 'mine'),
            };
        Map<String, dynamic> mine() => payloadOf(
            canvasOf(container).singleWhere((o) => idOf(o) == 'mine'));
        Object withField(Object source) {
          final json = {...payloadOf(source), field: value};
          return switch (kind) {
            'ability' => PlacedAbility.fromJson(json),
            'text' => PlacedText.fromJson(json),
            'image' => PlacedImage.fromJson(json),
            _ => PlacedUtility.fromJson(json),
          };
        }

        move(const Offset(200, 200));
        await land(container, remote, page,
            teammate: (canvas) => [for (final o in canvas) withField(o)]);
        expect(mine()[field], value);

        history(container).undoAction();
        expect(mine()['position'], {'dx': 10.0, 'dy': 20.0});
        expect(mine()[field], value);

        history(container).redoAction();
        expect(mine()['position'], {'dx': 200.0, 'dy': 200.0});
        expect(mine()[field], value);
      });
    }

    test('undoing a view cone conversion keeps an agent a teammate added',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      history(container).performTransaction(
        groups: const [ActionGroup.agent],
        mutation: () =>
            container.read(agentProvider.notifier).convertPlainAgentToViewCone(
                  id: 'jett',
                  presetType: UtilityType.viewCone90,
                  rotation: 0,
                  length: 50,
                ),
      );
      await land(container, remote, page,
          teammate: (canvas) => [...canvas, jett('sova')]);

      history(container).undoAction();

      expect(
        container.read(agentProvider).firstWhere((a) => a.id == 'jett'),
        isNot(isA<PlacedViewConeAgent>()),
      );
      expectKept(container, page, 'sova');

      history(container).redoAction();
      expect(
        container.read(agentProvider).firstWhere((a) => a.id == 'jett'),
        isA<PlacedViewConeAgent>(),
      );
      expectKept(container, page, 'sova');
    });

    test('undoing a cone dropped on an agent keeps a teammate utility',
        () async {
      final (container, remote, page) =
          await open([jett('jett'), cone('cone')]);

      history(container).performTransaction(
        groups: const [ActionGroup.agent, ActionGroup.utility],
        mutation: () {
          container
              .read(utilityProvider.notifier)
              .removeUtilityAsAction('cone');
          container.read(agentProvider.notifier).convertPlainAgentToViewCone(
                id: 'jett',
                presetType: UtilityType.viewCone90,
                rotation: 0,
                length: 50,
              );
        },
      );
      await land(container, remote, page,
          teammate: (canvas) => [...canvas, cone('teammate-cone')]);

      history(container).undoAction();

      expect(
        container.read(utilityProvider).map((u) => u.id),
        containsAll(['cone', 'teammate-cone']),
      );
      expect(
        container.read(agentProvider).single,
        isNot(isA<PlacedViewConeAgent>()),
      );
      expectKept(container, page, 'teammate-cone');

      history(container).redoAction();
      expect(
        container.read(utilityProvider).map((u) => u.id),
        ['teammate-cone'],
      );
      expectKept(container, page, 'teammate-cone');
    });

    test('undoing a size change keeps a teammate size change', () async {
      final (container, remote, page) = await open([jett('jett')]);

      final settings = container.read(strategySettingsProvider.notifier);
      history(container).performTransaction(
        groups: const [ActionGroup.strategySettings],
        mutation: () => settings.updateAgentSize(40),
      );
      await land(container, remote, page,
          settings: settingsWith(agentSize: 40, abilitySize: 28));
      expect(container.read(strategySettingsProvider).abilitySize, 28);

      history(container).undoAction();

      expect(container.read(strategySettingsProvider).agentSize, 30);
      expect(container.read(strategySettingsProvider).abilitySize, 28);

      history(container).redoAction();
      expect(container.read(strategySettingsProvider).agentSize, 40);
      expect(container.read(strategySettingsProvider).abilitySize, 28);
    });

    test('undoing a utility elevation change still works after it lands',
        () async {
      final (container, remote, page) = await open([cone('cone')]);

      container
          .read(utilityProvider.notifier)
          .updateViewConeElevation('cone', 150);
      await land(container, remote, page);

      history(container).undoAction();
      expect(container.read(utilityProvider).single.visionElevation, isNull);

      history(container).redoAction();
      expect(container.read(utilityProvider).single.visionElevation, 150);
    });

    test('an edit before a deletion stays undoable after the deletion lands',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(200, 200), 'jett');
      container.read(agentProvider.notifier).removeAgentAsAction('jett');
      await land(container, remote, page);
      expect(container.read(agentProvider), isEmpty);

      history(container).undoAction();
      expect(
        container.read(agentProvider).single.position,
        const Offset(200, 200),
      );

      history(container).undoAction();
      expect(
        container.read(agentProvider).single.position,
        const Offset(10, 20),
      );
    });

    test('undo and redo skip an edit whose object a teammate deleted',
        () async {
      final (container, remote, page) =
          await open([jett('jett'), jett('sova')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(200, 200), 'jett');
      await land(container, remote, page,
          teammate: (canvas) => [
                for (final object in canvas)
                  if (idOf(object) != 'jett') object,
              ]);

      history(container).undoAction();
      history(container).redoAction();

      expect(container.read(agentProvider).map((a) => a.id), ['sova']);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.element(page.publicId, 'jett')],
        isNull,
      );
    });

    // Bulk clear, per group: a teammate's object of the cleared kind arrives
    // after the clear lands.
    final clearCases = <(ActionGroup, Object Function(String id))>[
      (ActionGroup.agent, jett),
      (
        ActionGroup.ability,
        (id) => PlacedAbility(
              id: id,
              data: AgentData.agents[AgentType.jett]!.abilities.first,
              position: const Offset(60, 60),
            ),
      ),
      (
        ActionGroup.drawing,
        (id) => FreeDrawing(
              id: id,
              color: Colors.red,
              isDotted: false,
              hasArrow: false,
              listOfPoints: const [Offset.zero, Offset(10, 10)],
            ),
      ),
      (
        ActionGroup.text,
        (id) => PlacedText(id: id, position: const Offset(70, 70))..text = id,
      ),
      (
        ActionGroup.image,
        (id) => PlacedImage(
              id: id,
              position: const Offset(80, 80),
              aspectRatio: 1,
              scale: ImageScalePolicy.defaultWidth,
              fileExtension: '.png',
            ),
      ),
      (ActionGroup.utility, cone),
    ];
    for (final (group, build) in clearCases) {
      test('undoing a ${group.name} clear keeps one a teammate added',
          () async {
        final (container, remote, page) = await open([
          build('mine'),
          if (group != ActionGroup.agent) jett('jett'),
        ]);

        history(container).clearGroupAsAction(group);
        expect(canvasOf(container).map(idOf), isNot(contains('mine')));
        await land(container, remote, page,
            teammate: (canvas) => [...canvas, build('theirs')]);

        history(container).undoAction();
        expect(
          canvasOf(container).map(idOf),
          containsAll(['mine', 'theirs']),
        );
        expectKept(container, page, 'theirs');

        history(container).redoAction();
        expect(canvasOf(container).map(idOf), isNot(contains('mine')));
        expectKept(container, page, 'theirs');
      });
    }

    /// [canvas] with the object [id] replaced by [edit] of it.
    List<Object> editing(
      List<Object> canvas,
      String id,
      Object Function(Object object) edit,
    ) =>
        [for (final o in canvas) idOf(o) == id ? edit(o) : o];

    /// [canvas] without the object [id].
    List<Object> without(List<Object> canvas, String id) => [
          for (final o in canvas)
            if (idOf(o) != id) o
        ];

    Object dead(Object agent) =>
        (agent as PlacedAgent).copyWith()..state = AgentState.dead;

    PlacedAgent agentOn(ProviderContainer container, String id) =>
        container.read(agentProvider).singleWhere((a) => a.id == id)
            as PlacedAgent;

    test('undoing an ability visibility toggle keeps teammate toggles',
        () async {
      final ability = PlacedAbility(
        id: 'mine',
        data: AgentData.agents[AgentType.jett]!.abilities.first,
        position: const Offset(10, 20),
      );
      final (container, remote, page) = await open([ability]);
      AbilityVisualState visual() =>
          container.read(abilityProvider).single.visualState;
      Object toggled(Object object, String toggle) => PlacedAbility.fromJson({
            ...payloadOf(object),
            'visualState': {
              ...(object as PlacedAbility).visualState.toJson(),
              toggle: false,
            },
          });

      container.read(abilityProvider.notifier).updateVisualState(
            0,
            visual().copyWith(showRangeOutline: false),
          );
      await land(container, remote, page,
          teammate: (canvas) =>
              editing(canvas, 'mine', (o) => toggled(o, 'showRangeFill')));

      history(container).undoAction();
      expect(visual().showRangeOutline, isTrue);
      expect(visual().showRangeFill, isFalse);

      // Another teammate toggle lands between undo and redo.
      await land(container, remote, page,
          teammate: (canvas) =>
              editing(canvas, 'mine', (o) => toggled(o, 'showInnerFill')));
      history(container).redoAction();
      expect(visual().showRangeOutline, isFalse);
      expect(visual().showRangeFill, isFalse);
      expect(visual().showInnerFill, isFalse);

      history(container).undoAction();
      expect(visual().showRangeOutline, isTrue);
      expect(visual().showRangeFill, isFalse);
      expect(visual().showInnerFill, isFalse);
    });

    test('undoing a deletion leaves a teammate copy that is still there',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container.read(agentProvider.notifier).removeAgentAsAction('jett');
      // The teammate's edited copy wins on the server.
      final teammateCopy = dead(jett('jett'));
      await land(container, remote, page,
          teammate: (canvas) => [...canvas, teammateCopy]);
      expect(agentOn(container, 'jett').state, AgentState.dead);

      history(container).undoAction();
      expect(agentOn(container, 'jett').state, AgentState.dead);

      // The undo restored nothing, so there is nothing for redo to remove.
      history(container).redoAction();
      expect(agentOn(container, 'jett').state, AgentState.dead);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.element(page.publicId, 'jett')],
        isNot(isA<ElementDeleteOp>()),
      );
    });

    test('redoing an addition brings back the copy the undo took away',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container.read(agentProvider.notifier).addAgent(jett('sova'));
      await land(container, remote, page,
          teammate: (canvas) => editing(canvas, 'sova', dead));

      history(container).undoAction();
      expect(container.read(agentProvider).map((a) => a.id), ['jett']);
      await land(container, remote, page);

      history(container).redoAction();
      expect(agentOn(container, 'sova').state, AgentState.dead);

      history(container).undoAction();
      history(container).redoAction();
      expect(agentOn(container, 'sova').state, AgentState.dead);
    });

    test('a clear undone and redone around a teammate edit keeps the edit',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      history(container).clearGroupAsAction(ActionGroup.agent);
      history(container).undoAction();
      await land(container, remote, page,
          teammate: (canvas) => editing(canvas, 'jett', dead));

      history(container).redoAction();
      expect(container.read(agentProvider), isEmpty);
      await land(container, remote, page);

      history(container).undoAction();
      expect(agentOn(container, 'jett').state, AgentState.dead);
    });

    test('undoing an addition a teammate deleted gives redo nothing to add',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container.read(agentProvider.notifier).addAgent(jett('sova'));
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'sova'));

      history(container).undoAction();
      history(container).redoAction();

      expect(container.read(agentProvider).map((a) => a.id), ['jett']);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.element(page.publicId, 'sova')],
        isNull,
      );
    });

    test(
        'redoing a clear after a teammate deleted a restored object '
        'does not bring it back on the next undo', () async {
      final (container, remote, page) =
          await open([jett('jett'), jett('sova')]);

      history(container).clearGroupAsAction(ActionGroup.agent);
      history(container).undoAction();
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'sova'));

      history(container).redoAction();
      expect(container.read(agentProvider), isEmpty);
      await land(container, remote, page);

      history(container).undoAction();
      expect(container.read(agentProvider).map((a) => a.id), ['jett']);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.element(page.publicId, 'sova')],
        isNull,
      );
    });

    test('a transaction whose object a teammate deleted leaves history',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      history(container).performTransaction(
        groups: const [ActionGroup.agent],
        mutation: () =>
            container.read(agentProvider.notifier).convertPlainAgentToViewCone(
                  id: 'jett',
                  presetType: UtilityType.viewCone90,
                  rotation: 0,
                  length: 50,
                ),
      );
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'jett'));

      expect(container.read(actionProvider), isEmpty);
    });

    test('undoing a clear leaves out history hydration dropped since',
        () async {
      final (container, remote, page) = await open([
        jett('jett'),
        PlacedText(id: 'note', position: const Offset(70, 70))..text = 'note',
      ]);

      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(300, 300), 'note');
      history(container).clearGroupAsAction(ActionGroup.agent);
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'note'));

      history(container).undoAction();
      expect(container.read(agentProvider).map((a) => a.id), ['jett']);
      expect(container.read(actionProvider), isEmpty);
      expect(container.read(textProvider), isEmpty);
    });

    /// [lineup] as a teammate left it with [notes] on its link.
    RemoteLineup withNotes(RemoteLineup lineup, String notes) {
      final payload = jsonDecode(jsonEncode(lineup.payload)) as CloudPayload;
      ((payload['data'] as Map)['items'] as List).first['notes'] = notes;
      return RemoteLineup(
        publicId: lineup.publicId,
        strategyPublicId: lineup.strategyPublicId,
        pagePublicId: lineup.pagePublicId,
        payload: payload,
        sortIndex: lineup.sortIndex,
        revision: lineup.revision + 1,
        deleted: false,
      );
    }

    test(
        'redoing a lineup clear a teammate already undid by deleting '
        'does not resurrect it on the next undo', () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      history(container).clearGroupAsAction(ActionGroup.lineUp);
      history(container).undoAction();
      expect(container.read(lineUpProvider).origins, hasLength(1));
      await land(container, remote, page); // the teammate deleted it

      history(container).redoAction();
      history(container).undoAction();

      expect(container.read(lineUpProvider).links, isEmpty);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.lineup(page.publicId, 'mine')],
        isNull,
      );
    });

    test('a lineup clear redone and undone keeps a teammate notes edit',
        () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      history(container).clearGroupAsAction(ActionGroup.lineUp);
      history(container).undoAction();
      await land(container, remote, page,
          lineups: [withNotes(mine, 'teammate notes')]);
      expect(
          container.read(lineUpProvider).links.single.notes, 'teammate notes');

      history(container).redoAction();
      expect(container.read(lineUpProvider).links, isEmpty);
      await land(container, remote, page);

      history(container).undoAction();
      expect(
          container.read(lineUpProvider).links.single.notes, 'teammate notes');
    });

    test(
        'undoing a lineup clear leaves a lineup a teammate restored, '
        'and redo does not remove it', () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      history(container).clearGroupAsAction(ActionGroup.lineUp);
      await land(container, remote, page,
          lineups: [withNotes(mine, 'restored')]);
      expect(container.read(lineUpProvider).links.single.notes, 'restored');

      history(container).undoAction();
      history(container).redoAction();

      expect(container.read(lineUpProvider).links.single.notes, 'restored');
      expect(
        desiredOps(container, page).values.whereType<LineupDeleteOp>(),
        isEmpty,
      );
    });

    test(
        'redoing a lineup deletion a teammate already made removes nothing '
        'and the next undo does not resurrect it', () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      container.read(lineUpProvider.notifier).deleteOrigin('mine');
      history(container).undoAction();
      expect(container.read(lineUpProvider).links, hasLength(1));
      await land(container, remote, page); // the teammate deleted it

      history(container).redoAction();
      expect(container.read(lineUpProvider).links, isEmpty);
      history(container).undoAction();

      expect(container.read(lineUpProvider).links, isEmpty);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.lineup(page.publicId, 'mine')],
        isNull,
      );
    });

    test('undoing a weapon change on an agent a teammate deleted does nothing',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container
          .read(agentProvider.notifier)
          .setWeapon('jett', WeaponType.classic);
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'jett'));

      history(container).undoAction();

      expect(container.read(agentProvider), isEmpty);
      expect(history(container).poppedItems, isEmpty);
    });

    test('undoing a lineup weapon change a teammate deleted does nothing',
        () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      container
          .read(lineUpProvider.notifier)
          .setOriginWeapon('mine', WeaponType.classic);
      await land(container, remote, page);

      history(container).undoAction();

      expect(container.read(lineUpProvider).origins, isEmpty);
      expect(history(container).poppedItems, isEmpty);
    });

    test(
        'undoing a lineup notes edit whose link a teammate deleted does '
        'nothing', () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);
      final lineUps = container.read(lineUpProvider.notifier);

      lineUps.updateLink(
        container.read(lineUpProvider).links.single.copyWith(notes: 'mine'),
      );
      lineUps.deleteOrigin('mine');
      history(container).undoAction(); // the deletion
      await land(container, remote, page); // the teammate deleted it

      // The edit stays in history (a retained deletion can bring its link
      // back), but with the link gone undoing it changes nothing.
      history(container).undoAction();

      expect(container.read(lineUpProvider).links, isEmpty);
      expect(history(container).poppedItems, hasLength(1));
    });

    test('undoing a lineup clear keeps a lineup a teammate added', () async {
      final (container, remote, page) =
          await open(const [], lineups: [_lineup('page-1', 'mine')]);

      history(container).clearGroupAsAction(ActionGroup.lineUp);
      expect(container.read(lineUpProvider).origins, isEmpty);
      await land(container, remote, page,
          lineups: [_lineup(page.publicId, 'theirs')]);

      history(container).undoAction();
      expect(
        container.read(lineUpProvider).origins.map((o) => o.id),
        containsAll(['mine', 'theirs']),
      );
      expect(
        desiredOps(container, page).values.whereType<LineupDeleteOp>(),
        isEmpty,
      );

      history(container).redoAction();
      expect(
        container.read(lineUpProvider).origins.map((o) => o.id),
        ['theirs'],
      );
    });
  });
}
