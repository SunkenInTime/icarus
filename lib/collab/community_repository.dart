import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/collab/collab_models.dart';

final communityRepositoryProvider = Provider<CommunityRepository>(
  (ref) => CommunityRepository.fromClient(ConvexClient.instance),
);

/// Community on the server: the feed, posts, stars, copies and reports.
///
/// The feed is read once per page, never watched: a watched feed would run
/// again for every reader each time any post on it changed.
class CommunityRepository {
  CommunityRepository(this._api);

  factory CommunityRepository.fromClient(ConvexClient client) =>
      CommunityRepository(IcarusConvexApi(PlatformConvexTransport(client)));

  final IcarusConvexApi _api;

  double get _protocol => currentCloudProtocolVersion.toDouble();

  /// One page of posts matching [filter], after [cursor] (the previous
  /// page's [CommunityFeedPage.nextCursor]).
  Future<CommunityFeedPage> fetchFeed(
    CommunityFilter filter, {
    String? cursor,
  }) async {
    final text = filter.text.trim();
    final result = await _api.community
        .listPosts(
          sort: switch (filter.sort) {
            CommunitySort.trending => CommunityListPostsArgsSort.trending,
            CommunitySort.newest => CommunityListPostsArgsSort.newValue,
            CommunitySort.top => CommunityListPostsArgsSort.top,
          },
          mapData: _optional(
            filter.map == null ? null : Maps.mapNames[filter.map],
          ),
          side: _optional(switch (filter.side) {
            CommunitySide.attack => CommunityListPostsArgsSide.attack,
            CommunitySide.defense => CommunityListPostsArgsSide.defense,
            CommunitySide.mixed || null => null,
          }),
          agentTypes: filter.agents.isEmpty
              ? const ConvexOptional.absent()
              : ConvexOptional.present([
                  for (final agent in filter.agents) agent.name,
                ]),
          text: text.isEmpty
              ? const ConvexOptional.absent()
              : ConvexOptional.present(text),
          cursor: _optional(cursor),
        )
        .fetch();
    return (
      posts: [
        for (final card in result.posts)
          if (_post(card) case final post?) post,
      ],
      nextCursor: result.nextCursor,
    );
  }

  /// The post [postPublicId] and whether it is still up, or null when there
  /// is no such post.
  Future<({CommunityPost post, CommunityPostStatus status})?> fetchPost(
    String postPublicId,
  ) async {
    final result =
        await _api.community.getPost(postPublicId: postPublicId).fetch();
    if (result == null) return null;
    final post = _post(result.post);
    if (post == null) return null;
    return (post: post, status: _status(result.status));
  }

  /// The posts the signed-in user starred.
  Future<Set<String>> fetchMyStars() async {
    final stars = await _api.community.listMyStars().fetch();
    return stars.toSet();
  }

  /// The signed-in user's own posts that are still up, kept current.
  Stream<List<MyCommunityPost>> watchMine() {
    return _api.community.listMine().watch().map(
          (items) => [
            for (final item in items)
              if (_post(item.post) case final post?)
                (
                  post: post,
                  status: _status(item.status),
                  sourceStrategyPublicId: item.sourceStrategyPublicId,
                  saveCount: item.saveCount.toInt(),
                  updatedAt: _dateTime(item.updatedAt),
                ),
          ],
        );
  }

  /// Whether the strategy behind the user's post [postPublicId] changed
  /// since the post was last updated; null when it was deleted.
  Future<bool?> fetchSourceChanged(String postPublicId) async {
    final result = await _api.community
        .getSourceChanged(postPublicId: postPublicId)
        .fetch();
    return result.sourceExists ? result.changed : null;
  }

  Future<CommunityViewer> fetchViewer() async {
    final result = await _api.community.getViewer().fetch();
    return (
      isReviewer: result.isReviewer,
      canPost: result.canPost,
      authorName: result.authorName,
    );
  }

  /// What a post of [strategyPublicId] would show, or null when it is on a
  /// map this build doesn't know.
  Future<CommunityPostPreview?> fetchPostPreview(
    String strategyPublicId,
  ) async {
    final result = await _api.community
        .getPostPreview(strategyPublicId: strategyPublicId)
        .fetch();
    final map = _mapOf(result.mapData);
    if (map == null) return null;
    return (
      name: result.name,
      map: map,
      side: _side(result.side),
      agents: _agents(result.agentTypes),
    );
  }

  /// The signed-in user's strategies they could post, most recently changed
  /// first.
  Future<List<PostableStrategy>> fetchPostable() async {
    final items = await _api.community.listPostable().fetch();
    return [
      for (final item in items)
        (
          strategyPublicId: item.strategyPublicId,
          name: item.name,
          map: _mapOf(item.mapData),
          updatedAt: _dateTime(item.updatedAt),
          postPublicId: item.postPublicId,
        ),
    ];
  }

  /// Posts [strategyPublicId] as it is now, titled [title], as
  /// [postPublicId]. Retrying with the same [postPublicId] returns the post
  /// already made. Returns the post's id.
  Future<String> publish({
    required String postPublicId,
    required String strategyPublicId,
    required String title,
  }) async {
    final result = await _api.community.publish(
      clientProtocolVersion: _protocol,
      postPublicId: postPublicId,
      strategyPublicId: strategyPublicId,
      title: title,
    );
    return result.postPublicId;
  }

  /// Renames the post, and with [refresh] shows the strategy as it is now.
  Future<void> updatePost({
    required String postPublicId,
    String? title,
    bool refresh = false,
  }) async {
    await _api.community.updatePost(
      clientProtocolVersion: _protocol,
      postPublicId: postPublicId,
      title: _optional(title),
      refresh: refresh
          ? const ConvexOptional.present(true)
          : const ConvexOptional.absent(),
    );
  }

