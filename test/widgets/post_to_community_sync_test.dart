import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/community_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/cloud_work_sent.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/dialogs/community/post_to_community_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

const _strategyId = 'source-strategy';
const _postButton = ValueKey('community-post-confirm');
const _updateButton = ValueKey('community-post-update');

void main() {
  group('Post', () {
    testWidgets('waits for an edit still on its way, then posts',
        (tester) async {
      final repository = _Repository();
      final ops = _Ops(_unsent(queued: 1));
      await _openDialog(tester, repository: repository, ops: ops);

      await tester.tap(find.byKey(_postButton));
      await tester.pump(const Duration(seconds: 2));
      expect(repository.published, isEmpty);

      ops.land();
      await tester.pump(const Duration(milliseconds: 200));
      expect(repository.published, [_strategyId]);
    });

    testWidgets('an edit held for review posts nothing and says why',
        (tester) async {
      final repository = _Repository();
      await _openDialog(
        tester,
        repository: repository,
        ops: _Ops(_unsent(paused: 1)),
      );

      await tester.tap(find.byKey(_postButton));
      await tester.pump(const Duration(milliseconds: 200));

      expect(repository.published, isEmpty);
      expect(
        find.text(
          'Some changes to this strategy need your review before they can '
          'sync, so the post would miss them. Open the strategy to review '
          'them, then try again.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<ShadButton>(find.byKey(_postButton)).enabled,
        isTrue,
      );
    });

    testWidgets('a picture that failed to upload posts nothing and says why',
        (tester) async {
      final repository = _Repository();
      await _openDialog(
        tester,
        repository: repository,
        images: [_failedImage],
      );

      await tester.tap(find.byKey(_postButton));
      await tester.pump(const Duration(milliseconds: 200));

      expect(repository.published, isEmpty);
      expect(
        find.text(
          "A picture in this strategy didn't upload, so the post would be "
          'missing it. Open the strategy and choose Retry sync from its '
          'sync button, then try again.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'Cancel mid-wait posts nothing, even when the edit lands as it closes',
        (tester) async {
      final repository = _Repository();
      final ops = _Ops(_unsent(queued: 1));
      await _openDialog(tester, repository: repository, ops: ops);

      await tester.tap(find.byKey(_postButton));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      ops.land();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();

      expect(find.byType(PostToCommunityDialog), findsNothing);
      expect(repository.published, isEmpty);
    });

    testWidgets('another account signing in mid-wait posts nothing',
        (tester) async {
      final repository = _Repository();
      final ops = _Ops(_unsent(queued: 1));
      final auth = _Auth();
      await _openDialog(tester, repository: repository, ops: ops, auth: auth);

      await tester.tap(find.byKey(_postButton));
      await tester.pump(const Duration(milliseconds: 300));
      auth.signInAs('account-b');
      ops.land();
      await tester.pump(const Duration(milliseconds: 200));

      expect(repository.published, isEmpty);
      expect(
        find.text(
          'You signed in to a different account while this was getting '
          'ready, so nothing was sent. Try again.',
        ),
        findsOneWidget,
      );
    });
  });

  group('Update', () {
    testWidgets('an edit that never reaches the server updates nothing',
        (tester) async {
      final repository = _Repository();
      await _openDialog(
        tester,
        repository: repository,
        ops: _Ops(_unsent(queued: 1)),
        posted: true,
      );

      await tester.tap(find.byKey(_updateButton));
      await tester.pump(cloudWorkSendTimeout);
      await tester.pump(const Duration(milliseconds: 200));

      expect(repository.updated, isEmpty);
      expect(
        find.text(
          "Your latest changes haven't reached the server yet, so the post "
          'would miss them. Check your connection, then try again.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<ShadButton>(find.byKey(_updateButton)).enabled,
        isTrue,
      );
    });

    testWidgets('waits for an edit still on its way, then updates',
        (tester) async {
      final repository = _Repository();
      final ops = _Ops(_unsent(queued: 1));
      await _openDialog(tester, repository: repository, ops: ops, posted: true);

      await tester.tap(find.byKey(_updateButton));
      await tester.pump(const Duration(seconds: 2));
      expect(repository.updated, isEmpty);

      ops.land();
      await tester.pump(const Duration(milliseconds: 200));
      expect(repository.updated, [('post-1', refresh: true)]);
    });
  });
}

Future<void> _openDialog(
  WidgetTester tester, {
  required _Repository repository,
  _Ops? ops,
  _Auth? auth,
  List<CloudMediaUploadJob> images = const [],
  bool posted = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth ?? _Auth()),
        strategyProvider.overrideWith(_ClosedStrategy.new),
        strategyOpQueueProvider.overrideWith(
          () => ops ?? _Ops(const StrategyOpQueueState(durableLoaded: true)),
        ),
        cloudMediaUploadQueueProvider.overrideWith(() => _Images(images)),
        communityRepositoryProvider.overrideWithValue(repository),
        communityFeedProvider.overrideWith(_Feed.new),
        communityViewerProvider.overrideWith(
          (ref) async => (isReviewer: false, canPost: true, authorName: 'Ash'),
        ),
        myCommunityPostsProvider.overrideWith(
          (ref) => Stream.value(posted ? [_mine] : const <MyCommunityPost>[]),
        ),
      ],
      child: ShadApp(
        builder: (context, app) => MediaQuery.withClampedTextScaling(
          maxScaleFactor: 0.5,
          child: app!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => ShadButton(
              onPressed: () => showPostToCommunityDialog(context, _strategyId),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(find.byKey(posted ? _updateButton : _postButton), findsOneWidget);
}

final _post = CommunityPost(
  publicId: 'post-1',
  title: 'A site execute',
  map: MapValue.ascent,
  side: CommunitySide.attack,
  agents: const [],
  authorName: 'Ash',
  authorAvatarUrl: null,
  starCount: 0,
  pageCount: 1,
  lineupCount: 0,
  publishedAt: DateTime.utc(2026, 11),
  strategyPublicId: 'post-copy',
  shareToken: 'token',
);

final MyCommunityPost _mine = (
  post: _post,
  status: CommunityPostStatus.listed,
  sourceStrategyPublicId: _strategyId,
  copyCount: 0,
  updatedAt: DateTime.utc(2026, 11),
);

final _failedImage = CloudMediaUploadJob(
  jobId: 'job-1',
  accountId: 'account-a',
  strategyPublicId: _strategyId,
  assetPublicId: 'image-1',
  fileExtension: '.png',
  mimeType: 'image/png',
  state: CloudMediaJobState.failed,
  attempts: 3,
  updatedAt: DateTime.utc(2026),
);

class _Repository extends CommunityRepository {
  _Repository() : super(IcarusConvexApi(_NoTransport()));

  final published = <String>[];
  final updated = <(String, {bool refresh})>[];

  @override
  Future<CommunityPostPreview?> fetchPostPreview(
    String strategyPublicId,
  ) async =>
      (
        name: 'A site execute',
        map: MapValue.ascent,
        side: CommunitySide.attack,
        agents: const <AgentType>[],
      );

  @override
  Future<bool?> fetchSourceChanged(String postPublicId) async => true;

  @override
  Future<String> publish({
    required String postPublicId,
    required String strategyPublicId,
    required String title,
  }) async {
    published.add(strategyPublicId);
    return postPublicId;
  }

  @override
  Future<void> updatePost({
    required String postPublicId,
    String? title,
    bool refresh = false,
  }) async {
    updated.add((postPublicId, refresh: refresh));
  }
}

class _NoTransport implements ConvexTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Feed extends CommunityFeedNotifier {
  @override
  CommunityFeedState build() =>
      const CommunityFeedState(filter: CommunityFilter());

  @override
  Future<void> readAgain() async {}
}

class _ClosedStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: null,
        strategyName: null,
        source: StrategySource.local,
        isOpen: false,
      );
}

class _Images extends CloudMediaUploadQueueNotifier {
  _Images(this.jobs);

  final List<CloudMediaUploadJob> jobs;

  @override
  CloudMediaUploadQueueState build() =>
      CloudMediaUploadQueueState(jobs: jobs, isProcessing: false);
}

class _Auth extends AuthProvider {
  @override
  AppAuthState build() => _signedInAs('account-a');

  void signInAs(String accountId) => state = _signedInAs(accountId);
}

AppAuthState _signedInAs(String accountId) => AppAuthState(
      isLoading: false,
      isAuthenticated: true,
      isConvexUserReady: true,
      convexAuthStatus: ConvexAuthStatus.ready,
      user: User(
        id: accountId,
        appMetadata: const <String, dynamic>{},
        userMetadata: const <String, dynamic>{},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00.000Z',
      ),
    );

class _Ops extends StrategyOpQueueNotifier {
  _Ops(this.initial);

  final StrategyOpQueueState initial;

  @override
  StrategyOpQueueState build() => initial;

  void land() => state = const StrategyOpQueueState(durableLoaded: true);
}

StrategyOpQueueState _unsent({int queued = 0, int paused = 0}) =>
    StrategyOpQueueState(
      durableLoaded: true,
      accountOutbox: AccountStrategyOutboxSummary(
        strategies: {
          _strategyId: StrategyOutboxSummary(
            strategyPublicId: _strategyId,
            queuedCount: queued,
            inFlightCount: 0,
            pausedCount: paused,
            attentionCount: 0,
            successorCount: 0,
          ),
        },
      ),
    );
