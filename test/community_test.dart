import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/community_provider.dart';
import 'package:icarus/widgets/community/community_link.dart';

CommunityPost _post({String id = 'post-1', int starCount = 10}) =>
    CommunityPost(
      publicId: id,
      title: 'B Market Execute',
      map: MapValue.ascent,
      side: CommunitySide.attack,
      agents: const [AgentType.jett],
      authorName: 'kairo',
      authorAvatarUrl: null,
      starCount: starCount,
      pageCount: 1,
      lineupCount: 0,
      publishedAt: DateTime(2026, 11, 1),
      strategyPublicId: 'snapshot-1',
      shareToken: 'community-token',
    );

void main() {
  group('a Community link', () {
    final web = Uri.parse('http://localhost:8080/');
    String? idOf(String link) =>
        communityPostIdFromUri(Uri.parse(link), currentOrigin: web);

    test('names its post on the site, the app scheme and this page', () {
      expect(idOf('https://icarusstrats.com/community/abcd-1234'), 'abcd-1234');
      expect(
        idOf('https://www.icarusstrats.com/community/abcd-1234/'),
        'abcd-1234',
      );
      expect(idOf('icarus://community/abcd-1234'), 'abcd-1234');
      expect(idOf('http://localhost:8080/community/abcd-1234'), 'abcd-1234');
    });

    test('is not any other address', () {
      expect(idOf('https://example.com/community/abcd-1234'), isNull);
      expect(idOf('https://icarusstrats.com/share/abcd-1234'), isNull);
      expect(idOf('https://icarusstrats.com/community/'), isNull);
      expect(idOf('https://icarusstrats.com/community/a/b'), isNull);
      // Too short to be a post id, or not one at all.
      expect(idOf('https://icarusstrats.com/community/abc'), isNull);
      expect(idOf('https://icarusstrats.com/community/abcd%201234'), isNull);
      expect(idOf('http://localhost:9000/community/abcd-1234'), isNull);
      expect(idOf('icarus://share/abcd-1234'), isNull);
    });
  });

  group('the feed filter', () {
    test('is empty with only a sort picked', () {
      expect(const CommunityFilter().isEmpty, isTrue);
      expect(
        const CommunityFilter(sort: CommunitySort.top, text: '  ').isEmpty,
        isTrue,
      );
      expect(const CommunityFilter(map: MapValue.bind).isEmpty, isFalse);
    });

    test('clears a map or side without touching the rest', () {
      const filter = CommunityFilter(
        map: MapValue.bind,
        side: CommunitySide.defense,
        agents: [AgentType.sova],
      );
      final cleared = filter.copyWith(clearMap: true);
      expect(cleared.map, isNull);
      expect(cleared.side, CommunitySide.defense);
      expect(cleared.agents, [AgentType.sova]);
      expect(filter.copyWith(clearSide: true).side, isNull);
      expect(filter.copyWith(), filter);
    });
  });

  group('a star count on screen', () {
    test("counts this session's star until the server's count moves", () {
      final stars = const CommunityStars().withStar(_post(), true);
      expect(stars.isStarred('post-1'), isTrue);
      expect(stars.countFor(_post()), 11);
      // A feed read again before the server counted it still shows it.
      expect(stars.countFor(_post(starCount: 10)), 11);
      // Once the server's count moves, it includes the star.
      expect(stars.countFor(_post(starCount: 11)), 11);
    });

    test('takes back an unstar, never below none', () {
      final stars =
          const CommunityStars(starred: {'post-1'}).withStar(_post(), false);
      expect(stars.isStarred('post-1'), isFalse);
      expect(stars.countFor(_post()), 9);
      expect(
        const CommunityStars(starred: {'post-1'})
            .withStar(_post(starCount: 0), false)
            .countFor(_post(starCount: 0)),
        0,
      );
    });

    test('unstarring after the server counted the star takes it off', () {
      final starred = const CommunityStars().withStar(_post(), true);
      final unstarred = starred.withStar(_post(starCount: 11), false);
      expect(unstarred.countFor(_post(starCount: 11)), 10);
    });

    test('starring and unstarring before the server counts either', () {
      final stars = const CommunityStars()
          .withStar(_post(), true)
          .withStar(_post(), false);
      expect(stars.countFor(_post()), 10);
    });

    test('is the count as read when this session changed nothing', () {
      expect(const CommunityStars().countFor(_post()), 10);
    });
  });

  group('a feed read again', () {
    late _FeedServer server;
    late DateTime now;
    late ProviderContainer container;
    const bind = CommunityFilter(map: MapValue.bind);

    CommunityFeedState feed() => container.read(communityFeedProvider);
    CommunityFeedNotifier notifier() =>
        container.read(communityFeedProvider.notifier);
    void pick(CommunityFilter filter) =>
        container.read(communityFilterProvider.notifier).state = filter;
    List<String> ids() => [for (final post in feed().posts) post.publicId];

    /// Opens the feed and answers its first page with [posts].
    Future<void> readFirst(List<String> posts, {String? nextCursor}) async {
      container.listen(communityFeedProvider, (_, __) {});
      await pumpEventQueue();
      server.answer(posts, nextCursor: nextCursor);
      await pumpEventQueue();
    }

    setUp(() {
      server = _FeedServer();
      now = DateTime(2026, 11, 18, 12);
      container = ProviderContainer(
        overrides: [
          communityRepositoryProvider.overrideWithValue(server),
          authProvider.overrideWith(_SignedOut.new),
          communityClockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(container.dispose);
    });

    test('shows placeholders the first time a filter is read', () async {
      container.listen(communityFeedProvider, (_, __) {});
      await pumpEventQueue();
      expect(feed().isFirstLoad, isTrue);
      expect(server.reads, hasLength(1));
    });

    test('a post dropped while the next page is read stays dropped', () async {
      await readFirst(['a', 'b'], nextCursor: 'more');
      unawaited(notifier().loadMore());
      await pumpEventQueue();
      notifier().forget('a');
      server.answer(['c']);
      await pumpEventQueue();
      expect(ids(), ['b', 'c']);
    });

    test('reads every feed again after the user posts', () async {
      await readFirst(['old-1']);
      pick(bind);
      await pumpEventQueue();
      server.answer(['bind-1']);
      await pumpEventQueue();
      expect(server.reads, hasLength(2));

      unawaited(notifier().readAgain());
      await pumpEventQueue();
      // The cards stay while it is read.
      expect(ids(), ['bind-1']);
      server.answer(['bind-new', 'bind-1']);
      await pumpEventQueue();
      expect(ids(), ['bind-new', 'bind-1']);

      // The feed kept for the other filter was dropped, so it is read too.
      pick(const CommunityFilter());
      await pumpEventQueue();
      expect(feed().isFirstLoad, isTrue);
      expect(server.reads, hasLength(4));
    });

    test('keeps its cards until the new first page arrives', () async {
      await readFirst(['old-1', 'old-2']);
      final firstRead = now;
      pick(bind);
      await pumpEventQueue();
      server.answer(['bind-1']);
      await pumpEventQueue();

      now = now.add(const Duration(minutes: 6));
      pick(const CommunityFilter());
      await pumpEventQueue();
      // Shown at once, as read, while it is read again.
      expect(ids(), ['old-1', 'old-2']);
      expect(feed().isFirstLoad, isFalse);
      expect(feed().loading, isTrue);
      expect(feed().fetchedAt, firstRead);
      expect(server.reads, hasLength(3));
      expect(server.reads.last.cursor, isNull);

      // Coming back again doesn't start a second read.
      await notifier().refreshIfStale();
      expect(server.reads, hasLength(3));

      server.answer(['new-1']);
      await pumpEventQueue();
      expect(ids(), ['new-1']);
      expect(feed().loading, isFalse);
      expect(feed().fetchedAt, now);

      // The kept feed is the new one: going away (Bind, stale too, is read
      // again) and back reads nothing more.
      pick(bind);
      await pumpEventQueue();
      expect(server.reads, hasLength(4));
      pick(const CommunityFilter());
      await pumpEventQueue();
      expect(ids(), ['new-1']);
      expect(feed().loading, isFalse);
      expect(server.reads, hasLength(4));
    });

    test('reads no page after the old cards while it is read again', () async {
      final page = [for (var i = 0; i < 15; i++) 'old-$i'];
      await readFirst(page, nextCursor: 'old-cursor');
      now = now.add(const Duration(minutes: 6));
      unawaited(notifier().refreshIfStale());
      await pumpEventQueue();
      expect(server.reads, hasLength(2));

      await notifier().loadMore();
      await notifier().loadMore(byUser: false);
      expect(server.reads, hasLength(2));
      expect(ids(), page);

      // The new feed pages on from its own cursor.
      server.answer(['new-1'], nextCursor: 'new-cursor');
      await pumpEventQueue();
      expect(server.reads, hasLength(3));
      expect(server.reads.last.cursor, 'new-cursor');
      server.answer(['new-2']);
      await pumpEventQueue();
      expect(ids(), ['new-1', 'new-2']);
    });

    test('keeps its cards when the read fails, and tries again later',
        () async {
      await readFirst(['old-1']);
      final firstRead = now;
      now = now.add(const Duration(minutes: 6));
      unawaited(notifier().refreshIfStale());
      await pumpEventQueue();
      server.fail();
      await pumpEventQueue();
      expect(ids(), ['old-1']);
      expect(feed().loading, isFalse);
      expect(feed().fetchedAt, firstRead);

      unawaited(notifier().refreshIfStale());
      await pumpEventQueue();
      expect(server.reads, hasLength(3));
      server.answer(['new-1']);
      await pumpEventQueue();
      expect(ids(), ['new-1']);
      expect(feed().error, isNull);
    });

    test('is not read again while fresh', () async {
      await readFirst(['old-1']);
      now = now.add(const Duration(minutes: 4));
      await notifier().refreshIfStale();
      pick(bind);
      await pumpEventQueue();
      server.answer(['bind-1']);
      await pumpEventQueue();
      pick(const CommunityFilter());
      await pumpEventQueue();
      expect(ids(), ['old-1']);
      expect(server.reads, hasLength(2));
    });

    test('drops the late page when the filter changed meanwhile', () async {
      await readFirst(['old-1']);
      now = now.add(const Duration(minutes: 6));
      unawaited(notifier().refreshIfStale());
      await pumpEventQueue();
      final reread = server.pending;

      pick(bind);
      await pumpEventQueue();
      expect(feed().filter, bind);
      expect(feed().isFirstLoad, isTrue);

      reread.complete((posts: [_post(id: 'late-1')], nextCursor: null));
      await pumpEventQueue();
      expect(feed().filter, bind);
      expect(ids(), isEmpty);

      server.answer(['bind-1']);
      await pumpEventQueue();
      expect(ids(), ['bind-1']);
    });
  });
}

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

/// A server whose feed pages arrive when the test answers them, oldest
/// read first.
class _FeedServer extends CommunityRepository {
  _FeedServer() : super(IcarusConvexApi(_NoTransport()));

  final reads = <({CommunityFilter filter, String? cursor})>[];
  final _waiting = <Completer<CommunityFeedPage>>[];

  Completer<CommunityFeedPage> get pending => _waiting.removeAt(0);

  void answer(List<String> ids, {String? nextCursor}) => pending.complete((
        posts: [for (final id in ids) _post(id: id)],
        nextCursor: nextCursor,
      ));

  void fail() => pending.completeError(StateError('offline'));

  @override
  Future<CommunityFeedPage> fetchFeed(
    CommunityFilter filter, {
    String? cursor,
  }) {
    reads.add((filter: filter, cursor: cursor));
    final page = Completer<CommunityFeedPage>();
    _waiting.add(page);
    return page.future;
  }
}

final class _NoTransport implements ConvexTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
