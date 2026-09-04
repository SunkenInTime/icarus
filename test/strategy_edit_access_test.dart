import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/strategy_edit_boundary.dart';

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
}
