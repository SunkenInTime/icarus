import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/pages_bar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

final _at = DateTime.utc(2026, 9, 29);

RemotePage _page(String id, int sortIndex) => RemotePage(
      publicId: id,
      strategyPublicId: 'strategy-a',
      name: 'Page ${sortIndex + 1}',
      sortIndex: sortIndex,
      isAttack: true,
      revision: 1,
      createdAt: _at,
      updatedAt: _at,
    );

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
          pages: [_page('page-1', 0), _page('page-2', 1)],
        ),
        activePage: null,
      );

  @override
  Future<void> refresh() async {}
}

/// A cloud strategy whose deletes the server accepts.
class _CloudStrategy extends StrategyProvider {
  final List<String> deleted = [];

  @override
  StrategyState build() => const StrategyState(
        strategyId: 'strategy-a',
        strategyName: 'Strategy A',
        source: StrategySource.cloud,
        isOpen: true,
      );

  @override
  Future<bool> deletePage(String pageId) async {
    deleted.add(pageId);
    return true;
  }

  void switchTo(String strategyId) =>
      state = state.copyWith(strategyId: strategyId);
}

class _Session extends StrategyPageSessionNotifier {
  final List<String> restored = [];

  @override
  StrategyPageSessionState build() => const StrategyPageSessionState(
        activePageId: 'page-2',
        availablePageIds: ['page-1', 'page-2'],
        transitionState: PageTransitionState.idle,
        isApplyingPage: false,
      );

  final List<String> opened = [];

  @override
  Future<DeletedPageRestore> restorePageFromTrash(String pageId) async {
    restored.add(pageId);
    return DeletedPageRestore.restored;
  }

  @override
  Future<void> setActivePageAnimated(
    String pageId, {
    required PageTransitionDirection direction,
    Duration duration = Duration.zero,
  }) async =>
      opened.add(pageId);
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

/// Deletes Page 2 from the expanded bar; returns the providers it used.
Future<(_CloudStrategy, _Session, ValueNotifier<bool>)> _deletePage2(
  WidgetTester tester,
) async {
  final strategy = _CloudStrategy();
  final session = _Session();
  final showBar = ValueNotifier(true);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      remoteEditorSnapshotProvider.overrideWith(_Remote.new),
      strategyProvider.overrideWith(() => strategy),
      strategyPageSessionProvider.overrideWith(() => session),
      appPreferencesProvider.overrideWith(_Preferences.new),
      currentStrategyCapabilitiesProvider.overrideWithValue(_caps),
    ],
    child: ToastificationWrapper(
      child: ShadApp(
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder(
              valueListenable: showBar,
              builder: (_, show, __) =>
                  show ? const PagesBar() : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(LucideIcons.chevronDown));
  await tester.pumpAndSettle();
  // The active page's row carries its delete button.
  await tester.tap(find.byIcon(LucideIcons.trash));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('confirm-alert-confirm')));
  await tester.pumpAndSettle();
  expect(strategy.deleted, ['page-2']);
  return (strategy, session, showBar);
}

void main() {
  tearDown(() => toastification.dismissAll(delayForAnimation: false));

  testWidgets('Undo after a cloud delete restores the page, once',
      (tester) async {
    final (_, session, _) = await _deletePage2(tester);
    expect(find.text("Deleted 'Page 2'"), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(session.restored, ['page-2']);
    // It was the page you were on: Undo takes you back.
    expect(session.opened, ['page-2']);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('leaving the strategy takes the Undo offer away', (tester) async {
    final (_, session, showBar) = await _deletePage2(tester);
    expect(find.text('Undo'), findsOneWidget);

    showBar.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
    expect(session.restored, isEmpty);
  });

  testWidgets('Undo does nothing once another strategy is open',
      (tester) async {
    final (strategy, session, _) = await _deletePage2(tester);

    strategy.switchTo('strategy-b');
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(session.restored, isEmpty);
  });
}
