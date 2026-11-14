import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';

/// What the Community tab is narrowed to.
final communityFilterProvider =
    StateProvider<CommunityFilter>((ref) => const CommunityFilter());

/// The feed for [communityFilterProvider], a page at a time.
final communityFeedProvider =
    NotifierProvider<CommunityFeedNotifier, CommunityFeedState>(
  CommunityFeedNotifier.new,
);

class CommunityFeedState {
  const CommunityFeedState({
    required this.filter,
    this.posts = const [],
    this.nextCursor,
    this.started = false,
    this.loading = false,
    this.error,
    this.fetchedAt,
  });

  final CommunityFilter filter;
  final List<CommunityPost> posts;

  /// Where the next page starts; null once the feed has no more.
  final String? nextCursor;

  /// Whether the first page has been asked for.
  final bool started;
  final bool loading;
  final Object? error;

  /// When the first page of [posts] was read: star counts are as of then.
  final DateTime? fetchedAt;

  bool get hasMore => !started || nextCursor != null;

  /// The first page has not arrived yet.
  bool get isFirstLoad =>
      posts.isEmpty && (loading || !started) && error == null;

  CommunityFeedState copyWith({
    List<CommunityPost>? posts,
    String? nextCursor,
    bool clearCursor = false,
    bool? started,
    bool? loading,
    Object? error,
    bool clearError = false,
    DateTime? fetchedAt,
  }) {
    return CommunityFeedState(
      filter: filter,
      posts: posts ?? this.posts,
      nextCursor: clearCursor ? null : nextCursor ?? this.nextCursor,
      started: started ?? this.started,
      loading: loading ?? this.loading,
      error: clearError ? null : error ?? this.error,
      fetchedAt: fetchedAt ?? this.fetchedAt,
    );
  }
}

/// Reads the feed once per page and never watches it, so readers cost the
/// server nothing between pages. Feeds already read this session are kept,
/// so going back to a filter shows it at once and reads nothing; pulling to
/// [refresh] reads it again.
class CommunityFeedNotifier extends Notifier<CommunityFeedState> {
  /// Fewer cards than this after a page and the next page is read straight
  /// away, so a narrow filter still fills the screen.
  static const fillTarget = 15;
  static const _keptFeeds = 12;

  final _kept = <CommunityFilter, CommunityFeedState>{};
  int _generation = 0;

  @override
  CommunityFeedState build() {
    final filter = ref.watch(communityFilterProvider);
    _generation++;
    final kept = _kept.remove(filter);
    if (kept != null && kept.error == null && !kept.loading) {
      _kept[filter] = kept;
      return kept;
    }
    final fresh = CommunityFeedState(filter: filter);
    Future.microtask(loadMore);
    return fresh;
  }

  /// Reads the next page, unless one is already being read or there is none.
  Future<void> loadMore() async {
    final current = state;
    if (current.loading || !current.hasMore) return;
    final generation = _generation;
    state = current.copyWith(loading: true, started: true, clearError: true);
    try {
      final page = await ref
          .read(communityRepositoryProvider)
          .fetchFeed(current.filter, cursor: current.nextCursor);
      if (generation != _generation) return;
      final seen = {for (final post in current.posts) post.publicId};
      final next = state.copyWith(
        posts: [
          ...current.posts,
          for (final post in page.posts)
            if (seen.add(post.publicId)) post,
        ],
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        loading: false,
        fetchedAt: current.fetchedAt ?? DateTime.now(),
      );
      state = next;
      _keep(next);
      if (next.posts.length < fillTarget && next.nextCursor != null) {
        unawaited(loadMore());
      }
    } catch (error, stackTrace) {
      if (generation != _generation) return;
      AppErrorReporter.reportWarning(
        'Reading the Community feed failed.',
        source: 'CommunityFeedNotifier.loadMore',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(loading: false, error: error);
    }
  }

  /// Reads the feed again from the top.
  Future<void> refresh() async {
    _kept.remove(state.filter);
    _generation++;
    state = CommunityFeedState(filter: state.filter);
    await loadMore();
  }

  /// Drops [postPublicId] from every kept feed: it was taken down.
  void forget(String postPublicId) {
    bool keep(CommunityPost post) => post.publicId != postPublicId;
    for (final entry in _kept.entries.toList()) {
      _kept[entry.key] =
          entry.value.copyWith(posts: entry.value.posts.where(keep).toList());
    }
    state = state.copyWith(posts: state.posts.where(keep).toList());
  }

  void _keep(CommunityFeedState feed) {
    _kept.remove(feed.filter);
    _kept[feed.filter] = feed;
    while (_kept.length > _keptFeeds) {
      _kept.remove(_kept.keys.first);
    }
  }
}

/// The posts the signed-in user starred, read once per sign-in and then
/// changed here as they star: the screen answers on the click, and the
/// server is told behind it.
final communityStarsProvider =
    NotifierProvider<CommunityStarsNotifier, CommunityStars>(
  CommunityStarsNotifier.new,
);

class CommunityStars {
  const CommunityStars({
    this.starred = const {},
    this.changedAt = const {},
  });

