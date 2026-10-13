import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/strategy_access_watcher.dart';
import 'package:icarus/widgets/strategy_edit_boundary.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

class _RoleSnapshotNotifier extends RemoteEditorSnapshotNotifier {
  _RoleSnapshotNotifier(this.role);

  final String role;

  @override
  Future<RemoteEditorSnapshot?> build() async {
    final now = DateTime.utc(2026);
    return RemoteEditorSnapshot(
      shell: RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: 'cloud-strategy',
          name: 'Cloud Strategy',
          mapData: Maps.mapNames[MapValue.ascent]!,
          revision: 1,
          createdAt: now,
          updatedAt: now,
          role: role,
        ),
        pages: const [],
      ),
      activePage: null,
    );
  }

  /// The reader's role changes on the server while the strategy is open.
  void setRole(String nextRole) {
    final current = state.requireValue!;
    final header = current.header;
    state = AsyncData(RemoteEditorSnapshot(
      shell: RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: header.publicId,
          name: header.name,
          mapData: header.mapData,
          revision: header.revision + 1,
          createdAt: header.createdAt,
          updatedAt: header.updatedAt,
          role: nextRole,
        ),
        pages: const [],
      ),
      activePage: null,
    ));
  }

  /// A fresh read of the shell was refused: the reader was removed.
  void loseAccess() {
    state = const AsyncError(
      StrategyAccessLost('cloud-strategy'),
      StackTrace.empty,
    );
  }

  /// A read failed for a reason that says nothing about access.
  void failToRead() {
    state = AsyncError(StateError('offline'), StackTrace.empty);
  }
}

/// Holds one paused change for the open strategy, and records discards.
class _UnsentWorkQueue extends StrategyOpQueueNotifier {
  _UnsentWorkQueue({required this.unsent, this.discardWorks = true});

  final bool unsent;
  final bool discardWorks;
  final discarded = <String>[];

  @override
  StrategyOpQueueState build() => StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'test-client',
        durableLoaded: true,
        pausedByEntityKey: unsent
            ? {
                const EntitySyncKey.strategy(): const QueuedEntityIntent(
                  entityKey: EntitySyncKey.strategy(),
                  pending: PendingOp(
                    op: StrategyPatchOp(
                      opId: 'op-1',
                      payload: <String, dynamic>{'name': 'kept'},
                      expectedStrategyRevision: 1,
                    ),
                    clientId: 'test-client',
                  ),
                ),
              }
            : const {},
      );

  @override
  Future<bool> discardUnsendableWork(
    String strategyPublicId, {
    required String accountId,
  }) async {
    discarded.add('$accountId/$strategyPublicId');
    return discardWorks;
  }
}

/// Answers the second look the dialog takes before discarding.
class _RecheckRepository extends Fake implements ConvexStrategyRepository {
  _RecheckRepository({required this.refused});

  bool refused;

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    if (refused) {
      throw const ConvexFunctionException(
        code: ConvexErrorCode.forbidden,
        rawCode: 'FORBIDDEN',
        message: 'Forbidden',
      );
    }
    return RemoteStrategyShell(
      header: RemoteStrategyHeader(
        publicId: strategyPublicId,
        name: 'Retake B',
        mapData: 'ascent',
        revision: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        role: 'editor',
      ),
      pages: const [],
    );
  }
}

class _ClearingMediaQueue extends CloudMediaUploadQueueNotifier {
  final cleared = <String>[];

  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);

  @override
  Future<bool> discardUnreferencedJobs(
    String strategyPublicId, {
    required String accountId,
  }) async {
    cleared.add('$accountId/$strategyPublicId');
    return true;
  }
}

class _RecordingStrategyOpQueue extends StrategyOpQueueNotifier {
  final enqueued = <StrategyOp>[];

  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'test-client',
        durableLoaded: true,
      );

  @override
  Future<void> enqueueAll(
    Iterable<StrategyOp> ops, {
    bool flushImmediately = false,
  }) async {
    enqueued.addAll(ops);
  }
}