  Future<void> takeDown(String postPublicId) async {
    await _api.community.takeDown(
      clientProtocolVersion: _protocol,
      postPublicId: postPublicId,
    );
  }

  Future<void> setStar(String postPublicId, {required bool starred}) async {
    await _api.community.setStar(
      clientProtocolVersion: _protocol,
      postPublicId: postPublicId,
      starred: starred,
    );
  }

  /// Copies the post into the signed-in user's library as [publicId].
  /// Retrying with the same [publicId] reuses the copy already made.
  Future<void> saveCopy({
    required String postPublicId,
    required String publicId,
    String? folderPublicId,
  }) async {
    await _api.community.saveCopy(
      clientProtocolVersion: _protocol,
      postPublicId: postPublicId,
      publicId: publicId,
      folderPublicId: _optional(folderPublicId),
    );
  }

  Future<void> report({
    required String postPublicId,
    required CommunityReportReason reason,
    String? note,
  }) async {
    final trimmed = note?.trim() ?? '';
    await _api.community.report(
      clientProtocolVersion: _protocol,
      postPublicId: postPublicId,
      reason: _reasonWire(reason),
      note: trimmed.isEmpty
          ? const ConvexOptional.absent()
          : ConvexOptional.present(trimmed),
    );
  }

  Future<List<CommunityReportGroup>> fetchReports(String postPublicId) async {
    final groups =
        await _api.community.getReports(postPublicId: postPublicId).fetch();
    return [
      for (final group in groups)
        (
          reason: _reason(group.reason),
          count: group.count.toInt(),
          notes: group.notes,
        ),
    ];
  }

  Future<void> review(
    String postPublicId,
    CommunityReviewDecision decision,
  ) async {
    await _api.community.review(
      clientProtocolVersion: _protocol,
      postPublicId: postPublicId,
      decision: switch (decision) {
        CommunityReviewDecision.restore => CommunityReviewArgsDecision.restore,
        CommunityReviewDecision.remove => CommunityReviewArgsDecision.remove,
        CommunityReviewDecision.ban => CommunityReviewArgsDecision.ban,
      },
    );
  }
}

/// A post card from the server, or null when it names a map this build
/// doesn't know (a newer build's map). Unknown agents are left out.
CommunityPost? _post(CommunityGetPostResultPost card) {
  final map = _mapOf(card.mapData);
  if (map == null) return null;
  return CommunityPost(
    publicId: card.publicId,
    title: card.title,
    map: map,
    side: _side(card.side),
    agents: _agents(card.agentTypes),
    authorName: card.authorName,
    authorAvatarUrl: card.authorAvatarUrl,
    starCount: card.starCount.toInt(),
    pageCount: card.pageCount.toInt(),
    lineupCount: card.lineupCount.toInt(),
    publishedAt: _dateTime(card.publishedAt),
    strategyPublicId: card.strategyPublicId,
    shareToken: card.shareToken,
  );
}

CommunitySide _side(CommunityGetPostResultPostSide side) => switch (side) {
      CommunityGetPostResultPostSide.attack => CommunitySide.attack,
      CommunityGetPostResultPostSide.defense => CommunitySide.defense,
      CommunityGetPostResultPostSide.mixed => CommunitySide.mixed,
    };

/// [names] as agents, leaving out any this build doesn't know.
List<AgentType> _agents(List<String> names) => [
      for (final name in names)
        for (final type in AgentType.values)
          if (type.name == name) type,
    ];

MapValue? _mapOf(String mapData) {
  for (final entry in Maps.mapNames.entries) {
    if (entry.value == mapData) return entry.key;
  }
  return null;
}

CommunityPostStatus _status(CommunityGetPostResultStatus status) =>
    switch (status) {
      CommunityGetPostResultStatus.listed => CommunityPostStatus.listed,
      CommunityGetPostResultStatus.hidden => CommunityPostStatus.hidden,
      CommunityGetPostResultStatus.removed => CommunityPostStatus.removed,
    };

CommunityReportReason _reason(CommunityGetReportsResultItemReason reason) =>
    switch (reason) {
      CommunityGetReportsResultItemReason.offensive =>
        CommunityReportReason.offensive,
      CommunityGetReportsResultItemReason.picture =>
        CommunityReportReason.picture,
      CommunityGetReportsResultItemReason.link => CommunityReportReason.link,
      CommunityGetReportsResultItemReason.spam => CommunityReportReason.spam,
      CommunityGetReportsResultItemReason.stolen =>
        CommunityReportReason.stolen,
    };

CommunityGetReportsResultItemReason _reasonWire(
  CommunityReportReason reason,
) =>
    switch (reason) {
      CommunityReportReason.offensive =>
        CommunityGetReportsResultItemReason.offensive,
      CommunityReportReason.picture =>
        CommunityGetReportsResultItemReason.picture,
      CommunityReportReason.link => CommunityGetReportsResultItemReason.link,
      CommunityReportReason.spam => CommunityGetReportsResultItemReason.spam,
      CommunityReportReason.stolen =>
        CommunityGetReportsResultItemReason.stolen,
    };

DateTime _dateTime(double milliseconds) =>
    DateTime.fromMillisecondsSinceEpoch(milliseconds.toInt());

ConvexOptional<T> _optional<T>(T? value) => value == null
    ? const ConvexOptional.absent()
    : ConvexOptional.present(value);