  final Set<String> starred;

  /// When this session starred or unstarred a post. A count read before
  /// then doesn't include the change, so it is added on screen.
  final Map<String, ({bool starred, DateTime at})> changedAt;

  bool isStarred(String postPublicId) => starred.contains(postPublicId);

  /// [post]'s star count as of a read at [readAt], with this session's own
  /// star counted when the read came before it.
  int countFor(CommunityPost post, DateTime? readAt) {
    final change = changedAt[post.publicId];
    if (change == null || readAt == null || readAt.isAfter(change.at)) {
      return post.starCount;
    }
    final count = post.starCount + (change.starred ? 1 : -1);
    return count < 0 ? 0 : count;
  }
}

class CommunityStarsNotifier extends Notifier<CommunityStars> {
  @override
  CommunityStars build() {
    final signedIn = ref.watch(
      authProvider
          .select((auth) => auth.isAuthenticated && auth.isConvexUserReady),
    );
    if (!signedIn) return const CommunityStars();
    unawaited(_load());
    return const CommunityStars();
  }

  Future<void> _load() async {
    try {
      final starred =
          await ref.read(communityRepositoryProvider).fetchMyStars();
      state = CommunityStars(
        starred: {...starred, ...state.starred},
        changedAt: state.changedAt,
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'Reading Community stars failed.',
        source: 'CommunityStarsNotifier.load',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Stars or unstars [postPublicId]. The screen changes now; if the server
  /// refuses, it changes back and this throws.
  Future<void> setStarred(String postPublicId, bool starred) async {
    final before = state;
    if (before.isStarred(postPublicId) == starred) return;
    final changes = {...before.changedAt};
    // A second click undoes this session's first: the count is as read.
    if (changes.remove(postPublicId) == null) {
      changes[postPublicId] = (starred: starred, at: DateTime.now());
    }
    state = CommunityStars(
      starred: starred
          ? {...before.starred, postPublicId}
          : ({...before.starred}..remove(postPublicId)),
      changedAt: changes,
    );
    try {
      await ref
          .read(communityRepositoryProvider)
          .setStar(postPublicId, starred: starred);
    } catch (_) {
      state = before;
      rethrow;
    }
  }
}

/// The signed-in user's own posts, kept current, for the Posted badge and
/// the post's dialog. Empty when signed out.
final myCommunityPostsProvider = StreamProvider<List<MyCommunityPost>>((ref) {
  final signedIn = ref.watch(
    authProvider
        .select((auth) => auth.isAuthenticated && auth.isConvexUserReady),
  );
  if (!signedIn) return Stream.value(const []);
  return ref.watch(communityRepositoryProvider).watchMine();
});

/// The signed-in user's post of each of their strategies, by the strategy's
/// id.
final myPostsByStrategyProvider = Provider<Map<String, MyCommunityPost>>((ref) {
  final mine = ref.watch(myCommunityPostsProvider).valueOrNull ?? const [];
  return {for (final post in mine) post.sourceStrategyPublicId: post};
});

/// What the signed-in user may do in Community.
final communityViewerProvider = FutureProvider<CommunityViewer>((ref) async {
  final signedIn = ref.watch(
    authProvider
        .select((auth) => auth.isAuthenticated && auth.isConvexUserReady),
  );
  if (!signedIn) return (isReviewer: false, canPost: false, authorName: null);
  return ref.read(communityRepositoryProvider).fetchViewer();
});
