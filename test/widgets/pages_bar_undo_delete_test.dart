import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
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

RemoteEditorSnapshot _snapshot(List<RemotePage> pages) => RemoteEditorSnapshot(
      shell: RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: 'strategy-a',
          name: 'Strategy A',
          mapData: 'ascent',
          revision: 3,
          createdAt: _at,
          updatedAt: _at,
        ),
        pages: pages,
      ),
      activePage: null,
    );

/// The server's pages. A refresh waits on [refreshGate] and then lists
/// [afterRefresh].
class _Remote extends RemoteEditorSnapshotNotifier {
  Completer<void>? refreshGate;
  List<RemotePage> afterRefresh = [_page('page-1', 0), _page('page-2', 1)];

  @override
  Future<RemoteEditorSnapshot?> build() async =>
      _snapshot([_page('page-1', 0), _page('page-2', 1)]);

  @override
  Future<void> refresh() async {
    await refreshGate?.future;
    state = AsyncData(_snapshot(afterRefresh));
  }
}

/// A cloud strategy whose deletes the server accepts, after [deleteGate].
class _CloudStrategy extends StrategyProvider {
  final List<String> deleted = [];
  Completer<void>? deleteGate;

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
    await deleteGate?.future;
    return true;
  }

  void switchTo(String strategyId) =>
      state = state.copyWith(strategyId: strategyId);
}

class _Session extends StrategyPageSessionNotifier {
  final List<String> restored = [];
  final List<String> opened = [];
  bool openFails = false;

  /// A restore waits on this, then answers [restoreOutcome].
  Completer<void>? restoreGate;
  DeletedPageRestore restoreOutcome = DeletedPageRestore.restored;

  /// Runs while a page is opening, before it fails or lands.
  void Function()? duringOpen;

  @override
  StrategyPageSessionState build() => const StrategyPageSessionState(
        activePageId: 'page-2',
        availablePageIds: ['page-1', 'page-2'],
        transitionState: PageTransitionState.idle,
        isApplyingPage: false,
      );

  @override
  Future<DeletedPageRestore> restorePageFromTrash(String pageId) async {
    restored.add(pageId);
    await restoreGate?.future;
    return restoreOutcome;
  }

  @override
  Future<void> setActivePageAnimated(
    String pageId, {
    required PageTransitionDirection direction,
    Duration duration = Duration.zero,
  }) async {
    duringOpen?.call();
    if (openFails) throw StateError('Could not load the page.');
    opened.add(pageId);
  }
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

class _Harness {
  final strategy = _CloudStrategy();
  final session = _Session();
  final remote = _Remote();
  final showBar = ValueNotifier(true);

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        remoteEditorSnapshotProvider.overrideWith(() => remote),
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
  }

  /// Opens Page 2's delete confirmation (the page you are on) and confirms.
  Future<void> confirmDelete(WidgetTester tester) async {
    await tester.tap(find.byIcon(LucideIcons.trash));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-alert-confirm')));
  }
}

Future<_Harness> _deleted(WidgetTester tester) async {
  final harness = _Harness();
  await harness.pump(tester);
  await harness.confirmDelete(tester);
  await tester.pumpAndSettle();
  expect(harness.strategy.deleted, ['page-2']);
  expect(find.text("Deleted 'Page 2'"), findsOneWidget);
  return harness;
}

