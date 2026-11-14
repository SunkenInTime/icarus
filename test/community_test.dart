import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/community_provider.dart';
import 'package:icarus/widgets/community/community_link.dart';

CommunityPost _post({int starCount = 10}) => CommunityPost(
      publicId: 'post-1',
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
}
