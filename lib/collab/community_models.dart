import 'package:flutter/foundation.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';

/// The longest a post's title may be, as the server holds it.
const communityMaxTitleLength = 60;

/// Which side a post's pages play: all attack, all defense, or both.
enum CommunitySide { attack, defense, mixed }

/// How the feed is ordered.
enum CommunitySort {
  /// Stars and saves from the last week.
  trending,

  /// Newest first.
  newest,

  /// Most starred of all time.
  top,
}

enum CommunityPostStatus {
  /// In the feed.
  listed,

  /// Out of the feed after reports, until a reviewer decides.
  hidden,

  /// Taken down by its author or a reviewer; its link no longer opens.
  removed,
}

enum CommunityReportReason { offensive, picture, link, spam, stolen }

/// What a reviewer may do with a reported post.
enum CommunityReviewDecision { restore, remove, ban }

/// One post as a feed card shows it. Opening it reads the frozen copy of the
/// strategy, [strategyPublicId], through [shareToken].
@immutable
class CommunityPost {
  const CommunityPost({
    required this.publicId,
    required this.title,
    required this.map,
    required this.side,
    required this.agents,
    required this.authorName,
    required this.authorAvatarUrl,
    required this.starCount,
    required this.pageCount,
    required this.lineupCount,
    required this.publishedAt,
    required this.strategyPublicId,
    required this.shareToken,
  });

  final String publicId;
  final String title;
  final MapValue map;
  final CommunitySide side;

  /// The agents the strategy uses, most used first.
  final List<AgentType> agents;

  /// Null when the author has no display name.
  final String? authorName;
  final String? authorAvatarUrl;

  /// As the server last counted it: stars reach the count within minutes.
  final int starCount;
  final int pageCount;
  final int lineupCount;
  final DateTime publishedAt;
  final String strategyPublicId;
  final String shareToken;

  @override
  bool operator ==(Object other) =>
      other is CommunityPost &&
      other.publicId == publicId &&
      other.title == title &&
      other.starCount == starCount &&
      other.strategyPublicId == strategyPublicId;

  @override
  int get hashCode => Object.hash(publicId, title, starCount, strategyPublicId);
}

/// What the feed is narrowed to and how it is ordered.
@immutable
class CommunityFilter {
  const CommunityFilter({
    this.map,
    this.side,
    this.agents = const [],
    this.text = '',
    this.sort = CommunitySort.trending,
    this.starred = false,
  });

  final MapValue? map;

  /// [CommunitySide.attack] or [CommunitySide.defense]; a post playing both
  /// matches either.
  final CommunitySide? side;

  /// Posts that use every one of these.
  final List<AgentType> agents;

  /// Words in the title or the author's name.
  final String text;
  final CommunitySort sort;

  /// Only posts the reader starred.
  final bool starred;

  bool get isEmpty =>
      map == null &&
      side == null &&
      agents.isEmpty &&
      text.trim().isEmpty &&
      !starred;

  CommunityFilter copyWith({
    MapValue? map,
    bool clearMap = false,
    CommunitySide? side,
    bool clearSide = false,
    List<AgentType>? agents,
    String? text,
    CommunitySort? sort,
    bool? starred,
  }) {
    return CommunityFilter(
      map: clearMap ? null : map ?? this.map,
      side: clearSide ? null : side ?? this.side,
      agents: agents ?? this.agents,
      text: text ?? this.text,
      sort: sort ?? this.sort,
      starred: starred ?? this.starred,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CommunityFilter &&
      other.map == map &&
      other.side == side &&
      listEquals(other.agents, agents) &&
      other.text == text &&
      other.sort == sort &&
      other.starred == starred;

  @override
  int get hashCode =>
      Object.hash(map, side, Object.hashAll(agents), text, sort, starred);
}

typedef CommunityFeedPage = ({
  List<CommunityPost> posts,

  /// Null when the feed has no more.
  String? nextCursor,
});

/// One of the signed-in user's own posts.
typedef MyCommunityPost = ({
  CommunityPost post,
  CommunityPostStatus status,
  String sourceStrategyPublicId,
  int saveCount,
  DateTime updatedAt,
});

typedef CommunityViewer = ({
  bool isReviewer,
  bool canPost,

  /// The name their posts show; null shows none.
  String? authorName,
});

/// What a post of one of the user's strategies would show on its card.
typedef CommunityPostPreview = ({
  String name,
  MapValue map,
  CommunitySide side,
  List<AgentType> agents,
});

typedef CommunityReportGroup = ({
  CommunityReportReason reason,
  int count,
  List<String> notes,
});

/// One of the signed-in user's strategies, as the Post picker lists it.
typedef PostableStrategy = ({
  String strategyPublicId,
  String name,
  MapValue? map,
  DateTime updatedAt,

  /// The post already made from it, if any.
  String? postPublicId,
});

/// A copy of a post the signed-in user made in their library.
typedef CommunityCopy = ({String strategyPublicId, String postPublicId});
