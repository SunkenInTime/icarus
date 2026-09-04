import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/cloud_sync_status_chip.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _CloudStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'cloud-strategy',
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      );
}

class _SettledOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'client-a',
        durableLoaded: true,
      );
}

class _EmptyMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() => const CloudMediaUploadQueueState(
        jobs: [],
        isProcessing: false,
      );
}

class _FixedSaveState extends StrategySaveStateNotifier {
  _FixedSaveState(this.initialState);

  final StrategySaveState initialState;

  @override
  StrategySaveState build() => initialState;
}

ProviderContainer _createContainer({
  bool connected = true,
  StrategySaveState? saveState,
}) {
  return ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_CloudStrategyProvider.new),
      strategyOpQueueProvider.overrideWith(_SettledOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_EmptyMediaQueue.new),
      convexConnectionProvider.overrideWith((ref) => Stream.value(connected)),
      if (saveState != null)
        strategySaveStateProvider.overrideWith(
          () => _FixedSaveState(saveState),
        ),
    ],
  );
}

void main() {
  testWidgets('an active text draft can never appear synced', (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Synced'), findsOneWidget);

    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'visible local edit');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Editing…'), findsOneWidget);
    expect(find.text('Synced'), findsNothing);

    await tester.tap(find.text('Editing…'));
    await tester.pumpAndSettle();
    expect(find.text('Edit not synced yet'), findsOneWidget);
    expect(
      find.text(
        'Finish editing or switch pages to send this change to the cloud.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('offline remains visible while a text draft is active',
      (tester) async {
    final container = _createContainer(connected: false);
    addTearDown(container.dispose);
    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'offline edit');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Editing…'), findsNothing);
    expect(find.text('Synced'), findsNothing);
  });

  test('status provider prioritizes connectivity over an offline flush error',
      () async {
    final container = _createContainer(
      connected: false,
      saveState: const StrategySaveState(
        isDirty: true,
        isSaving: false,
        hasPendingCloudSync: true,
        cloudSyncError: 'Cloud connection is offline.',
        hasPendingMediaSync: false,
        mediaSyncErrorCount: 0,
        lastPersistedAt: null,
      ),
    );
    addTearDown(container.dispose);
    await container.read(convexConnectionProvider.future);

    expect(container.read(cloudSyncStatusProvider), CloudSyncStatus.offline);
  });

  testWidgets('offline flush errors render Offline instead of Needs attention',
      (tester) async {
    final container = _createContainer(
      connected: false,
      saveState: const StrategySaveState(
        isDirty: true,
        isSaving: false,
        hasPendingCloudSync: true,
        cloudSyncError: 'Cloud connection is offline.',
        hasPendingMediaSync: false,
        mediaSyncErrorCount: 0,
        lastPersistedAt: null,
      ),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Needs attention'), findsNothing);
  });
}
