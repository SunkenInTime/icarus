import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/trashed_pages_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/pages_bar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
  /// The strategy's revision moves, as a delete or restore moves it.
  void moveRevision(int revision) => state = AsyncData(RemoteEditorSnapshot(
        shell: RemoteStrategyShell(
          header: RemoteStrategyHeader(
            publicId: 'strategy-a',
            name: 'Strategy A',
            mapData: 'ascent',
            revision: revision,
            createdAt: _at,
            updatedAt: _at,
          ),
          pages: [_page('page-1', 0), _page('page-2', 1)],
        ),
        activePage: null,
      ));

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
        availablePageIds: ['page-1', 'page-2'],
        transitionState: PageTransitionState.idle,
        isApplyingPage: false,
      );
}

class _Preferences extends AppPreferencesNotifier {
  @override
  AppPreferences build() =>
      AppPreferences(defaultThemeProfileIdForNewStrategies: 'default');
}

/// Serves [pages] as the strategy's trash.
class _Trash implements ConvexStrategyRepository {
  _Trash([this.pages = const []]);

  List<TrashedPage> pages;
  final List<String> listed = [];

  /// Reads fail while set, as offline.
  bool offline = false;

  @override
  Future<List<TrashedPage>> listTrashedPages(String strategyPublicId) async {
    listed.add(strategyPublicId);
    if (offline) throw StateError('Cloud connection is offline.');
    return pages;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

StrategyCapabilities _caps({required bool canDeletePage}) =>
    StrategyCapabilities(
      canRenameStrategy: false,
      canDeleteStrategy: false,
      canDuplicateStrategy: false,
      canMoveStrategy: false,
      canEditPages: canDeletePage,
      canAddPage: canDeletePage,
      canRenamePage: canDeletePage,
      canDeletePage: canDeletePage,
      canReorderPages: canDeletePage,
      canCreateFolder: false,
      canEditFolder: false,
      canDeleteFolder: false,
      canMoveFolder: false,
    );

Future<void> _expandedBar(
  WidgetTester tester, {
  required bool canDeletePage,
  ConvexStrategyRepository? repository,
  _Remote? remote,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      remoteEditorSnapshotProvider.overrideWith(() => remote ?? _Remote()),
      strategyProvider.overrideWith(_CloudStrategy.new),
      strategyPageSessionProvider.overrideWith(_Session.new),
      appPreferencesProvider.overrideWith(_Preferences.new),
      currentStrategyCapabilitiesProvider
          .overrideWithValue(_caps(canDeletePage: canDeletePage)),
      if (repository != null)
        convexStrategyRepositoryProvider.overrideWithValue(repository),
    ],
    child: const ShadApp(
      home: Scaffold(body: Center(child: PagesBar())),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(LucideIcons.chevronDown));
  await tester.pumpAndSettle();
  expect(find.text('Page 2'), findsOneWidget);
}

void main() {
  testWidgets(
      'an editor opens Recently deleted from the pages bar when it has pages',
      (tester) async {
    final repository = _Trash([
      TrashedPage(
        pageId: 'page-3',
        name: 'Retake B',
        deletedAt: _at,
        restorableUntil: _at.add(const Duration(days: 30)),
        deletedByName: 'Sam',
        deletedByYou: false,
      ),
    ]);
    await _expandedBar(tester, canDeletePage: true, repository: repository);

    await tester.tap(find.byIcon(LucideIcons.archiveRestore));
    await tester.pumpAndSettle();

    expect(find.text('Retake B'), findsOneWidget);
  });

  testWidgets('an empty trash shows no Recently deleted button',
      (tester) async {
    final repository = _Trash();
    await _expandedBar(tester, canDeletePage: true, repository: repository);

    expect(repository.listed, ['strategy-a']);
    expect(find.byIcon(LucideIcons.archiveRestore), findsNothing);
  });

  testWidgets('someone who cannot delete pages has no Recently deleted',
      (tester) async {
    await _expandedBar(tester, canDeletePage: false);

    expect(find.byIcon(LucideIcons.archiveRestore), findsNothing);
  });

  testWidgets(
      'the button comes with the first deleted page and goes with the '
      'last', (tester) async {
    final repository = _Trash();
    final remote = _Remote();
    await _expandedBar(tester,
        canDeletePage: true, repository: repository, remote: remote);
    expect(find.byIcon(LucideIcons.archiveRestore), findsNothing);

    repository.pages = [
      TrashedPage(
        pageId: 'page-3',
        name: 'Retake B',
        deletedAt: _at,
        restorableUntil: _at.add(const Duration(days: 30)),
        deletedByName: null,
        deletedByYou: true,
      ),
    ];
    remote.moveRevision(4);
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.archiveRestore), findsOneWidget);

    repository.pages = [];
    remote.moveRevision(5);
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.archiveRestore), findsNothing);
  });

  testWidgets('a failed read is tried again, so the button comes back online',
      (tester) async {
    final repository = _Trash([
      TrashedPage(
        pageId: 'page-3',
        name: 'Retake B',
        deletedAt: _at,
        restorableUntil: _at.add(const Duration(days: 30)),
        deletedByName: 'Sam',
        deletedByYou: false,
      ),
    ])
      ..offline = true;
    await _expandedBar(tester, canDeletePage: true, repository: repository);
    expect(find.byIcon(LucideIcons.archiveRestore), findsNothing);

    // Back online; nothing about the strategy changed.
    repository.offline = false;
    await tester.pump(trashRecheckDelay);
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.archiveRestore), findsOneWidget);
  });

  testWidgets("the button goes when the last page's 30 days run out",
      (tester) async {
    final soon = DateTime.now().add(const Duration(minutes: 1));
    final repository = _Trash([
      TrashedPage(
        pageId: 'page-3',
        name: 'Retake B',
        deletedAt: soon.subtract(const Duration(days: 30)),
        restorableUntil: soon,
        deletedByName: 'Sam',
        deletedByYou: false,
      ),
    ]);
    await _expandedBar(tester, canDeletePage: true, repository: repository);
    expect(find.byIcon(LucideIcons.archiveRestore), findsOneWidget);

    // The server lists only restorable pages; once past, it lists none.
    repository.pages = [];
    await tester.pump(const Duration(minutes: 1, seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.archiveRestore), findsNothing);
  });
}
