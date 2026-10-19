import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

final _at = DateTime.utc(2026);

RemotePage _page(String id, int index) => RemotePage(
      publicId: id,
      strategyPublicId: 'cloud-strategy',
      name: 'Page ${index + 1}',
      isAutoNamed: true,
      sortIndex: index,
      isAttack: true,
      revision: 1,
      createdAt: _at,
      updatedAt: _at,
    );

RemotePageSnapshot _read(RemotePage page) => RemotePageSnapshot(
      page: page,
      content: RemotePageContent(
        settings: const {},
        revision: 1,
        createdAt: _at,
        updatedAt: _at,
      ),
      elements: const [],
      lineups: const [],
      assetsById: const {},
    );

final _pageOne = _page('page-1', 0);
final _pageTwo = _page('page-2', 1);
final _pageThree = _page('page-3', 2);

/// The server's pages as last read, with page 1 on screen. Offline: no
/// other page can be read.
class _OfflineRemote extends RemoteEditorSnapshotNotifier {
  @override
  Future<RemoteEditorSnapshot?> build() async => RemoteEditorSnapshot(
        shell: RemoteStrategyShell(
          header: RemoteStrategyHeader(
            publicId: 'cloud-strategy',
            name: 'Cloud Strategy',
            mapData: Maps.mapNames[MapValue.ascent]!,
            revision: 3,
            createdAt: _at,
            updatedAt: _at,
          ),
          pages: [_pageOne, _pageTwo, _pageThree],
        ),
        activePage: _read(_pageOne),
      );

  @override
  Future<RemotePageSnapshot> fetchPage(String pagePublicId) async =>
      throw StateError('offline');
}

/// A queue holding a move made offline: page 3 to the top, which renumbers
/// the automatically named pages, so the pages bar shows page 2 as
/// "Page 3".
class _MoveWaitingQueue extends StrategyOpQueueNotifier {
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
  Future<void> syncDesiredOpsForPage({
    required String pageId,
    required Map<EntitySyncKey, StrategyOp> desiredOpsByEntityKey,
    bool clearMissing = true,
    bool flushImmediately = false,
    int? madeLive,
  }) async {}

  @override
  Future<void> flushNow() async {}

  @override
  List<StrategyOp> pageChangesToDraw(RemoteEditorSnapshot snapshot) => [
        PageReorderOp(
          opId: 'move-offline',
          pagePublicId: _pageThree.publicId,
          sortIndex: 0,
          expectedStrategyRevision: 3,
        ),
      ];
}

void main() {
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  testWidgets(
      "a page that can't be read is named as the pages bar shows it, with a "
      'move still waiting to be sent', (tester) async {
    final container = ProviderContainer(overrides: [
      remoteEditorSnapshotProvider.overrideWith(_OfflineRemote.new),
      strategyOpQueueProvider.overrideWith(_MoveWaitingQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue('account-a'),
      cloudCopyScopeProvider.overrideWithValue(null),
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
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ToastificationWrapper(
        child: ShadApp(home: Scaffold(body: SizedBox.expand())),
      ),
    ));
    final session = container.read(strategyPageSessionProvider.notifier);
    await tester.runAsync(() async {
      await container.read(remoteEditorSnapshotProvider.future);
      await session.initializeForStrategy(
        strategyId: 'cloud-strategy',
        source: StrategySource.cloud,
        selectFirstPageIfNeeded: true,
      );
      await session.setActivePage(_pageTwo.publicId);
    });

    // The toast comes in over a few frames.
    final seen = <String?>{};
    for (var round = 0; round < 30; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      seen.addAll(
          tester.widgetList<Text>(find.byType(Text)).map((t) => t.data));
    }

    expect(
      seen,
      contains("Couldn't open Page 3. Check your connection and try again."),
    );
    expect(seen.where((text) => text?.contains('Page 2') ?? false), isEmpty);
    expect(
      container.read(strategyPageSessionProvider).activePageId,
      _pageOne.publicId,
    );
    // The toast closes on its own.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
