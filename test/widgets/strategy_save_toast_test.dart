import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/strategy_save_icon_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:toastification/toastification.dart';

/// The save toast after the press: it must say where the work actually is,
/// read from the library and the outboxes, not from the press.
void main() {
  setUpAll(() {
    appProviderContainer = ProviderContainer();
  });

  tearDownAll(() => appProviderContainer.dispose());

  group('cloud', () {
    testWidgets('a failed outbox write is not called saved', (tester) async {
      final container = _cloudContainer(
        store: _FailingPutStore(),
        connected: true,
      );
      await _pressSave(tester, container);

      expect(find.text(unverifiedCloudWorkMessage), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      expect(
          container.read(strategyOpQueueProvider).hasDurabilityFailure, isTrue);
      await _finish(tester, container);
    });

    testWidgets('offline, the change is saved here and waits to sync',
        (tester) async {
      final store = MemoryDurableStrategyOutboxStore();
      final container = _cloudContainer(store: store, connected: false);
      await _pressSave(tester, container);

      expect(find.text('Offline, changes stay on this device'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      expect(store.values, hasLength(1));
      await _finish(tester, container);
    });

    testWidgets('once the server accepts the change, it is saved',
        (tester) async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _AckingRepository();
      final container = _cloudContainer(
        store: store,
        connected: true,
        repository: repository,
      );
      await _pressSave(tester, container);

      expect(repository.batches, 1);
      expect(store.values, isEmpty);
      expect(find.text('Saved'), findsOneWidget);
      await _finish(tester, container);
    });
  });

  group('local', () {
    testWidgets('a save that throws is not called saved', (tester) async {
      final container = _localContainer(
        () => _LocalStrategy((_) async => throw StateError('disk full')),
      );
      await _pressSave(tester, container);

      expect(find.text(saveFailedMessage), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      await _finish(tester, container);
    });

    testWidgets('a save that never wrote the library is not called saved',
        (tester) async {
      // saveToHive returns quietly when the strategy is missing from the
      // library: nothing throws, and nothing was written.
      final container = _localContainer(
        () => _LocalStrategy((_) async {}),
      );
      await _pressSave(tester, container);

      expect(find.text(saveFailedMessage), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      await _finish(tester, container);
    });

    testWidgets('a save that wrote the library is saved', (tester) async {
      final container = _localContainer(
        () => _LocalStrategy(
          (ref) async =>
              ref.read(strategySaveStateProvider.notifier).markPersisted(),
        ),
      );
      await _pressSave(tester, container);

      expect(find.text('Saved'), findsOneWidget);
      await _finish(tester, container);
    });
  });
}

Future<void> _pressSave(
    WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ToastificationWrapper(
        child: ShadApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => saveStrategyNow(context, ref),
                child: const Text('Save now'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Save now'));
  await tester.pumpAndSettle();
}

/// Lets the toast close and the queue's retry timers go with the container.
Future<void> _finish(WidgetTester tester, ProviderContainer container) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  await tester.pump(const Duration(seconds: 1));
}

ProviderContainer _cloudContainer({
  required DurableStrategyOutboxStore store,
  required bool connected,
  ConvexStrategyRepository? repository,
}) {
  final container = ProviderContainer(overrides: [
    strategyProvider.overrideWith(_CloudStrategy.new),
    durableStrategyOutboxStoreProvider.overrideWithValue(store),
    convexStrategyRepositoryProvider
        .overrideWithValue(repository ?? _AckingRepository()),
    authProvider.overrideWith(_ReadyAuth.new),
    convexConnectionProvider.overrideWith((ref) => Stream.value(connected)),
    convexConnectionSnapshotProvider.overrideWith((ref) => connected),
    cloudMediaUploadQueueProvider.overrideWith(_EmptyMediaQueue.new),
    activePageLiveSyncProvider.overrideWith(_IdleLiveSync.new),
  ]);
  container.read(strategySaveStateProvider);
  container
      .read(strategyOpQueueProvider.notifier)
      .setActiveStrategy('cloud-strategy', accountId: 'account-a');
  return container;
}

ProviderContainer _localContainer(_LocalStrategy Function() strategy) {
  final container = ProviderContainer(overrides: [
    strategyProvider.overrideWith(strategy),
  ]);
  container.read(strategySaveStateProvider);
  return container;
}

/// Saves a cloud strategy the way the editor does: the change goes to the
/// outbox, then the outbox is flushed.
class _CloudStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'cloud-strategy',
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  Future<void> forceSaveNow(String id) async {
    ref.read(strategySaveStateProvider.notifier)
      ..markDirty()
      ..setPendingCloudSync(true);
    final queue = ref.read(strategyOpQueueProvider.notifier);
    await queue.enqueue(
      const ElementPatchOp(
        opId: 'save-press',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'mine'},
        expectedElementRevision: 1,
      ),
    );
    await queue.flushNow();
  }
}

class _LocalStrategy extends StrategyProvider {
  _LocalStrategy(this.save);

  final Future<void> Function(Ref ref) save;

  @override
  StrategyState build() => const StrategyState(
        strategyId: 'local-strategy',
        strategyName: 'Local Strategy',
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  Future<void> forceSaveNow(String id) => save(ref);
}

class _FailingPutStore extends MemoryDurableStrategyOutboxStore {
  @override
  Future<void> put(DurableOutboxRecord record) async {
    throw StateError('disk write failed');
  }
}

class _AckingRepository extends Fake implements ConvexStrategyRepository {
  int batches = 0;

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    batches += 1;
    return [for (final op in ops) AppliedOpAck(opId: op.opId, revision: 2)];
  }
}

class _ReadyAuth extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: <String, dynamic>{},
          userMetadata: <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _EmptyMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() => const CloudMediaUploadQueueState(
        jobs: [],
        isProcessing: false,
      );
}

class _IdleLiveSync extends ActivePageLiveSyncNotifier {
  @override
  ActivePageLiveSyncState build() => const ActivePageLiveSyncState();
}