Future<void> _invokeAddTextShortcut(
  WidgetTester tester,
  StrategyCapabilities capabilities,
) async {
  late WidgetRef widgetRef;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentStrategyCapabilitiesProvider.overrideWithValue(capabilities),
      ],
      child: MaterialApp(
        home: GlobalShortcuts(
          child: Consumer(
            builder: (context, ref, _) {
              widgetRef = ref;
              return const SizedBox(
                key: ValueKey('shortcut-target'),
                width: 100,
                height: 100,
              );
            },
          ),
        ),
      ),
    ),
  );

  Actions.invoke(
    tester.element(find.byKey(const ValueKey('shortcut-target'))),
    const AddedTextIntent(),
  );
  await tester.pump();

  expect(
    widgetRef.read(textProvider).length,
    capabilities.canEditPages ? 1 : 0,
  );
}

/// The capabilities of the open strategy, changeable mid-test.
final _capabilities = StateProvider<StrategyCapabilities>(
  (ref) => StrategyCapabilities.fullAccess(),
);

/// Who makes each edit in [_guardedEdits]. A local strategy can always be
/// edited.
final _readers = <String, StrategyCapabilities>{
  'viewer': StrategyCapabilities.fromCloudRole('viewer'),
  'editor': StrategyCapabilities.fromCloudRole('editor'),
  'owner': StrategyCapabilities.fromCloudRole('owner'),
  'local strategy': StrategyCapabilities.fullAccess(),
};

final _breachAbility = AgentData.agents[AgentType.breach]!.abilities.first;

/// A page with one of everything, loaded the way the server's copy is.
ProviderContainer _loadedPage(StrategyCapabilities capabilities) {
  final container = ProviderContainer(overrides: [
    currentStrategyCapabilitiesProvider
        .overrideWith((ref) => ref.watch(_capabilities)),
  ]);
  container.read(_capabilities.notifier).state = capabilities;
  container.read(agentProvider.notifier).fromHive([
    PlacedAgent(
      id: 'agent',
      type: AgentType.jett,
      position: const Offset(400, 300),
    ),
    PlacedViewConeAgent(
      id: 'cone-agent',
      type: AgentType.sova,
      position: const Offset(500, 300),
      presetType: UtilityType.viewCone90,
      rotation: 0.5,
      length: 40,
    ),
    PlacedCircleAgent(
      id: 'circle-agent',
      type: AgentType.omen,
      position: const Offset(600, 300),
      diameterMeters: 4,
    ),
  ]);
  container.read(abilityProvider.notifier).fromHive([
    PlacedAbility(
      id: 'ability',
      data: _breachAbility,
      position: const Offset(400, 400),
    ),
  ]);
  container.read(drawingProvider.notifier).fromHive([
    Line(
      id: 'line',
      lineStart: const Offset(100, 100),
      lineEnd: const Offset(200, 100),
      colorValue: 0xFFFFFFFF,
      isDotted: false,
      hasArrow: false,
      boundingBox: BoundingBox(
        min: const Offset(100, 100),
        max: const Offset(200, 100),
      ),
    ),
  ]);
  container.read(textProvider.notifier).fromHive([
    PlacedText(id: 'text', position: const Offset(300, 200))..text = 'B site',
  ]);
  container.read(placedImageProvider.notifier).fromHive([
    PlacedImage(
      id: 'image',
      position: const Offset(300, 500),
      aspectRatio: 1,
      scale: 200,
      fileExtension: '.png',
    ),
  ]);
  container.read(utilityProvider.notifier).fromHive([
    PlacedUtility(
      id: 'spike',
      type: UtilityType.spike,
      position: const Offset(700, 400),
    ),
    PlacedUtility(
      id: 'cone',
      type: UtilityType.viewCone90,
      position: const Offset(700, 500),
    ),
    PlacedUtility(
      id: 'circle',
      type: UtilityType.customCircle,
      position: const Offset(700, 600),
      customDiameter: 5,
      customColorValue: 0xFFFFFFFF,
    ),
  ]);
  return container;
}

/// Everything the page holds, as text, so edits made in place show too.
String _pageContent(ProviderContainer container) => [
      container.read(agentProvider.notifier).toJson(),
      container.read(abilityProvider.notifier).toJson(),
      container.read(drawingProvider.notifier).toJson(),
      container.read(textProvider.notifier).toJson(),
      jsonEncode([
        for (final image in container.read(placedImageProvider).images)
          image.toJson(),
      ]),
      container.read(utilityProvider.notifier).toJson(),
      jsonEncode(container.read(strategySettingsProvider).toJson()),
    ].join('\n');

