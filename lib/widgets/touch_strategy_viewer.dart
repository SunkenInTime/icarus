import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/drawn_cloud_pages_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart'
    hide PageTransitionState;
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/cloud_sync_button.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _stripHeight = 48;

/// The narrowest the pages column gets when the screen is held sideways.
const double _sidePagesWidth = 220;

/// The least height the pages keep under the map on an upright screen.
const double _minPagesHeight = 112;

/// Air either side of the map when its width is what fits it to the screen.
const double _mapSideGap = 16;

/// A view-only strategy on a phone or tablet: the map as big as the screen
/// allows, and the pages beside or under it, upright or sideways. Nothing
/// here edits, so the desktop editor's floating cards have no place, and a
/// reader who came from a share link can read the whole strategy at once.
class TouchStrategyViewer extends ConsumerWidget {
  const TouchStrategyViewer({
    super.key,
    required this.onLeave,
    this.backTooltip,
  });

  final VoidCallback onLeave;
  final String? backTooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentMap = ref.watch(mapProvider.select((map) => map.currentMap));
    return Scaffold(
      body: Column(
        children: [
          _ViewerStrip(onLeave: onLeave, backTooltip: backTooltip),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const map = RepaintBoundary(child: InteractiveMap());
                const pages = _ViewerPages();
                if (constraints.maxWidth > constraints.maxHeight) {
                  return Row(
                    children: [
                      const Expanded(child: map),
                      Container(
                        width: _sidePagesWidth,
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: Settings.tacticalVioletTheme.border,
                            ),
                          ),
                        ),
                        child: pages,
                      ),
                    ],
                  );
                }
                // The map is laid out by its height, so fitting its width
                // into the screen's is a matter of giving it less height.
                final art = Maps.mapViewBox[currentMap]!;
                final mapHeight = math.min(
                  (constraints.maxWidth - _mapSideGap) * art.height / art.width,
                  constraints.maxHeight - _minPagesHeight,
                );
                return Column(
                  children: [
                    SizedBox(height: mapHeight, child: map),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: Settings.tacticalVioletTheme.border,
                            ),
                          ),
                        ),
                        child: pages,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewerStrip extends ConsumerWidget {
  const _ViewerStrip({required this.onLeave, this.backTooltip});

  final VoidCallback onLeave;
  final String? backTooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = Settings.tacticalVioletTheme;
    final name = ref.watch(
      strategyProvider.select((value) => value.strategyName),
    );
    return Container(
      key: const ValueKey('app-window-strip'),
      height: _stripHeight,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: theme.card,
        border: Border(bottom: BorderSide(color: theme.border)),
      ),
      child: Row(
        children: [
          Semantics(
            label: backTooltip ?? 'Library',
            button: true,
            child: ShadIconButton.ghost(
              key: const ValueKey('viewer-leave'),
              width: 36,
              height: 36,
              foregroundColor: theme.mutedForeground,
              onPressed: onLeave,
              icon: Icon(
                backTooltip == null
                    ? LucideIcons.house300
                    : LucideIcons.chevronLeft300,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.foreground,
                  ),
                ),
                Text(
                  'View only',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const _ViewerAction(),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// What a reader can do with what they're reading. In words, because a
/// finger gets no tooltip: log in or keep a strategy read through a link. A
/// member who can only view already has it, so they see its sync state.
class _ViewerAction extends ConsumerWidget {
  const _ViewerAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strategyId = ref.watch(
      strategyProvider.select((value) => value.strategyId),
    );
    final throughLink =
        ref.watch(shareLinkViewProvider)?.strategyPublicId == strategyId;
    if (!throughLink) {
      return const CloudSyncButton(style: kEditorToolbarButtonStyle);
    }
    final signedIn = ref.watch(
      authProvider.select((auth) => auth.isAuthenticated),
    );
    if (signedIn) {
      return ShadButton(
        key: const ValueKey('viewer-add-to-library'),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        onPressed: () => ref
            .read(shareLinkControllerProvider.notifier)
            .addViewedLinkToLibrary(),
        leading: const Icon(LucideIcons.bookmarkPlus, size: 16),
        child: const Text('Add to library'),
      );
    }
    return ShadButton(
      key: const ValueKey('viewer-log-in'),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => const AuthDialog(),
      ),
      child: const Text('Log In'),
    );
  }
}

class _ViewerPages extends ConsumerWidget {
  const _ViewerPages();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = Settings.tacticalVioletTheme;
    final pages = ref.watch(drawnCloudPagesProvider)?.pages ?? const [];
    final activePageId = ref.watch(
      strategyPageSessionProvider.select((state) => state.activePageId),
    );
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: pages.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final page = pages[index];
        final active = page.publicId == (activePageId ?? pages.first.publicId);
        return Semantics(
          label: page.name,
          button: true,
          selected: active,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref
                .read(strategyProvider.notifier)
                .setActivePageAnimated(page.publicId),
            child: Container(
              key: ValueKey('viewer-page-${page.publicId}'),
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              decoration: active ? Settings.raisedSurface(8) : null,
              child: Text(
                page.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: active ? theme.foreground : theme.mutedForeground,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
