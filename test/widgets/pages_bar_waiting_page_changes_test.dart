import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/pages_bar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

final _at = DateTime.utc(2026, 10, 18);

RemotePage _page(String id, int sortIndex) => RemotePage(
      publicId: id,
      strategyPublicId: 'strategy-a',
      name: 'Page ${sortIndex + 1}',
      isAutoNamed: true,
      sortIndex: sortIndex,
      isAttack: true,
      revision: 1,
      createdAt: _at,
      updatedAt: _at,
    );

/// The server's pages as last read; offline, they stay as they were.
class _Remote extends RemoteEditorSnapshotNotifier {
  @override
  Future<RemoteEditorSnapshot?> build() async => RemoteEditorSnapshot(
        shell: RemoteStrategyShell(
          header: RemoteStrategyHeader(
            publicId: 'strategy-a',
            name: 'Strategy A',
            mapData: 'ascent',
            revision: 3,
            createdAt: _at,
            updatedAt: _at,
          ),
          pages: [_page('page-1', 0), _page('page-2', 1), _page('page-3', 2)],
        ),
        activePage: null,
      );
}

class _CloudStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'strategy-a',
        strategyName: 'Strategy A',
        source: StrategySource.cloud,
        isOpen: true,
      );
}

class _Session extends StrategyPageSessionNotifier {
  @override
  StrategyPageSessionState build() => const StrategyPageSessionState(
        activePageId: 'page-1',
        availablePageIds: ['page-1', 'page-2', 'page-3'],
        transitionState: PageTransitionState.idle,
        isApplyingPage: false,
      );
}

class _Preferences extends AppPreferencesNotifier {
  @override
  AppPreferences build() =>
      AppPreferences(defaultThemeProfileIdForNewStrategies: 'default');
}

const _caps = StrategyCapabilities(
  canRenameStrategy: false,
  canDeleteStrategy: false,
  canDuplicateStrategy: false,
  canMoveStrategy: false,
  canEditPages: true,
  canAddPage: true,
  canRenamePage: true,
  canDeletePage: true,
  canReorderPages: true,
  canCreateFolder: false,
  canEditFolder: false,
  canDeleteFolder: false,
  canMoveFolder: false,
);

void main() {
  tearDown(() => toastification.dismissAll(delayForAnimation: false));

  testWidgets(
      'the pages bar shows a rename, a move and a delete still waiting to '
      'be sent', (tester) async {
    final store = MemoryDurableStrategyOutboxStore();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        remoteEditorSnapshotProvider.overrideWith(_Remote.new),
        durableStrategyOutboxStoreProvider.overrideWithValue(store),
        strategyOutboxSessionProvider.overrideWithValue(
          const StrategyOutboxSession(
            accountId: null,
            isReady: false,
            hasAuthIncident: false,
          ),
        ),
        strategyProvider.overrideWith(_CloudStrategy.new),
        strategyPageSessionProvider.overrideWith(_Session.new),
        appPreferencesProvider.overrideWith(_Preferences.new),
        currentStrategyCapabilitiesProvider.overrideWithValue(_caps),
      ],
      child: ToastificationWrapper(
        child: ShadApp(
          home: Scaffold(body: Center(child: const PagesBar())),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.chevronDown));
    await tester.pumpAndSettle();
    expect(find.text('Page 3'), findsOneWidget);

    // Made offline: the queue holds them, and nothing reaches the server.
    final container =
        ProviderScope.containerOf(tester.element(find.byType(PagesBar)));
    final queue = container.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('strategy-a', accountId: 'account-a');
    await tester.runAsync(() async {
      await queue.enqueue(const PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-2',
        payload: {'name': 'Retake', 'isAutoNamed': false},
        expectedPageRevision: 1,
      ));
      await queue.enqueue(const PageReorderOp(
        opId: 'move',
        pagePublicId: 'page-3',
        sortIndex: 0,
        expectedStrategyRevision: 3,
      ));
      await queue.enqueue(const PageDeleteOp(
        opId: 'delete',
        pagePublicId: 'page-1',
        expectedStrategyRevision: 3,
      ));
    });
    await tester.pumpAndSettle();

    // [1, 2, 3] -> 2 renamed -> 3 moved first: [3, 1, 2] -> 1 deleted.
    final retake = find.text('Retake');
    final moved = find.text('Page 1');
    expect(retake, findsOneWidget);
    expect(moved, findsOneWidget);
    expect(find.text('Page 2'), findsNothing);
    expect(find.text('Page 3'), findsNothing);
    expect(
      tester.getTopLeft(moved).dy,
      lessThan(tester.getTopLeft(retake).dy),
    );
  });
}
