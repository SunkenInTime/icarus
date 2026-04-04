import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/transition_provider.dart'
    as overlay_transition;
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class _StaticStrategyProvider extends StrategyProvider {
  _StaticStrategyProvider(this.initialState);

  final StrategyState initialState;

  @override
  StrategyState build() => initialState;
}

class _FakeRemoteStrategySnapshotNotifier
    extends RemoteStrategySnapshotNotifier {
  _FakeRemoteStrategySnapshotNotifier(this.initialSnapshot);

  RemoteStrategySnapshot? initialSnapshot;
  int refreshCount = 0;

  @override
  Future<RemoteStrategySnapshot?> build() async => initialSnapshot;

  void setSnapshot(RemoteStrategySnapshot snapshot) {
    initialSnapshot = snapshot;
    state = AsyncData(snapshot);
  }

  @override
  Future<void> refresh() async {
    refreshCount++;
    state = AsyncData(initialSnapshot);
  }
}

class _FakeStrategyOpQueueNotifier extends StrategyOpQueueNotifier {
  _FakeStrategyOpQueueNotifier(this.strategyPublicId);

  final String? strategyPublicId;
  int enqueueAllCount = 0;
  int flushNowCount = 0;
  final List<StrategyOp> enqueuedOps = [];

  @override
  StrategyOpQueueState build() {
    return StrategyOpQueueState(
      strategyPublicId: strategyPublicId,
      clientId: 'test-client',
    );
  }

  @override
  void setActiveStrategy(String? strategyPublicId) {
    state = state.copyWith(
      strategyPublicId: strategyPublicId,
      pending: const [],
      lastAcks: const [],
      clearError: true,
    );
  }

  @override
  void enqueueAll(Iterable<StrategyOp> ops, {bool flushImmediately = false}) {
    final collected = ops.toList(growable: false);
    enqueueAllCount++;
    enqueuedOps.addAll(collected);
    state = state.copyWith(
      pending: [
        for (final op in collected)
          PendingOp(op: op, clientId: state.clientId ?? 'test-client'),
      ],
      clearError: true,
    );
    if (flushImmediately) {
      flushNow();
    }
  }

  @override
  Future<void> flushNow() async {
    flushNowCount++;
    state = state.copyWith(
      pending: const [],
      isFlushing: false,
      lastFlushAt: DateTime.now(),
    );
  }

  void emitAcks(List<OpAck> acks) {
    state = state.copyWith(lastAcks: acks);
  }
}

Future<Box<StrategyData>> _openStrategyBox(String prefix) async {
  const abilityInfoAdapterTypeId = 9;
  final tempDir = await Directory.systemTemp.createTemp(prefix);
  Hive.init(tempDir.path);
  if (!Hive.isAdapterRegistered(abilityInfoAdapterTypeId)) {
    registerIcarusAdapters(Hive);
  }

  final strategyBox =
      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  addTearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });
  return strategyBox;
}

RemoteStrategySnapshot _cloudSnapshot({
  required String strategyId,
  required int sequence,
  required List<RemotePage> pages,
  Map<String, List<RemoteElement>> elementsByPage = const {},
}) {
  final now = DateTime.utc(2026, 1, 1);
  return RemoteStrategySnapshot(
    header: RemoteStrategyHeader(
      publicId: strategyId,
      name: 'Cloud Strategy',
      mapData: Maps.mapNames[MapValue.ascent]!,
      sequence: sequence,
      createdAt: now,
      updatedAt: now,
    ),
    pages: pages,
    elementsByPage: elementsByPage,
    lineupsByPage: const {},
  );
}

RemotePage _remotePage({
  required String strategyId,
  required String pageId,
  required int sortIndex,
}) {
  return RemotePage(
    publicId: pageId,
    strategyPublicId: strategyId,
    name: 'Page $sortIndex',
    sortIndex: sortIndex,
    isAttack: true,
    revision: 1,
  );
}

