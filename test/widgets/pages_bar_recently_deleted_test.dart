import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
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

class _EmptyTrash implements ConvexStrategyRepository {
  final List<String> listed = [];

  @override
  Future<List<TrashedPage>> listTrashedPages(String strategyPublicId) async {
    listed.add(strategyPublicId);
    return const [];
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
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      remoteEditorSnapshotProvider.overrideWith(_Remote.new),
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
      'an editor of a cloud strategy opens Recently deleted from the pages '
      'bar', (tester) async {
    final repository = _EmptyTrash();
    await _expandedBar(tester, canDeletePage: true, repository: repository);

    await tester.tap(find.byIcon(LucideIcons.archiveRestore));
    await tester.pumpAndSettle();

    expect(find.text('No deleted pages.'), findsOneWidget);
    expect(repository.listed, ['strategy-a']);
  });

  testWidgets('someone who cannot delete pages has no Recently deleted',
      (tester) async {
    await _expandedBar(tester, canDeletePage: false);

    expect(find.byIcon(LucideIcons.archiveRestore), findsNothing);
  });
}
