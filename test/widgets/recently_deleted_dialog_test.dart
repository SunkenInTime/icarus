import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/widgets/dialogs/recently_deleted_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

final _now = DateTime.now();

TrashedPage _trashed(
  String pageId,
  String name, {
  Duration ago = const Duration(days: 2),
  String? by,
  bool byYou = false,
}) =>
    TrashedPage(
      pageId: pageId,
      name: name,
      deletedAt: _now.subtract(ago),
      restorableUntil: _now.subtract(ago).add(const Duration(days: 30)),
      deletedByName: by,
      deletedByYou: byYou,
    );

/// Serves [pages] as the server's trash, or fails while [offline].
class _TrashRepository implements ConvexStrategyRepository {
  _TrashRepository(this.pages);

  List<TrashedPage> pages;
  bool offline = false;
  final List<String> listed = [];

  @override
  Future<List<TrashedPage>> listTrashedPages(String strategyPublicId) async {
    listed.add(strategyPublicId);
    if (offline) throw StateError('Cloud connection is offline.');
    return pages;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Answers each restore with the next of [outcomes], once [gate] opens.
class _Session extends StrategyPageSessionNotifier {
  _Session(this.outcomes);

  final List<DeletedPageRestore> outcomes;
  final List<String> restored = [];
  Completer<void>? gate;

  @override
  StrategyPageSessionState build() => const StrategyPageSessionState(
        activePageId: 'page-2',
        availablePageIds: ['page-2'],
        transitionState: PageTransitionState.idle,
        isApplyingPage: false,
      );

  @override
  Future<DeletedPageRestore> restorePageFromTrash(String pageId) async {
    restored.add(pageId);
    await gate?.future;
    return outcomes.removeAt(0);
  }
}

Future<void> _open(
  WidgetTester tester,
  _TrashRepository repository,
  _Session session,
) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      strategyPageSessionProvider.overrideWith(() => session),
    ],
    child: ShadApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ShadButton(
              onPressed: () =>
                  RecentlyDeletedDialog.show(context, 'strategy-a'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('labels', () {
    final now = DateTime(2026, 9, 29, 12);
    TrashedPage page({String? by, bool byYou = false, Duration? ago}) =>
        TrashedPage(
          pageId: 'p',
          name: 'A exec',
          deletedAt: now.subtract(ago ?? const Duration(days: 2)),
          restorableUntil: now
              .subtract(ago ?? const Duration(days: 2))
              .add(const Duration(days: 30)),
          deletedByName: by,
          deletedByYou: byYou,
        );

    test('say who deleted the page and when, if known', () {
      expect(deletedLabel(page(by: 'Sam'), now), 'Deleted by Sam, 2 days ago');
      expect(
        deletedLabel(
            page(by: 'Sam', byYou: true, ago: const Duration(minutes: 5)), now),
        'Deleted by you, 5 minutes ago',
      );
      expect(
        deletedLabel(page(ago: const Duration(hours: 1)), now),
        'Deleted 1 hour ago',
      );
      expect(deletedLabel(page(ago: Duration.zero), now), 'Deleted just now');
    });

    test('count the days left', () {
      expect(timeLeftLabel(page(), now), '28 days left');
      expect(
        timeLeftLabel(page(ago: const Duration(days: 28, hours: 12)), now),
        '1 day left',
      );
      expect(
        timeLeftLabel(page(ago: const Duration(days: 29, hours: 12)), now),
        'Less than a day left',
      );
    });
  });

  testWidgets('lists the deleted pages with who deleted each and when',
      (tester) async {
    final repository = _TrashRepository([
      _trashed('page-3', 'Retake', ago: const Duration(hours: 3), by: 'Sam'),
      // Off a day boundary, as the list reads the clock a moment later.
      _trashed('page-1', 'A exec', ago: const Duration(hours: 47)),
    ]);
    await _open(tester, repository, _Session([]));

    expect(repository.listed, ['strategy-a']);
    expect(find.text('Recently deleted'), findsOneWidget);
    expect(find.text('Retake'), findsOneWidget);
    expect(find.text('Deleted by Sam, 3 hours ago · 29 days left'),
        findsOneWidget);
    expect(find.text('A exec'), findsOneWidget);
    expect(find.text('Deleted 1 day ago · 28 days left'), findsOneWidget);
    expect(find.text('Restore'), findsNWidgets(2));
  });

  testWidgets('says when nothing was deleted', (tester) async {
    await _open(tester, _TrashRepository([]), _Session([]));

    expect(find.text('No deleted pages.'), findsOneWidget);
    expect(find.text('Restore'), findsNothing);
  });

  testWidgets('says when the list cannot load, and tries again',
      (tester) async {
    final repository = _TrashRepository([_trashed('page-1', 'A exec')])
      ..offline = true;
    await _open(tester, repository, _Session([]));

    expect(
      find.text('Could not load deleted pages. Check your connection and try '
          'again.'),
      findsOneWidget,
    );
    repository.offline = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('A exec'), findsOneWidget);
  });

  testWidgets('restoring a page takes it off the list', (tester) async {
    final session = _Session([DeletedPageRestore.restored])
      ..gate = Completer<void>();
    await _open(
      tester,
      _TrashRepository([
        _trashed('page-3', 'Retake'),
        _trashed('page-1', 'A exec'),
      ]),
      session,
    );

    await tester.tap(find.text('Restore').last);
    await tester.pump();
    expect(find.text('Restoring…'), findsOneWidget);
    session.gate!.complete();
    await tester.pumpAndSettle();

    expect(session.restored, ['page-1']);
    expect(find.text('A exec'), findsNothing);
    expect(find.text('Retake'), findsOneWidget);
  });

  testWidgets('a failed restore says so and can be tried again',
      (tester) async {
    final session =
        _Session([DeletedPageRestore.failed, DeletedPageRestore.restored]);
    await _open(
        tester, _TrashRepository([_trashed('page-1', 'A exec')]), session);

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not restore it. Check your connection and try again.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(session.restored, ['page-1', 'page-1']);
    expect(find.text('No deleted pages.'), findsOneWidget);
  });

  testWidgets('a page past its time says it can no longer be restored',
      (tester) async {
    final session = _Session([DeletedPageRestore.gone]);
    await _open(
        tester, _TrashRepository([_trashed('page-1', 'A exec')]), session);

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.text('It can no longer be restored.'), findsOneWidget);
    expect(find.text('Restore'), findsNothing);
  });

  testWidgets(
      'a page whose time ran out while the list was open offers no Restore',
      (tester) async {
    final session = _Session([]);
    await _open(
      tester,
      _TrashRepository([
        _trashed('page-1', 'A exec', ago: const Duration(days: 30, minutes: 1)),
      ]),
      session,
    );

    expect(find.text('It can no longer be restored.'), findsOneWidget);
    expect(find.text('Deleted 30 days ago'), findsOneWidget);
    expect(find.text('Restore'), findsNothing);
  });

  testWidgets("Restore goes away when a page's time runs out while it is open",
      (tester) async {
    final deletedAt = clock.now().subtract(const Duration(days: 30));
    await _open(
      tester,
      _TrashRepository([
        TrashedPage(
          pageId: 'page-1',
          name: 'A exec',
          deletedAt: deletedAt,
          restorableUntil: clock.now().add(const Duration(seconds: 30)),
          deletedByName: null,
          deletedByYou: false,
        ),
      ]),
      _Session([]),
    );
    expect(find.text('Restore'), findsOneWidget);

    await tester.pump(const Duration(minutes: 1));

    expect(find.text('Restore'), findsNothing);
    expect(find.text('It can no longer be restored.'), findsOneWidget);
  });
}
