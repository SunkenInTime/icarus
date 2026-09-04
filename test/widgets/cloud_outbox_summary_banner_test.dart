import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/widgets/cloud_outbox_summary_banner.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('closed-strategy attention is visible with no editor open',
      (tester) async {
    String? openedStrategy;
    final container = _container(
      queue: const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: null,
        durableLoaded: true,
        accountOutbox: AccountStrategyOutboxSummary(
          accountId: 'account-a',
          strategies: {
            'strategy-needs-review': StrategyOutboxSummary(
              strategyPublicId: 'strategy-needs-review',
              queuedCount: 0,
              inFlightCount: 0,
              pausedCount: 1,
              attentionCount: 0,
              successorCount: 0,
              reason: 'ClientException: socket failed, bearer=secret',
            ),
          },
        ),
      ),
    );
    addTearDown(container.dispose);

    await _pump(
      tester,
      container,
      CloudOutboxSummaryBanner(
        onOpenStrategy: (id) => openedStrategy = id,
      ),
    );

    expect(find.byKey(const ValueKey('cloud-outbox-summary')), findsOneWidget);
    expect(find.text('Cloud work needs attention'), findsOneWidget);
    expect(find.textContaining('Haven retake'), findsOneWidget);
    expect(find.text('Haven retake: review sync'), findsOneWidget);
    expect(find.textContaining('ClientException'), findsNothing);
    expect(find.textContaining('bearer=secret'), findsNothing);
    await tester.tap(find.textContaining('Haven retake'));
    expect(openedStrategy, 'strategy-needs-review');
  });

  testWidgets('queued closed-strategy work is visible while offline',
      (tester) async {
    final container = _container(
      connected: false,
      queue: const StrategyOpQueueState(
        accountId: 'account-a',
        durableLoaded: true,
        accountOutbox: AccountStrategyOutboxSummary(
          accountId: 'account-a',
          strategies: {
            'closed': StrategyOutboxSummary(
              strategyPublicId: 'closed',
              queuedCount: 2,
              inFlightCount: 0,
              pausedCount: 0,
              attentionCount: 0,
              successorCount: 0,
            ),
          },
        ),
      ),
    );
    addTearDown(container.dispose);
    await _pump(tester, container, const CloudOutboxSummaryBanner());
    await tester.pump();

    expect(find.text('Working offline'), findsOneWidget);
    expect(find.textContaining('2 saved changes'), findsOneWidget);
    expect(find.textContaining('waiting on this device'), findsOneWidget);
  });

  testWidgets('pending shared-strategy work is visible in Shared With Me',
      (tester) async {
    final container = _container(
      section: CloudLibrarySection.sharedWithMe,
      queue: const StrategyOpQueueState(
        accountId: 'account-a',
        durableLoaded: true,
        accountOutbox: AccountStrategyOutboxSummary(
          accountId: 'account-a',
          strategies: {
            'shared-strategy': StrategyOutboxSummary(
              strategyPublicId: 'shared-strategy',
              queuedCount: 1,
              inFlightCount: 0,
              pausedCount: 0,
              attentionCount: 0,
              successorCount: 0,
            ),
          },
        ),
      ),
    );
    addTearDown(container.dispose);
    await _pump(tester, container, const CloudOutboxSummaryBanner());

    expect(find.byKey(const ValueKey('cloud-outbox-summary')), findsOneWidget);
    expect(find.text('Syncing cloud work'), findsOneWidget);
    expect(find.textContaining('1 saved change'), findsOneWidget);
  });

  testWidgets('another account work is absent from this account library',
      (tester) async {
    final container = _container(
      queue: const StrategyOpQueueState(
        accountId: 'account-b',
        durableLoaded: true,
        accountOutbox: AccountStrategyOutboxSummary(accountId: 'account-b'),
      ),
    );
    addTearDown(container.dispose);
    await _pump(tester, container, const CloudOutboxSummaryBanner());

    expect(
      find.byKey(const ValueKey('cloud-outbox-summary')),
      findsNothing,
    );
  });

  testWidgets('outbox banner stays absent from the local workspace',
      (tester) async {
    final container = _container(
      workspace: LibraryWorkspace.local,
      queue: const StrategyOpQueueState(
        accountId: 'account-a',
        durableLoaded: true,
        accountOutbox: AccountStrategyOutboxSummary(
          accountId: 'account-a',
          strategies: {
            'closed': StrategyOutboxSummary(
              strategyPublicId: 'closed',
              queuedCount: 1,
              inFlightCount: 0,
              pausedCount: 0,
              attentionCount: 0,
              successorCount: 0,
            ),
          },
        ),
      ),
    );
    addTearDown(container.dispose);
    await _pump(tester, container, const CloudOutboxSummaryBanner());

    expect(
      find.byKey(const ValueKey('cloud-outbox-summary')),
      findsNothing,
    );
  });

  testWidgets('auth-paused work shows the reason instead of syncing',
      (tester) async {
    final container = _container(
      authReady: false,
      queue: const StrategyOpQueueState(
        accountId: 'account-a',
        durableLoaded: true,
        accountOutbox: AccountStrategyOutboxSummary(
          accountId: 'account-a',
          strategies: {
            'closed': StrategyOutboxSummary(
              strategyPublicId: 'closed',
              queuedCount: 1,
              inFlightCount: 0,
              pausedCount: 0,
              attentionCount: 0,
              successorCount: 0,
            ),
          },
        ),
      ),
    );
    addTearDown(container.dispose);
    await _pump(tester, container, const CloudOutboxSummaryBanner());

    expect(find.text('Cloud work needs attention'), findsOneWidget);
    expect(find.textContaining('authentication is paused'), findsOneWidget);
    expect(find.text('Syncing cloud work'), findsNothing);
  });
}

