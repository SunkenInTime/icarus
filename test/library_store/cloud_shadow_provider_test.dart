import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart'
    show at, pageList, pageSnapshot, serverRows, strategyId;

class _Queue extends StrategyOpQueueNotifier {
  int? stamp = 0;

  @override
  StrategyOpQueueState build() => const StrategyOpQueueState();

  @override
  int? get liveStamp => stamp;
}

class _Remote extends RemoteEditorSnapshotNotifier {
  final connections = Expando<int>();
  var shown = 0;

  @override
  Future<RemoteEditorSnapshot?> build() async => null;

  void show(RemotePageSnapshot page, {required int connection}) {
    connections[page] = connection;
    shown++;
    state = AsyncData(
      RemoteEditorSnapshot(
        shell: RemoteStrategyShell(
          header: RemoteStrategyHeader(
            publicId: strategyId,
            name: 'Shell $shown',
            mapData: 'bind',
            revision: 1,
            createdAt: at,
            updatedAt: at,
          ),
          pages: [page.page],
        ),
        activePage: page,
      ),
    );
  }

  @override
  int? connectionOf(RemotePageSnapshot page) => connections[page];
}

class _Repository implements ConvexStrategyRepository {
  final lists = StreamController<RemotePageList>.broadcast();
  var watched = 0;

  @override
  Stream<RemotePageList> watchPageList(
    String strategyPublicId, {
    String? shareToken,
  }) {
    watched++;
    return lists.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _account = StateProvider<String?>((ref) => 'first');
final _connected = StateProvider<bool>((ref) => true);

Future<void> _settled(CloudShadow shadow) async {
  for (var round = 0; round < 3; round++) {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await shadow.idle;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('with the flag off, the driver creates nothing of the shadow', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final log = CloudStoreLog();

    expect(log.isOn(container), isFalse);
    expect(log.drain(container), isEmpty);
    expect(await log.end(container), isEmpty);
    expect(await log.readBack(container), isEmpty);
    expect(container.exists(cloudShadowProvider), isFalse);
  });

  group('through the provider', () {
    late ProviderContainer container;
    late _Queue queue;
    late _Remote remote;
    late _Repository repository;
    late CloudShadow shadow;

    setUp(() async {
      queue = _Queue();
      remote = _Remote();
      repository = _Repository();
      container = ProviderContainer(overrides: [
        strategyOpQueueProvider.overrideWith(() => queue),
        remoteEditorSnapshotProvider.overrideWith(() => remote),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        convexConnectionSnapshotProvider
            .overrideWith((ref) => ref.watch(_connected)),
        strategyOutboxSessionProvider.overrideWith(
          (ref) => StrategyOutboxSession(
            accountId: ref.watch(_account),
            isReady: true,
            hasAuthIncident: false,
          ),
        ),
      ]);
      await container.read(remoteEditorSnapshotProvider.future);
      final opening = await LibraryStore.open(
        MemoryEngine(MemoryStorage()),
        canRead: appCanRead,
        build: 'b',
      ) as StoreOpened;
      await container.read(cloudShadowProvider.notifier).begin(
            opening: Future.value(
              LibraryStoreReady(
                File('unused'),
                opening.store,
                opening.origin,
                opening.foreignNames,
                () async => const Released(),
              ),
            ),
            build: 'b',
          );
      shadow =
          (container.read(cloudShadowProvider) as CloudShadowRunning).shadow;
    });

    tearDown(() => container.dispose());

    List<String> sessions() => [
          for (final report in shadow.reports)
            if (report is ShadowSessionOpened) report.because,
        ];

    test(
        'the page list watch starts after the notification that opened the '
        'strategy, never inside it', () async {
      final rows = serverRows();
      remote.show(pageSnapshot(rows), connection: 0);
      expect(repository.watched, 0);

      await _settled(shadow);
      expect(repository.watched, 1);
    });

    test(
        'a page answered on a new connection opens its session before it is '
        'recorded, though the connection change has not been reported',
        () async {
      final rows = serverRows();
      remote.show(pageSnapshot(rows), connection: 0);
      await _settled(shadow);
      repository.lists.add(pageList(rows));
      await _settled(shadow);

      remote.show(pageSnapshot(rows), connection: 1);
      await _settled(shadow);

      expect(
        [for (final entry in shadow.ledger) entry.verdict],
        everyElement(isA<ComparedEqual>()),
      );
      expect(sessions(), [
        'the strategy was added',
        'the connection came back',
      ]);
    });

    test(
        'signing in as another account with the strategy open opens a new '
        'session for the next result', () async {
      final rows = serverRows();
      remote.show(pageSnapshot(rows), connection: 0);
      await _settled(shadow);
      repository.lists.add(pageList(rows));
      await _settled(shadow);

      container.read(_account.notifier).state = null;
      container.read(_account.notifier).state = 'second';
      remote.show(pageSnapshot(rows), connection: 0);
      await _settled(shadow);

      expect(sessions().last, 'the account changed');
      expect(shadow.ledger.last.verdict, isA<ComparedEqual>());
    });

    test(
        'a dropped connection is recorded, and a result tagged offline is '
        'skipped with its reason', () async {
      final rows = serverRows();
      remote.show(pageSnapshot(rows), connection: 0);
      await _settled(shadow);
      repository.lists.add(pageList(rows));
      await _settled(shadow);

      container.read(_connected.notifier).state = false;
      queue.stamp = null;
      repository.lists.add(pageList(rows));
      await _settled(shadow);

      expect(shadow.reports.whereType<ShadowConnectionLost>(), hasLength(1));
      expect(
        shadow.ledger.last.verdict,
        isA<Skipped>().having(
          (skipped) => skipped.reason,
          'reason',
          SkipReason.receivedOffline,
        ),
      );
    });
  });
}