/// Each mutator that commits an edit to a page, with an edit that changes
/// the page [_loadedPage] loads.
final _guardedEdits = <String, FutureOr<void> Function(ProviderContainer)>{
  'add an agent': (c) => c.read(agentProvider.notifier).addAgent(
        PlacedAgent(
          id: 'new-agent',
          type: AgentType.sage,
          position: const Offset(450, 450),
        ),
      ),
  'remove an agent': (c) =>
      c.read(agentProvider.notifier).removeAgentAsAction('agent'),
  'remove an agent outright': (c) =>
      c.read(agentProvider.notifier).removeAgent('agent'),
  'mark an agent dead': (c) =>
      c.read(agentProvider.notifier).toggleAgentState('agent'),
  'arm an agent': (c) =>
      c.read(agentProvider.notifier).setWeapon('agent', WeaponType.classic),
  'move an agent': (c) => c
      .read(agentProvider.notifier)
      .updatePosition(const Offset(420, 320), 'agent'),
  'copy an agent': (c) => c
      .read(agentProvider.notifier)
      .duplicateAgentAt(sourceId: 'agent', position: const Offset(450, 350)),
  "turn an agent's view cone": (c) => c
      .read(agentProvider.notifier)
      .updateViewConeGeometry(id: 'cone-agent', rotation: 1.5, length: 60),
  "raise an agent's view cone": (c) => c
      .read(agentProvider.notifier)
      .updateViewConeElevation(id: 'cone-agent', elevation: 2),
  "resize an agent's circle": (c) =>
      c.read(agentProvider.notifier).updateCircleGeometry(
            id: 'circle-agent',
            diameterMeters: 8,
            colorValue: 0xFFFF0000,
            opacityPercent: 50,
          ),
  'give an agent a view cone': (c) =>
      c.read(agentProvider.notifier).convertPlainAgentToViewCone(
            id: 'agent',
            presetType: UtilityType.viewCone90,
            rotation: 0,
            length: 40,
          ),
  "take an agent's view cone away": (c) => c
      .read(agentProvider.notifier)
      .convertViewConeAgentToPlain(id: 'cone-agent'),
  'give an agent a circle': (c) =>
      c.read(agentProvider.notifier).convertPlainAgentToCircle(
            id: 'agent',
            diameterMeters: 4,
            colorValue: 0xFFFFFFFF,
            opacityPercent: 100,
          ),
  'add an ability': (c) => c.read(abilityProvider.notifier).addAbility(
        PlacedAbility(
          id: 'new-ability',
          data: _breachAbility,
          position: const Offset(450, 450),
        ),
      ),
  'remove an ability': (c) =>
      c.read(abilityProvider.notifier).removeAbilityAsAction('ability'),
  'remove an ability outright': (c) =>
      c.read(abilityProvider.notifier).removeAbility('ability'),
  'move an ability': (c) => c
      .read(abilityProvider.notifier)
      .updatePosition(const Offset(420, 420), 'ability'),
  'copy an ability': (c) => c.read(abilityProvider.notifier).duplicateAbilityAt(
        sourceId: 'ability',
        position: const Offset(450, 420),
      ),
  'turn an ability': (c) =>
      c.read(abilityProvider.notifier).updateGeometry(0, rotation: 1),
  "hide an ability's range": (c) =>
      c.read(abilityProvider.notifier).updateVisualState(
            0,
            const AbilityVisualState(showRangeFill: false),
          ),
  'finish a line': (c) {
    final drawings = c.read(drawingProvider.notifier);
    drawings.startLine(
      const Offset(300, 300),
      CoordinateSystem.instance,
      Colors.white,
      2,
      false,
      false,
      false,
      TraversalSpeedProfile.running,
    );
    drawings.finishCurrentLine(
      const Offset(400, 400),
      CoordinateSystem.instance,
    );
  },
  'delete a drawing': (c) => c.read(drawingProvider.notifier).deleteDrawing(0),
  'erase a drawing': (c) =>
      c.read(drawingProvider.notifier).onErase(const Offset(150, 100)),
  'add text': (c) => c.read(textProvider.notifier).addText(
        PlacedText(id: 'new-text', position: const Offset(250, 250)),
      ),
  'remove text': (c) =>
      c.read(textProvider.notifier).removeTextAsAction('text'),
  'remove text outright': (c) =>
      c.read(textProvider.notifier).removeText('text'),
  'move text': (c) => c
      .read(textProvider.notifier)
      .updatePosition(const Offset(320, 220), 'text'),
  'retype text': (c) =>
      c.read(textProvider.notifier).commitText('text', 'A site'),
  'tag text': (c) =>
      c.read(textProvider.notifier).updateTagColor('text', 0xFFFF0000),
  'resize text': (c) => c
      .read(textProvider.notifier)
      .resize('text', size: 240, position: const Offset(310, 200)),
  'add an image': (c) => c.read(placedImageProvider.notifier).addImage(
        imageBytes: Uint8List(4),
        strategyId: null,
        strategySource: null,
        fileExtension: '.png',
        aspectRatio: 1,
      ),
  'remove an image': (c) =>
      c.read(placedImageProvider.notifier).removeImageAsAction('image'),
  'remove an image outright': (c) =>
      c.read(placedImageProvider.notifier).removeImage('image'),
  'move an image': (c) => c
      .read(placedImageProvider.notifier)
      .updatePosition(const Offset(320, 520), 'image'),
  'tag an image': (c) =>
      c.read(placedImageProvider.notifier).updateTagColor('image', 0xFFFF0000),
  'resize an image': (c) => c
      .read(placedImageProvider.notifier)
      .resize('image', scale: 300, position: const Offset(300, 500)),
  'add a utility': (c) => c.read(utilityProvider.notifier).addUtility(
        PlacedUtility(
          id: 'new-spike',
          type: UtilityType.spike,
          position: const Offset(750, 450),
        ),
      ),
  'remove a utility': (c) =>
      c.read(utilityProvider.notifier).removeUtilityAsAction('spike'),
  'remove a utility outright': (c) =>
      c.read(utilityProvider.notifier).removeUtility('spike'),
  'move a utility': (c) => c
      .read(utilityProvider.notifier)
      .updatePosition(const Offset(720, 420), 'spike'),
  'turn a view cone': (c) =>
      c.read(utilityProvider.notifier).updateRotation(1, 1.2, 60),
  'raise a view cone': (c) =>
      c.read(utilityProvider.notifier).updateViewConeElevation('cone', 2),
  'resize a custom shape': (c) => c
      .read(utilityProvider.notifier)
      .updateCustomCircleDiameter(id: 'circle', diameterMeters: 9),
  'recolor a custom shape': (c) => c
      .read(utilityProvider.notifier)
      .updateCustomShapeColor(id: 'circle', colorValue: 0xFF00FF00),
  'resize agents': (c) =>
      c.read(strategySettingsProvider.notifier).updateAgentSize(40),
  'resize abilities': (c) =>
      c.read(strategySettingsProvider.notifier).updateAbilitySize(40),
  'grey out team colors': (c) =>
      c.read(strategySettingsProvider.notifier).updateNeutralTeamColors(true),
  'clear the page': (c) => c.read(actionProvider.notifier).clearAllAsAction(),
  'clear the agents': (c) =>
      c.read(actionProvider.notifier).clearGroupAsAction(ActionGroup.agent),
  'change settings as one step': (c) =>
      c.read(actionProvider.notifier).performTransaction(
        groups: const [ActionGroup.strategySettings],
        mutation: () =>
            c.read(strategySettingsProvider.notifier).updateAgentSize(40),
      ),
};