ProviderContainer _container({
  required StrategyOpQueueState queue,
  LibraryWorkspace workspace = LibraryWorkspace.cloud,
  CloudLibrarySection section = CloudLibrarySection.home,
  bool connected = true,
  bool authReady = true,
}) {
  return ProviderContainer(overrides: [
    authProvider.overrideWith(() => _ReadyAuth(authReady)),
    libraryWorkspaceProvider.overrideWith(() => _Workspace(workspace)),
    cloudLibrarySectionProvider.overrideWith(() => _CloudSection(section)),
    strategyOpQueueProvider.overrideWith(() => _Queue(queue)),
    cloudMediaUploadQueueProvider.overrideWith(_MediaQueue.new),
    convexConnectionProvider.overrideWith((ref) => Stream.value(connected)),
    cloudStrategyNamesProvider.overrideWithValue(const {
      'strategy-needs-review': 'Haven retake',
    }),
  ]);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget banner,
) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ShadApp(home: Scaffold(body: banner)),
    ),
  );
}

class _Workspace extends LibraryWorkspaceNotifier {
  _Workspace(this.workspace);

  final LibraryWorkspace workspace;

  @override
  LibraryWorkspace build() => workspace;
}

class _CloudSection extends CloudLibrarySectionNotifier {
  _CloudSection(this.section);

  final CloudLibrarySection section;

  @override
  CloudLibrarySection build() => section;
}

class _ReadyAuth extends AuthProvider {
  _ReadyAuth(this.ready);

  final bool ready;

  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: ready,
        convexAuthStatus:
            ready ? ConvexAuthStatus.ready : ConvexAuthStatus.incident,
        user: const User(
          id: 'account-a',
          appMetadata: <String, dynamic>{},
          userMetadata: <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _Queue extends StrategyOpQueueNotifier {
  _Queue(this.initialState);

  final StrategyOpQueueState initialState;

  @override
  StrategyOpQueueState build() => initialState;
}

class _MediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() => const CloudMediaUploadQueueState(
        jobs: [],
        isProcessing: false,
      );
}