RemoteElement _remoteText({
  required String strategyId,
  required String pageId,
  required String elementId,
  required String text,
}) {
  final placedText = PlacedText(
    id: elementId,
    position: const Offset(10, 20),
  )..text = text;
  return RemoteElement(
    publicId: elementId,
    strategyPublicId: strategyId,
    pagePublicId: pageId,
    elementType: 'text',
    payload: jsonEncode(placedText.toJson()),
    sortIndex: 0,
    revision: 1,
    deleted: false,
  );
}

StrategyData _localStrategy({
  required String strategyId,
  required String firstText,
  required String secondText,
}) {
  final pageOne = StrategyPage(
    id: 'page-1',
    name: 'Page 1',
    drawingData: const [],
    agentData: const [],
    abilityData: const [],
    textData: [
      PlacedText(id: 'text-1', position: const Offset(10, 20))
        ..text = firstText,
    ],
    imageData: const [],
    utilityData: const [],
    sortIndex: 0,
    isAttack: true,
    settings: StrategySettings(),
  );
  final pageTwo = StrategyPage(
    id: 'page-2',
    name: 'Page 2',
    drawingData: const [],
    agentData: const [],
    abilityData: const [],
    textData: [
      PlacedText(id: 'text-2', position: const Offset(30, 40))
        ..text = secondText,
    ],
    imageData: const [],
    utilityData: const [],
    sortIndex: 1,
    isAttack: true,
    settings: StrategySettings(),
  );

  return StrategyData(
    id: strategyId,
    name: 'Local Strategy',
    mapData: MapValue.ascent,
    versionNumber: 1,
    lastEdited: DateTime.utc(2026, 1, 1),
    folderID: null,
    pages: [pageOne, pageTwo],
  );
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<ProviderContainer> _cloudContainer({
  required StrategyState strategyState,
  required _FakeRemoteStrategySnapshotNotifier remoteNotifier,
  required _FakeStrategyOpQueueNotifier queueNotifier,
}) async {
  final container = ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(
        () => _StaticStrategyProvider(strategyState),
      ),
      remoteStrategySnapshotProvider.overrideWith(() => remoteNotifier),
      strategyOpQueueProvider.overrideWith(() => queueNotifier),
    ],
  );
  addTearDown(container.dispose);
  container.listen(strategyPageSessionProvider, (_, __) {});
  await container.read(remoteStrategySnapshotProvider.future);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  test('remote snapshot reapply does not flush current cloud page', () async {
    const strategyId = 'cloud-strategy';
    final pageOne =
        _remotePage(strategyId: strategyId, pageId: 'page-1', sortIndex: 0);
    final initialSnapshot = _cloudSnapshot(
      strategyId: strategyId,
      sequence: 1,
      pages: [pageOne],
      elementsByPage: {
        'page-1': [
          _remoteText(
              strategyId: strategyId,
              pageId: 'page-1',
              elementId: 'text-1',
              text: 'before')
        ],
      },
    );
    final updatedSnapshot = _cloudSnapshot(
      strategyId: strategyId,
      sequence: 2,
      pages: [pageOne],
      elementsByPage: {
        'page-1': [
          _remoteText(
              strategyId: strategyId,
              pageId: 'page-1',
              elementId: 'text-1',
              text: 'after')
        ],
      },
    );

    final remoteNotifier = _FakeRemoteStrategySnapshotNotifier(initialSnapshot);
    final queueNotifier = _FakeStrategyOpQueueNotifier(strategyId);
    final container = await _cloudContainer(
      strategyState: const StrategyState(
        strategyId: strategyId,
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      ),
      remoteNotifier: remoteNotifier,
      queueNotifier: queueNotifier,
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: strategyId,
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local-text', position: const Offset(50, 60))
        ..text = 'local-only',
    ]);

    remoteNotifier.setSnapshot(updatedSnapshot);
    await _settle();

    expect(queueNotifier.enqueueAllCount, 0);
    expect(queueNotifier.flushNowCount, 0);
    expect(container.read(textProvider).single.text, 'after');
  });

  test('reject refresh does not flush current cloud page', () async {
    const strategyId = 'cloud-strategy';
    final pageOne =
        _remotePage(strategyId: strategyId, pageId: 'page-1', sortIndex: 0);
    final initialSnapshot = _cloudSnapshot(
      strategyId: strategyId,
      sequence: 1,
      pages: [pageOne],
      elementsByPage: {
        'page-1': [
          _remoteText(
              strategyId: strategyId,
              pageId: 'page-1',
              elementId: 'text-1',
              text: 'before')
        ],
      },
    );
    final updatedSnapshot = _cloudSnapshot(
      strategyId: strategyId,
      sequence: 2,
      pages: [pageOne],
      elementsByPage: {
        'page-1': [
          _remoteText(
              strategyId: strategyId,
              pageId: 'page-1',
              elementId: 'text-1',
              text: 'after')
        ],
      },
    );

    final remoteNotifier = _FakeRemoteStrategySnapshotNotifier(initialSnapshot);
    final queueNotifier = _FakeStrategyOpQueueNotifier(strategyId);
    final container = await _cloudContainer(
      strategyState: const StrategyState(
        strategyId: strategyId,
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      ),
      remoteNotifier: remoteNotifier,
      queueNotifier: queueNotifier,
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: strategyId,
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local-text', position: const Offset(50, 60))
        ..text = 'local-only',
    ]);
    remoteNotifier.setSnapshot(updatedSnapshot);
    queueNotifier.emitAcks(const [
      OpAck(
          opId: 'op-1',
          status: 'reject',
          latestSequence: 2,
          reason: 'conflict'),
    ]);
    await _settle();

    expect(remoteNotifier.refreshCount, 1);
    expect(queueNotifier.enqueueAllCount, 0);
    expect(queueNotifier.flushNowCount, 0);
    expect(container.read(textProvider).single.text, 'after');
  });

  test('user page switch still flushes current cloud page', () async {
    const strategyId = 'cloud-strategy';
    final snapshot = _cloudSnapshot(
      strategyId: strategyId,
      sequence: 1,
      pages: [
        _remotePage(strategyId: strategyId, pageId: 'page-1', sortIndex: 0),
        _remotePage(strategyId: strategyId, pageId: 'page-2', sortIndex: 1),
      ],
      elementsByPage: {
        'page-2': [
          _remoteText(
              strategyId: strategyId,
              pageId: 'page-2',
              elementId: 'text-2',
              text: 'page-two'),
        ],
      },
    );

    final remoteNotifier = _FakeRemoteStrategySnapshotNotifier(snapshot);
    final queueNotifier = _FakeStrategyOpQueueNotifier(strategyId);
    final container = await _cloudContainer(
      strategyState: const StrategyState(
        strategyId: strategyId,
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      ),
      remoteNotifier: remoteNotifier,
      queueNotifier: queueNotifier,
    );

    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: strategyId,
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local-text', position: const Offset(50, 60))
        ..text = 'needs-sync',
    ]);

    await container
        .read(strategyPageSessionProvider.notifier)
        .setActivePage('page-2');

    expect(queueNotifier.enqueueAllCount, 1);
    expect(queueNotifier.enqueuedOps, isNotEmpty);
    expect(queueNotifier.flushNowCount, 1);
    expect(container.read(textProvider).single.text, 'page-two');
  });

  test('cloud animated page switch uses shared transition state', () async {
    const strategyId = 'cloud-strategy';
    final snapshot = _cloudSnapshot(
      strategyId: strategyId,
      sequence: 1,
      pages: [
        _remotePage(strategyId: strategyId, pageId: 'page-1', sortIndex: 0),
        _remotePage(strategyId: strategyId, pageId: 'page-2', sortIndex: 1),
      ],
      elementsByPage: {
        'page-1': [
          _remoteText(
            strategyId: strategyId,
            pageId: 'page-1',
            elementId: 'text-1',
            text: 'before',
          ),
        ],
        'page-2': [
          _remoteText(
            strategyId: strategyId,
            pageId: 'page-2',
            elementId: 'text-2',
            text: 'after',
          ),
        ],
      },
    );

    final remoteNotifier = _FakeRemoteStrategySnapshotNotifier(snapshot);
    final queueNotifier = _FakeStrategyOpQueueNotifier(strategyId);
    final container = await _cloudContainer(
      strategyState: const StrategyState(
        strategyId: strategyId,
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      ),
      remoteNotifier: remoteNotifier,
      queueNotifier: queueNotifier,
    );

    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: strategyId,
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local-text', position: const Offset(50, 60))
        ..text = 'needs-sync',
    ]);

    await container
        .read(strategyPageSessionProvider.notifier)
        .setActivePageAnimated(
          'page-2',
          direction: PageTransitionDirection.forward,
        );

    expect(
      container.read(strategyPageSessionProvider).transitionState,
      PageTransitionState.animatingForward,
    );
    final transitionState =
        container.read(overlay_transition.transitionProvider);
    expect(transitionState.hideView, isTrue);
    expect(
      transitionState.phase,
      overlay_transition.PageTransitionPhase.preparing,
    );
    expect(transitionState.direction, PageTransitionDirection.forward);
    expect(queueNotifier.flushNowCount, 1);
    expect(container.read(textProvider).single.text, 'after');
  });

  test('cloud relative page switch preserves backward transition direction',
      () async {
    const strategyId = 'cloud-strategy';
    final snapshot = _cloudSnapshot(
      strategyId: strategyId,
      sequence: 1,
      pages: [
        _remotePage(strategyId: strategyId, pageId: 'page-1', sortIndex: 0),
        _remotePage(strategyId: strategyId, pageId: 'page-2', sortIndex: 1),
      ],
      elementsByPage: {
        'page-1': [
          _remoteText(
            strategyId: strategyId,
            pageId: 'page-1',
            elementId: 'text-1',
            text: 'before',
          ),
        ],
        'page-2': [
          _remoteText(
            strategyId: strategyId,
            pageId: 'page-2',
            elementId: 'text-2',
            text: 'after',
          ),
        ],
      },
    );

    final remoteNotifier = _FakeRemoteStrategySnapshotNotifier(snapshot);
    final queueNotifier = _FakeStrategyOpQueueNotifier(strategyId);
    final container = await _cloudContainer(
      strategyState: const StrategyState(
        strategyId: strategyId,
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      ),
      remoteNotifier: remoteNotifier,
      queueNotifier: queueNotifier,
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: strategyId,
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    await container.read(strategyPageSessionProvider.notifier).setActivePage(
          'page-2',
        );

    queueNotifier
      ..enqueueAllCount = 0
      ..flushNowCount = 0
      ..enqueuedOps.clear();
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'page-two-draft', position: const Offset(40, 70))
        ..text = 'draft',
    ]);

    await container
        .read(strategyPageSessionProvider.notifier)
        .switchRelativePage(PageSwitchDirection.previous);

    expect(
      container.read(strategyPageSessionProvider).transitionState,
      PageTransitionState.animatingBackward,
    );
    final transitionState =
        container.read(overlay_transition.transitionProvider);
    expect(transitionState.hideView, isTrue);
    expect(
      transitionState.phase,
      overlay_transition.PageTransitionPhase.preparing,
    );
    expect(transitionState.direction, PageTransitionDirection.backward);
    expect(queueNotifier.flushNowCount, 1);
    expect(container.read(strategyPageSessionProvider).activePageId, 'page-1');
    expect(container.read(textProvider).single.text, 'before');
  });

  test('pending remote reapply resumes through non-flushing path', () async {
    const strategyId = 'cloud-strategy';
    final pageOne =
        _remotePage(strategyId: strategyId, pageId: 'page-1', sortIndex: 0);
    final initialSnapshot = _cloudSnapshot(
      strategyId: strategyId,
      sequence: 1,
      pages: [pageOne],
      elementsByPage: {
        'page-1': [
          _remoteText(
              strategyId: strategyId,
              pageId: 'page-1',
              elementId: 'text-1',
              text: 'before')
        ],
      },
    );
    final updatedSnapshot = _cloudSnapshot(
      strategyId: strategyId,
      sequence: 2,
      pages: [pageOne],
      elementsByPage: {
        'page-1': [
          _remoteText(
              strategyId: strategyId,
              pageId: 'page-1',
              elementId: 'text-1',
              text: 'after')
        ],
      },
    );

    final remoteNotifier = _FakeRemoteStrategySnapshotNotifier(initialSnapshot);
    final queueNotifier = _FakeStrategyOpQueueNotifier(strategyId);
    final container = await _cloudContainer(
      strategyState: const StrategyState(
        strategyId: strategyId,
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      ),
      remoteNotifier: remoteNotifier,
      queueNotifier: queueNotifier,
    );

    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: strategyId,
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(strategySaveStateProvider.notifier)
      ..markDirty()
      ..setPendingCloudSync(true);
    remoteNotifier.setSnapshot(updatedSnapshot);
    await _settle();

    expect(container.read(textProvider).single.text, 'before');
    expect(queueNotifier.enqueueAllCount, 0);
    expect(queueNotifier.flushNowCount, 0);

    container.read(strategySaveStateProvider.notifier).markPersisted();
    await _settle();

    expect(container.read(textProvider).single.text, 'after');
    expect(queueNotifier.enqueueAllCount, 0);
    expect(queueNotifier.flushNowCount, 0);
  });

  test('user page switch still flushes current local page', () async {
    final box = await _openStrategyBox('icarus-page-session-local-switch-');
    final strategy = _localStrategy(
      strategyId: 'local-strategy',
      firstText: 'before',
      secondText: 'page-two',
    );
    await box.put(strategy.id, strategy);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(strategyProvider.notifier).setFromState(
          const StrategyState(
            strategyId: 'local-strategy',
            strategyName: 'Local Strategy',
            source: StrategySource.local,
            storageDirectory: null,
            isOpen: true,
          ),
        );
    container.listen(strategyPageSessionProvider, (_, __) {});

    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: strategy.id,
          source: StrategySource.local,
          selectFirstPageIfNeeded: true,
        );

    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'text-1', position: const Offset(10, 20))..text = 'draft',
    ]);

    await container
        .read(strategyPageSessionProvider.notifier)
        .setActivePage('page-2');

    final saved = box.get(strategy.id)!;
    expect(saved.pages.first.textData.single.text, 'draft');
    expect(container.read(textProvider).single.text, 'page-two');
  });

  test('initializeForStrategy does not flush before initial apply', () async {
    final box = await _openStrategyBox('icarus-page-session-local-init-');
    final strategy = _localStrategy(
      strategyId: 'local-strategy',
      firstText: 'persisted',
      secondText: 'page-two',
    );
    await box.put(strategy.id, strategy);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(strategyProvider.notifier).setFromState(
          const StrategyState(
            strategyId: 'local-strategy',
            strategyName: 'Local Strategy',
            source: StrategySource.local,
            storageDirectory: null,
            isOpen: true,
          ),
        );
    container.listen(strategyPageSessionProvider, (_, __) {});
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'stray', position: const Offset(90, 90))..text = 'stray',
    ]);

    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: strategy.id,
          source: StrategySource.local,
          selectFirstPageIfNeeded: true,
        );

    final saved = box.get(strategy.id)!;
    expect(saved.pages.first.textData.single.text, 'persisted');
    expect(container.read(textProvider).single.text, 'persisted');
  });
}