/// The editor with [_RoleSnapshotNotifier] behind it, open on its strategy.
Future<(ProviderContainer, List<int>)> _pumpWatcher(
  WidgetTester tester, {
  String role = 'editor',
  _UnsentWorkQueue? queue,
  _ClearingMediaQueue? media,
  _RecheckRepository? server,
}) async {
  final container = ProviderContainer(overrides: [
    remoteEditorSnapshotProvider.overrideWith(
      () => _RoleSnapshotNotifier(role),
    ),
    strategyOpQueueProvider
        .overrideWith(() => queue ?? _UnsentWorkQueue(unsent: false)),
    cloudMediaUploadQueueProvider
        .overrideWith(() => media ?? _ClearingMediaQueue()),
    convexStrategyRepositoryProvider
        .overrideWithValue(server ?? _RecheckRepository(refused: true)),
  ]);
  addTearDown(container.dispose);
  await tester.runAsync(
    () => container.read(remoteEditorSnapshotProvider.future),
  );
  container.read(strategyProvider.notifier).setFromState(
        const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Retake B',
          source: StrategySource.cloud,
          storageDirectory: null,
          isOpen: true,
        ),
      );
  final leaves = <int>[];
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: ToastificationWrapper(
      child: ShadApp(
        home: StrategyAccessWatcher(
          onLeave: () async => leaves.add(1),
          child: const Scaffold(),
        ),
      ),
    ),
  ));
  return (container, leaves);
}

