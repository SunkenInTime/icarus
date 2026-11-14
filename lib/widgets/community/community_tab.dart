import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/community_provider.dart';
import 'package:icarus/widgets/community/community_post_card.dart';
import 'package:icarus/widgets/community/community_post_view.dart';
import 'package:icarus/widgets/community/community_search_bar.dart';
import 'package:icarus/widgets/community/open_community_post.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// How long a feed read this session is shown as it was before the tab
/// reads it again on the next visit.
const _feedFreshFor = Duration(minutes: 5);

/// The Community tab: posts as cards, and one search bar floating at the
/// foot. Nothing else sits above the cards.
class CommunityTab extends ConsumerStatefulWidget {
  const CommunityTab({super.key});

  @override
  ConsumerState<CommunityTab> createState() => _CommunityTabState();
}

class _CommunityTabState extends ConsumerState<CommunityTab> {
  final _scroll = ScrollController();
  bool _panelOpen = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    final feed = ref.read(communityFeedProvider);
    final readAt = feed.fetchedAt;
    if (readAt != null && DateTime.now().difference(readAt) > _feedFreshFor) {
      Future.microtask(ref.read(communityFeedProvider.notifier).refresh);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels > position.maxScrollExtent - 600) {
      unawaited(ref.read(communityFeedProvider.notifier).loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(communityFeedProvider);
    // A filter change starts at the top.
    ref.listen(communityFilterProvider, (_, __) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
    return LayoutBuilder(
      builder: (context, constraints) {
        final barWidth = math.min(
          communitySearchBarWidth,
          constraints.maxWidth - 32,
        );
        return Stack(
          children: [
            Positioned.fill(child: _body(context, feed)),
            // The cards step back while the bar is open, and a click on
            // them only closes the bar (the bar closes on any click outside).
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_panelOpen,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    curve: Settings.easeOut,
                    opacity: _panelOpen ? 1 : 0,
                    child: const ColoredBox(color: Color(0x8C09090B)),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: SizedBox(
                  width: barWidth,
                  child: CommunitySearchBar(
                    maxPanelHeight: constraints.maxHeight - 48,
                    onPanelChanged: (open) => setState(() => _panelOpen = open),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, CommunityFeedState feed) {
    final l10n = context.l10n;
    final Widget child;
    if (feed.isFirstLoad) {
      child = const _FeedSkeleton(key: ValueKey('community-loading'));
    } else if (feed.posts.isEmpty && feed.error != null) {
      child = _FeedMessage(
        key: const ValueKey('community-error'),
        icon: LucideIcons.wifiOff,
        title: l10n.communityLoadFailedTitle,
        subtitle: l10n.communityLoadFailedSubtitle,
        action: ShadButton.secondary(
          onPressed: ref.read(communityFeedProvider.notifier).refresh,
          child: Text(l10n.commonRetry),
        ),
      );
    } else if (feed.posts.isEmpty) {
      final filtered = !feed.filter.isEmpty;
      child = _FeedMessage(
        key: ValueKey('community-empty-$filtered'),
        icon: filtered ? LucideIcons.searchX : LucideIcons.globe,
        title: filtered ? l10n.communityNoMatchTitle : l10n.communityEmptyTitle,
        subtitle: filtered
            ? l10n.communityNoMatchSubtitle
            : l10n.communityEmptySubtitle,
      );
    } else {
      child = _grid(feed);
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Settings.easeOut,
      switchOutCurve: Settings.easeOut.flipped,
      child: child,
    );
  }

  Widget _grid(CommunityFeedState feed) {
    final stars = ref.watch(communityStarsProvider);
    return LayoutBuilder(
      key: const ValueKey('community-grid'),
      builder: (context, constraints) {
        final columns = _columnsFor(constraints.maxWidth);
        return CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverPadding(
              // The cards' own gutter makes up the rest, as in My Library;
              // the foot leaves room to scroll the last row clear of the bar.
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 110),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: strategyTileGridMainAxisExtent,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final post = feed.posts[index];
                    return CommunityPostCard(
                      key: ValueKey(post.publicId),
                      post: post,
                      starred: stars.isStarred(post.publicId),
                      starCount: stars.countFor(post, feed.fetchedAt),
                      onOpen: () => openCommunityPost(ref, post),
                      onStar: () => toggleCommunityStar(context, ref, post),
                    );
                  },
                  childCount: feed.posts.length,
                ),
              ),
            ),
            if (feed.loading && feed.posts.isNotEmpty)
              const SliverToBoxAdapter(child: SizedBox(height: 1)),
          ],
        );
      },
    );
  }
}

int _columnsFor(double width) {
  const minTileWidth = 250.0;
  const spacing = strategyTileGridSpacing;
  const padding = 32.0;
  return math.max(
    1,
    ((width - padding + spacing) / (minTileWidth + spacing)).floor(),
  );
}

class _FeedMessage extends StatelessWidget {
  const _FeedMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Padding(
      // Centred in the space the bar leaves.
      padding: const EdgeInsets.only(bottom: 100),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 38, color: theme.mutedForeground),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.mutedForeground),
              ),
              if (action case final action?) ...[
                const SizedBox(height: 18),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Card-shaped placeholders while the first page is read.
class _FeedSkeleton extends StatefulWidget {
  const _FeedSkeleton({super.key});

  @override
  State<_FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<_FeedSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.value = 0.5;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _columnsFor(constraints.maxWidth);
        return FadeTransition(
          opacity: Tween(begin: 0.45, end: 0.9).animate(_pulse),
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(6),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisExtent: strategyTileGridMainAxisExtent,
            ),
            itemCount: columns * 3,
            itemBuilder: (context, _) => Padding(
              padding: const EdgeInsets.all(strategyTileGutterOutset),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Settings.tacticalVioletTheme.muted
                      .withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(strategyTileOuterRadius),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
