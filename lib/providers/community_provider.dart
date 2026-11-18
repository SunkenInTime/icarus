import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';

/// What the Community tab is narrowed to.
final communityFilterProvider =
    StateProvider<CommunityFilter>((ref) => const CommunityFilter());

/// The time a feed counts as read at; tests set it to say when "now" is.
final communityClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

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
    this.paused = false,
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

  /// Several pages in a row were read without filling the screen, so the
  /// rest waits to be asked for. Filters the server applies after reading a
  /// page can match a few posts in thousands.
  final bool paused;

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
    bool? paused,
  }) {
    return CommunityFeedState(
      filter: filter,
      posts: posts ?? this.posts,
      nextCursor: clearCursor ? null : nextCursor ?? this.nextCursor,
      started: started ?? this.started,
      loading: loading ?? this.loading,
      error: clearError ? null : error ?? this.error,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      paused: paused ?? this.paused,
    );
  }
}

/// Reads the feed once per page and never watches it, so readers cost the
/// server nothing between pages. Feeds already read this session are kept,
/// so going back to a filter shows it at once and reads nothing until it
/// is [freshFor] old, when it is read again behind the cards already shown.
class CommunityFeedNotifier extends Notifier<CommunityFeedState> {
  /// Fewer cards than this after a page and the next page is read straight
  /// away, so a narrow filter still fills the screen.
  static const fillTarget = 15;
  static const _keptFeeds = 12;

  /// How long a feed is shown as it was read.
  static const freshFor = Duration(minutes: 5);

  /// Pages read in a row without being asked before the feed pauses.
  static const maxUnaskedPages = 5;
  int _unaskedPages = 0;

  final _kept = <CommunityFilter, CommunityFeedState>{};
  int _generation = 0;
  String? _account;

  @override
  CommunityFeedState build() {
    final filter = ref.watch(communityFilterProvider);
    // Starred feeds are the account's own, so a sign-in or sign-out reads
    // them again.
    final account = ref.watch(
      authProvider.select(
        (auth) => auth.isAuthenticated && auth.isConvexUserReady
            ? auth.user?.id
            : null,
      ),
    );
    if (account != _account) {
      _account = account;
      _kept.removeWhere((kept, _) => kept.starred);
    }
    _generation++;
    final kept = _kept.remove(filter);
    if (kept != null && kept.error == null && !kept.loading) {
      _kept[filter] = kept;
      if (_stale(kept)) Future.microtask(refreshIfStale);
      return kept;
    }
    final fresh = CommunityFeedState(filter: filter);
    Future.microtask(loadMore);
    return fresh;
  }

  bool _stale(CommunityFeedState feed) {
    final readAt = feed.fetchedAt;
    return readAt != null &&
        ref.read(communityClockProvider)().difference(readAt) > freshFor;
  }

  /// Reads the feed again if it was read more than [freshFor] ago, unless a
  /// read is already under way.
  Future<void> refreshIfStale() async {
    if (_stale(state) && !state.loading) await refresh();
  }

  /// Reads the next page, unless one is already being read or there is none.
  /// A page the user didn't ask for (not [byUser]: filling the screen) is
  /// only read [maxUnaskedPages] times in a row, then the feed is [paused].
  Future<void> loadMore({bool byUser = true}) async {
    final current = state;
    if (current.loading || !current.hasMore) return;
    if (byUser) {
      _unaskedPages = 0;
    } else if (_unaskedPages >= maxUnaskedPages) {
      if (!current.paused) state = current.copyWith(paused: true);
      return;
    } else {
      _unaskedPages++;
    }
    state = current.copyWith(
      loading: true,
      started: true,
      clearError: true,
      paused: false,
    );
    await _read(after: current);
  }

  /// Reads the feed again from the top. The cards on screen stay until the
  /// new first page replaces them, [CommunityFeedState.loading] meanwhile so
  /// no page is read after them; if the read fails they stay.
  Future<void> refresh() async {
    _generation++;
    _unaskedPages = 0;
    state = state.copyWith(loading: true, started: true, clearError: true);
    await _read(after: CommunityFeedState(filter: state.filter));
  }