_RoleSnapshotNotifier _remote(ProviderContainer container) =>
    container.read(remoteEditorSnapshotProvider.notifier)
        as _RoleSnapshotNotifier;

/// A toast's text. Toasts sit in an overlay entry that is still animating
/// in when these tests look, so offstage widgets count.
Finder _toast(String text) => find.byWidgetPredicate(
      (widget) => widget is Text && widget.data == text,
      skipOffstage: false,
    );

// toastification is a global: clear it and let every auto-close timer run
// out, so no toast outlives its test or lands in the next one.
Future<void> _clearToasts(WidgetTester tester) async {
  toastification.dismissAll(delayForAnimation: false);
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

const _demotedToast = 'Your access to this strategy changed to view only.';

Future<void> _settleToasts(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('viewers cannot add text with an editor shortcut',
      (tester) async {
    await _invokeAddTextShortcut(
      tester,
      StrategyCapabilities.fromCloudRole('viewer'),
    );
  });

  for (final role in ['editor', 'owner']) {
    testWidgets('$role can add text with an editor shortcut', (tester) async {
      await _invokeAddTextShortcut(
        tester,
        StrategyCapabilities.fromCloudRole(role),
      );
    });
  }

  testWidgets('view-only edit controls absorb pointer input', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentStrategyCapabilitiesProvider.overrideWithValue(
            StrategyCapabilities.fromCloudRole('viewer'),
          ),
        ],
        child: MaterialApp(
          home: StrategyEditBoundary(
            disabledOpacity: 0.55,
            child: GestureDetector(
              key: const ValueKey('edit-control'),
              onTap: () => taps += 1,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('edit-control')),
      warnIfMissed: false,
    );
    expect(taps, 0);
    expect(
      tester
          .widget<ExcludeFocus>(
            find.descendant(
              of: find.byType(StrategyEditBoundary),
              matching: find.byType(ExcludeFocus),
            ),
          )
          .excluding,
      isTrue,
    );
    expect(
      tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(StrategyEditBoundary),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      0.55,
    );
  });

  test('a stale cloud role cannot grant access to another strategy', () async {
    final container = ProviderContainer(
      overrides: [
        remoteEditorSnapshotProvider.overrideWith(
          () => _RoleSnapshotNotifier('editor'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(remoteEditorSnapshotProvider.future);
    container.read(strategyProvider.notifier).setFromState(
          const StrategyState(
            strategyId: 'different-cloud-strategy',
            strategyName: 'Different Cloud Strategy',
            source: StrategySource.cloud,
            storageDirectory: null,
            isOpen: true,
          ),
        );

    expect(
      container.read(currentStrategyCapabilitiesProvider).canEditPages,
      isFalse,
    );
  });

  for (final role in ['viewer', 'editor', 'owner']) {
    test('$role cloud op queue access matches page edit capability', () async {
      final queue = _RecordingStrategyOpQueue();
      final container = ProviderContainer(
        overrides: [
          remoteEditorSnapshotProvider.overrideWith(
            () => _RoleSnapshotNotifier(role),
          ),
          strategyOpQueueProvider.overrideWith(() => queue),
        ],
      );
      addTearDown(container.dispose);
      await container.read(remoteEditorSnapshotProvider.future);
      container.read(strategyProvider.notifier).setFromState(
            const StrategyState(
              strategyId: 'cloud-strategy',
              strategyName: 'Cloud Strategy',
              source: StrategySource.cloud,
              storageDirectory: null,
              isOpen: true,
            ),
          );

      await container.read(strategyProvider.notifier).enqueueOps(
        const [
          StrategyPatchOp(
            opId: 'strategy-op',
            payload: {'name': 'Changed'},
            expectedStrategyRevision: 1,
          ),
        ],
      );

      expect(
        queue.enqueued.length,
        role == 'viewer' ? 0 : 1,
      );
    });
  }

  group('page edits', () {
    setUp(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

    for (final MapEntry(key: edit, value: run) in _guardedEdits.entries) {
      for (final MapEntry(key: reader, value: capabilities)
          in _readers.entries) {
        final refused = !capabilities.canEditPages;
        test(
            '${refused ? 'a' : 'an'} $reader '
            '${refused ? 'cannot' : 'can'} $edit', () async {
          final container = _loadedPage(capabilities);
          addTearDown(container.dispose);
          final before = _pageContent(container);

          await run(container);

          final after = _pageContent(container);
          if (refused) {
            expect(after, before);
            expect(container.read(actionProvider), isEmpty,
                reason: 'nothing to undo either');
            expect(container.read(drawingProvider).currentElement, isNull,
                reason: 'a drawing in progress is let go');
          } else {
            expect(after, isNot(before));
          }
        });
      }
    }

    test('undo and redo change nothing once the reader is a viewer', () {
      final container =
          _loadedPage(StrategyCapabilities.fromCloudRole('editor'));
      addTearDown(container.dispose);
      final history = container.read(actionProvider.notifier);
      container.read(agentProvider.notifier)
        ..toggleAgentState('agent')
        ..setWeapon('agent', WeaponType.classic);
      history.undoAction();
      final edited = _pageContent(container);

      container.read(_capabilities.notifier).state =
          StrategyCapabilities.fromCloudRole('viewer');
      history.undoAction();
      expect(_pageContent(container), edited);
      history.redoAction();
      expect(_pageContent(container), edited);

      // With edit access back, the same history works again.
      container.read(_capabilities.notifier).state =
          StrategyCapabilities.fromCloudRole('editor');
      history.redoAction();
      expect(_pageContent(container), isNot(edited));
    });

    test(
        "a drag that ends after the reader's access dropped leaves the agent "
        'where the server has it', () {
      final container =
          _loadedPage(StrategyCapabilities.fromCloudRole('editor'));
      addTearDown(container.dispose);
      final position = container.read(agentProvider).first.position;

      // The drag started while they could edit; the drop comes after.
      container.read(_capabilities.notifier).state =
          StrategyCapabilities.fromCloudRole('viewer');
      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(420, 320), 'agent');

      expect(container.read(agentProvider).first.position, position);
    });

    test("the server's copy still reaches a viewer's page", () {
      final container =
          _loadedPage(StrategyCapabilities.fromCloudRole('viewer'));
      addTearDown(container.dispose);
      final moved = PlacedAgent(
        id: 'agent',
        type: AgentType.jett,
        position: const Offset(410, 310),
      );

      container.read(agentProvider.notifier).mergeRemote(
        [moved],
        (id) => false,
      );
      container.read(textProvider.notifier).mergeRemote([], (id) => false);

      expect(container.read(agentProvider).single.position, moved.position);
      expect(container.read(textProvider), isEmpty);

      container.read(utilityProvider.notifier).clearAll();
      expect(container.read(utilityProvider), isEmpty);
    });
  });

  test('access confirmed gone leaves nothing editable', () async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final container = ProviderContainer(
      overrides: [
        remoteEditorSnapshotProvider.overrideWith(
          () => _RoleSnapshotNotifier('editor'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(remoteEditorSnapshotProvider.future);
    container.read(strategyProvider.notifier).setFromState(
          const StrategyState(
            strategyId: 'cloud-strategy',
            strategyName: 'Cloud Strategy',
            source: StrategySource.cloud,
            storageDirectory: null,
            isOpen: true,
          ),
        );
    expect(container.read(lastKnownCloudRoleProvider), 'editor');
    expect(
      container.read(currentStrategyCapabilitiesProvider).canEditPages,
      isTrue,
    );
    expect(container.read(isViewOnlyStrategyProvider), isFalse);

    _remote(container).loseAccess();

    expect(
      container.read(currentStrategyCapabilitiesProvider).canEditPages,
      isFalse,
    );
    expect(container.read(lastKnownCloudRoleProvider), isNull,
        reason: 'the editor role last seen no longer holds');
    expect(container.read(isViewOnlyStrategyProvider), isTrue);
    container.read(agentProvider.notifier).addAgent(
          PlacedAgent(
            id: 'new-agent',
            type: AgentType.sage,
            position: const Offset(450, 450),
          ),
        );
    expect(container.read(agentProvider), isEmpty);
  });

  group('while the strategy is open', () {
    testWidgets('a demotion to viewer is told once', (tester) async {
      final (container, _) = await _pumpWatcher(tester);

      _remote(container).setRole('viewer');
      await _settleToasts(tester);
      expect(_toast(_demotedToast), findsOneWidget);

      // The live read brings the same role again: no second toast.
      await _clearToasts(tester);
      _remote(container).setRole('viewer');
      await _settleToasts(tester);
      expect(_toast(_demotedToast), findsNothing);
      expect(
        container.read(currentStrategyCapabilitiesProvider).canEditPages,
        isFalse,
      );
      await _clearToasts(tester);
    });

    testWidgets('opening a strategy as a viewer is not a demotion',
        (tester) async {
      final (container, _) = await _pumpWatcher(tester, role: 'viewer');

      _remote(container).setRole('viewer');
      await _settleToasts(tester);
      expect(_toast(_demotedToast), findsNothing);
      await _clearToasts(tester);
    });

    testWidgets('losing access shows it and leads back to the library',
        (tester) async {
      final (container, leaves) = await _pumpWatcher(tester);

      _remote(container).loseAccess();
      await tester.pumpAndSettle();

      expect(find.text('You no longer have access'), findsOneWidget);
      expect(
        find.text(
          'The owner removed you from "Retake B", or stopped sharing it.',
        ),
        findsOneWidget,
      );
      expect(find.byType(ShadButton), findsOneWidget,
          reason: 'Back to library is the only way on');
      expect(leaves, isEmpty);

      await tester.tap(find.text('Back to library'));
      await tester.pumpAndSettle();
      expect(find.text('You no longer have access'), findsNothing);
      expect(leaves, [1]);
    });

    testWidgets('leaving takes down a dialog that was open over the editor',
        (tester) async {
      final (container, leaves) = await _pumpWatcher(tester);
      unawaited(showShadDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (_) => const ShadDialog(child: Text('Edit lineup')),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Edit lineup'), findsOneWidget);

      _remote(container).loseAccess();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back to library'));
      await tester.pumpAndSettle();

      expect(find.text('Edit lineup'), findsNothing,
          reason: 'the editor route is what leaving pops');
      expect(leaves, [1]);
    });

    testWidgets('unsent changes are named, and can be discarded on the way out',
        (tester) async {
      final queue = _UnsentWorkQueue(unsent: true);
      final media = _ClearingMediaQueue();
      final (container, leaves) =
          await _pumpWatcher(tester, queue: queue, media: media);

      _remote(container).loseAccess();
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The owner removed you from "Retake B", or stopped sharing it. '
          "1 change you made here hasn't reached the cloud and can't be "
          'saved.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(queue.discarded, ['account-a/cloud-strategy']);
      expect(media.cleared, ['account-a/cloud-strategy']);
      expect(leaves, [1]);
      await _clearToasts(tester);
    });

    testWidgets('access back by the time Discard is pressed discards nothing',
        (tester) async {
      final queue = _UnsentWorkQueue(unsent: true);
      final media = _ClearingMediaQueue();
      final server = _RecheckRepository(refused: true);
      final (container, leaves) = await _pumpWatcher(tester,
          queue: queue, media: media, server: server);

      _remote(container).loseAccess();
      await tester.pumpAndSettle();
      // The owner adds them back while the dialog is open.
      server.refused = false;
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(queue.discarded, isEmpty);
      expect(media.cleared, isEmpty);
      expect(
        _toast('You can open this strategy again, so nothing was discarded.'),
        findsOneWidget,
      );
      expect(leaves, [1]);
      await _clearToasts(tester);
    });

    testWidgets('images stay when their changes could not be discarded',
        (tester) async {
      final queue = _UnsentWorkQueue(unsent: true, discardWorks: false);
      final media = _ClearingMediaQueue();
      final (container, _) =
          await _pumpWatcher(tester, queue: queue, media: media);

      _remote(container).loseAccess();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(queue.discarded, ['account-a/cloud-strategy']);
      expect(media.cleared, isEmpty);
      await _clearToasts(tester);
    });

    testWidgets('keeping them leaves them for the library', (tester) async {
      final queue = _UnsentWorkQueue(unsent: true);
      final (container, leaves) = await _pumpWatcher(tester, queue: queue);

      _remote(container).loseAccess();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back to library'));
      await tester.pumpAndSettle();

      expect(queue.discarded, isEmpty);
      expect(leaves, [1]);
    });

    testWidgets('a read that fails for another reason shows nothing',
        (tester) async {
      final (container, leaves) = await _pumpWatcher(tester);

      _remote(container).failToRead();
      await tester.pumpAndSettle();

      expect(find.text('You no longer have access'), findsNothing);
      expect(leaves, isEmpty);
      expect(
        container.read(currentStrategyCapabilitiesProvider).canEditPages,
        isTrue,
        reason: 'the role last read still holds',
      );
    });
  });
}