/// Result toasts close on a timer, which must not outlive the test.
Future<void> _letToastsClose(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => toastification.dismissAll(delayForAnimation: false));

  testWidgets('Undo after a cloud delete restores the page and goes back to it',
      (tester) async {
    final harness = await _deleted(tester);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(harness.session.restored, ['page-2']);
    expect(harness.session.opened, ['page-2']);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('a second tap on Undo restores nothing more', (tester) async {
    final harness = await _deleted(tester);

    await tester.tap(find.text('Undo'));
    await tester.tap(find.text('Undo'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(harness.session.restored, ['page-2']);
  });

  testWidgets('leaving the strategy takes the Undo offer away', (tester) async {
    final harness = await _deleted(tester);

    harness.showBar.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
    expect(harness.session.restored, isEmpty);
  });

  testWidgets('Undo does nothing once another strategy is open',
      (tester) async {
    final harness = await _deleted(tester);

    harness.strategy.switchTo('strategy-b');
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(harness.session.restored, isEmpty);
  });

  testWidgets('switching strategies while the delete lands offers no Undo',
      (tester) async {
    final harness = _Harness();
    harness.strategy.deleteGate = Completer();
    await harness.pump(tester);
    await harness.confirmDelete(tester);
    await tester.pump();

    harness.strategy.switchTo('strategy-b');
    harness.strategy.deleteGate!.complete();
    await tester.pumpAndSettle();
    expect(harness.strategy.deleted, ['page-2']);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('leaving while Undo is refreshing the list is safe',
      (tester) async {
    final harness = await _deleted(tester);
    harness.remote.refreshGate = Completer();

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(harness.session.restored, ['page-2']);
    harness.showBar.value = false;
    await tester.pumpAndSettle();
    harness.remote.refreshGate!.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(harness.session.opened, isEmpty);
  });

  testWidgets('a restore the list does not show yet says only that',
      (tester) async {
    final harness = await _deleted(tester);
    harness.remote.afterRefresh = [_page('page-1', 0)];

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text("Restored 'Page 2'."), findsOneWidget);
    expect(harness.session.opened, isEmpty);
    await _letToastsClose(tester);
  });

  testWidgets('a restored page that will not open says so', (tester) async {
    final harness = await _deleted(tester);
    harness.session.openFails = true;

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(
      find.text("Restored 'Page 2', but could not open it. It is in the "
          'pages list.'),
      findsOneWidget,
    );
    await _letToastsClose(tester);
  });

  testWidgets('switching strategies with the confirmation open deletes nothing',
      (tester) async {
    final harness = _Harness();
    await harness.pump(tester);
    await tester.tap(find.byIcon(LucideIcons.trash));
    await tester.pumpAndSettle();

    harness.strategy.switchTo('strategy-b');
    await tester.tap(find.byKey(const ValueKey('confirm-alert-confirm')));
    await tester.pumpAndSettle();
    expect(harness.strategy.deleted, isEmpty);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('a page deleted again while opening is not claimed as listed',
      (tester) async {
    final harness = await _deleted(tester);
    harness.session
      ..openFails = true
      ..duringOpen = () =>
          harness.remote.state = AsyncData(_snapshot([_page('page-1', 0)]));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(
        find.text("Restored 'Page 2', but could not open it."), findsOneWidget);
    await _letToastsClose(tester);
  });

  testWidgets('a failed restore after leaving names the strategy it was in',
      (tester) async {
    final harness = await _deleted(tester);
    harness.session
      ..restoreGate = Completer()
      ..restoreOutcome = DeletedPageRestore.failed;

    await tester.tap(find.text('Undo'));
    await tester.pump();
    harness.strategy.switchTo('strategy-b');
    harness.session.restoreGate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.text("Could not restore 'Page 2' in Strategy A. It is in that "
          "strategy's Recently deleted for 30 days."),
      findsOneWidget,
    );
    await _letToastsClose(tester);
  });

  testWidgets('a page that can no longer come back says so', (tester) async {
    final harness = await _deleted(tester);
    harness.session.restoreOutcome = DeletedPageRestore.gone;

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text("'Page 2' can no longer be restored."), findsOneWidget);
    await _letToastsClose(tester);
  });

  test('Undo failure messages', () {
    expect(
      undoFailedMessage('Page 2', DeletedPageRestore.failed,
          strategyName: null),
      "Could not restore 'Page 2'. It is in Recently deleted for 30 days.",
    );
    expect(
      undoFailedMessage('Page 2', DeletedPageRestore.failed, strategyName: ''),
      "Could not restore 'Page 2'. It is in its strategy's Recently deleted "
      'for 30 days.',
    );
    expect(
      undoFailedMessage('Page 2', DeletedPageRestore.gone,
          strategyName: 'Strategy A'),
      "'Page 2' can no longer be restored.",
    );
  });
}