  /// Reads the page that follows [after] and shows [after] with it.
  Future<void> _read({required CommunityFeedState after}) async {
    final generation = _generation;
    try {
      final page = await ref
          .read(communityRepositoryProvider)
          .fetchFeed(after.filter, cursor: after.nextCursor);
      if (generation != _generation) return;
      final seen = {for (final post in after.posts) post.publicId};
      final next = state.copyWith(
        posts: [
          ...after.posts,
          for (final post in page.posts)
            if (seen.add(post.publicId)) post,
        ],
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        loading: false,
        paused: false,
        fetchedAt: after.fetchedAt ?? ref.read(communityClockProvider)(),
      );
      state = next;
      _keep(next);
      if (next.posts.length < fillTarget && next.nextCursor != null) {
        unawaited(loadMore(byUser: false));
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
    this.shownCounts = const {},
  });

  final Set<String> starred;

  /// The count shown for each post this session starred or unstarred, and
  /// the server's count it was worked out from. The server counts stars in
  /// batches a few minutes apart, so until its count moves from that one it
  /// doesn't include the change, and the shown count stands.
  final Map<String, ({int serverCount, int shown})> shownCounts;

  bool isStarred(String postPublicId) => starred.contains(postPublicId);

  /// [post]'s star count as it should read on screen.
  int countFor(CommunityPost post) {
    final shown = shownCounts[post.publicId];
    if (shown == null || shown.serverCount != post.starCount) {
      return post.starCount;
    }
    return shown.shown;
  }

  /// After starring ([starred]) or unstarring [post]: one more or one fewer
  /// than it showed before.
  CommunityStars withStar(CommunityPost post, bool starred) {
    final shown = countFor(post) + (starred ? 1 : -1);
    return CommunityStars(
      starred: starred
          ? {...this.starred, post.publicId}
          : ({...this.starred}..remove(post.publicId)),
      shownCounts: {
        ...shownCounts,
        post.publicId: (
          serverCount: post.starCount,
          shown: shown < 0 ? 0 : shown,
        ),
      },
    );
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
        shownCounts: state.shownCounts,
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

  /// Stars or unstars [post]. The screen changes now; if the server
  /// refuses, it changes back and this throws.
  Future<void> setStarred(CommunityPost post, bool starred) async {
    final before = state;
    if (before.isStarred(post.publicId) == starred) return;
    state = before.withStar(post, starred);
    try {
      await ref
          .read(communityRepositoryProvider)
          .setStar(post.publicId, starred: starred);
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

/// The posts waiting for a reviewer, kept current. Empty for everyone who
/// isn't one.
final communityReviewQueueProvider =
    StreamProvider<List<CommunityReviewItem>>((ref) {
  final isReviewer =
      ref.watch(communityViewerProvider).valueOrNull?.isReviewer ?? false;
  if (!isReviewer) return Stream.value(const []);
  return ref.watch(communityRepositoryProvider).watchForReview();
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

/// The signed-in user's copies of posts, read once per sign-in and added to
/// as they make more. Empty when signed out: a copy made then went to this
/// computer's library, which keeps no record of where it came from.
final communityCopiesProvider =
    NotifierProvider<CommunityCopiesNotifier, List<CommunityCopy>>(
  CommunityCopiesNotifier.new,
);

class CommunityCopiesNotifier extends Notifier<List<CommunityCopy>> {
  @override
  List<CommunityCopy> build() {
    final signedIn = ref.watch(
      authProvider.select(
        (auth) => auth.isAuthenticated && auth.isConvexUserReady,
      ),
    );
    if (!signedIn) return const [];
    unawaited(_load());
    return const [];
  }

  Future<void> _load() async {
    try {
      final copies =
          await ref.read(communityRepositoryProvider).fetchMyCopies();
      final made = {for (final copy in state) copy.strategyPublicId};
      state = [
        ...state,
        for (final copy in copies)
          if (!made.contains(copy.strategyPublicId)) copy,
      ];
    } catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'Reading Community copies failed.',
        source: 'CommunityCopiesNotifier.load',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Records a copy just made, newest first.
  void add(CommunityCopy copy) => state = [copy, ...state];
}

/// The user's newest copy of each post, by the post's id.
final communityCopyByPostProvider = Provider<Map<String, String>>((ref) {
  final copies = ref.watch(communityCopiesProvider);
  final byPost = <String, String>{};
  for (final copy in copies) {
    byPost.putIfAbsent(copy.postPublicId, () => copy.strategyPublicId);
  }
  return byPost;
});

/// The post each of the user's copies came from, by the copy's id.
final communityPostByCopyProvider = Provider<Map<String, String>>((ref) {
  return {
    for (final copy in ref.watch(communityCopiesProvider))
      copy.strategyPublicId: copy.postPublicId,
  };
});
