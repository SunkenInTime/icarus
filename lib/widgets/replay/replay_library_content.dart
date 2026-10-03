import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/replay/replay_agents.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay_view.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/widgets/hover_dot_grid.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

/// The Replays tab: every match Valorant downloaded plus the ones brought into
/// Icarus, newest first, on the same grid as strategies.
class ReplayLibraryContent extends ConsumerWidget {
  const ReplayLibraryContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listings = ref.watch(replayLibraryProvider);
    return ReplayDropTarget(
      child: Stack(
        children: [
          const Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(4),
              child: HoverDotGrid(),
            ),
          ),
          Positioned.fill(
            child: listings.when(
              loading: () => const SizedBox.shrink(),
              error: (error, _) => _Message(
                title: "Couldn't list replays",
                hint: '$error',
              ),
              data: (listings) => listings.isEmpty
                  ? const _Message(
                      title: 'No replays yet',
                      hint: 'Download a match from your career page in '
                          'Valorant, or drop a .vrf file here',
                    )
                  : _ReplayGrid(listings: listings),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplayGrid extends StatelessWidget {
  const _ReplayGrid({required this.listings});

  final List<ReplayListing> listings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The strategy grid's columns, so the two tabs line up.
        const minTileWidth = 250.0;
        const padding = 32.0;
        final columns =
            ((constraints.maxWidth - padding + strategyTileGridSpacing) /
                    (minTileWidth + strategyTileGridSpacing))
                .floor()
                .clamp(1, 1 << 20);
        return GridView.builder(
          padding: const EdgeInsets.all(16 - strategyTileGutterOutset),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: strategyTileGridMainAxisExtent,
          ),
          itemCount: listings.length,
          itemBuilder: (context, index) => ReplayTile(
            key: ValueKey(listings[index].file.path),
            listing: listings[index],
          ),
        );
      },
    );
  }
}

/// One replay on the grid. Built like a strategy tile: map art above, the
/// match below.
class ReplayTile extends ConsumerStatefulWidget {
  const ReplayTile({super.key, required this.listing});

  final ReplayListing listing;

  @override
  ConsumerState<ReplayTile> createState() => _ReplayTileState();
}

class _ReplayTileState extends ConsumerState<ReplayTile> {
  static const _ringWidth = 2.0;
  bool _hovered = false;

  void _open() {
    final listing = widget.listing;
    final probe = listing.probe;
    if (probe == null || !probe.supported) {
      Settings.showToast(
        message: _unavailableReason(listing),
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }
    Navigator.push(context, ReplayView.route(file: listing.file, probe: probe));
  }

  Future<void> _keep() async {
    try {
      await ref.read(replayLibraryProvider.notifier).import(
            widget.listing.file.path,
          );
      Settings.showToast(
        message: 'Kept in Icarus. Valorant can no longer remove it.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        "Couldn't keep this replay.",
        error: error,
        stackTrace: stackTrace,
        source: 'ReplayTile.keep',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final listing = widget.listing;
    final probe = listing.probe;
    final map = probe == null
        ? null
        : ReplayMapProjection.forMapPath(probe.mapPath)?.map;
    final available = listing.canOpen && map != null;
    const theme = Settings.tacticalVioletTheme;

    return Padding(
      padding: const EdgeInsets.all(strategyTileGutterOutset),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: ShadContextMenuRegion(
          items: [
            if (listing.file.source == ReplaySource.valorant)
              ShadContextMenuItem(
                leading: const Icon(LucideIcons.archive),
                onPressed: _keep,
                child: const Text('Keep in Icarus'),
              ),
          ],
          child: GestureDetector(
            onTap: _open,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: BoxDecoration(
                color: theme.border,
                gradient:
                    _hovered && available ? Settings.raisedPrimaryFill : null,
                borderRadius: BorderRadius.circular(strategyTileOuterRadius),
              ),
              padding: const EdgeInsets.all(_ringWidth),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.card,
                  borderRadius: BorderRadius.circular(
                    strategyTileOuterRadius - _ringWidth,
                  ),
                ),
                padding: const EdgeInsets.all(8 - _ringWidth),
                child: Opacity(
                  opacity: available ? 1 : 0.5,
                  child: Column(
                    children: [
                      Expanded(
                        child: map == null
                            ? DecoratedBox(
                                decoration: BoxDecoration(
                                  color: theme.secondary,
                                  borderRadius: BorderRadius.circular(
                                    strategyTileInnerRadius,
                                  ),
                                ),
                                child: const SizedBox.expand(),
                              )
                            : StrategyTileThumbnail(
                                assetPath: 'assets/maps/thumbnails/'
                                    '${Maps.mapNames[map]}_thumbnail.webp',
                                borderRadius: strategyTileInnerRadius,
                              ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                          child: _ReplayDetails(listing: listing, map: map)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _unavailableReason(ReplayListing listing) {
  final probe = listing.probe;
  if (probe == null) {
    return listing.error?.message ?? "This file isn't a Valorant replay.";
  }
  if (!probe.supported) {
    return 'Replays from patch ${replayPatchLabel(probe.build)} '
        "can't be read yet. An Icarus update will add them.";
  }
  return "This replay's map isn't in Icarus yet.";
}

/// `++Ares-Core+release-13.06` reads as `13.06`.
String replayPatchLabel(String build) {
  final match = RegExp(r'release-([0-9]+\.[0-9]+)').firstMatch(build);
  return match?.group(1) ?? build;
}

String replayDurationLabel(int durationMs) {
  final minutes = durationMs ~/ 60000;
  final seconds = (durationMs ~/ 1000) % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _ReplayDetails extends StatelessWidget {
  const _ReplayDetails({required this.listing, required this.map});

  final ReplayListing listing;
  final MapValue? map;

  @override
  Widget build(BuildContext context) {
    final probe = listing.probe;
    final theme = ShadTheme.of(context);
    final mapName = map == null
        ? (probe == null ? 'Unreadable file' : 'Unknown map')
        : Maps.mapNames[map]!.replaceRange(
            0,
            1,
            Maps.mapNames[map]![0].toUpperCase(),
          );
    final date = probe?.recordedAt ?? listing.file.modified;
    final status = probe == null || !listing.canOpen
        ? (probe == null
            ? 'Not a replay'
            : 'Patch ${replayPatchLabel(probe.build)}')
        : replayDurationLabel(probe.durationMs);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        borderRadius: BorderRadius.circular(strategyTileInnerRadius),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  mapName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              Text(status, style: theme.textTheme.muted),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            MaterialLocalizations.of(context).formatMediumDate(date),
            style: theme.textTheme.muted,
          ),
          const Spacer(),
          if (probe != null) _AgentStrip(agentIds: probe.agentIds),
        ],
      ),
    );
  }
}

/// The ten agents in the match, small enough to fit one row.
class _AgentStrip extends StatelessWidget {
  const _AgentStrip({required this.agentIds});

  final List<String> agentIds;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 3.0;
        final count = agentIds.length.clamp(1, 10);
        final size = ((constraints.maxWidth - gap * (count - 1)) / count)
            .clamp(12.0, 24.0);
        return Row(
          spacing: gap,
          children: [
            for (final id in agentIds.take(10))
              _AgentChip(agent: replayAgentType(id), size: size),
          ],
        );
      },
    );
  }
}

class _AgentChip extends StatelessWidget {
  const _AgentChip({required this.agent, required this.size});

  final AgentType? agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.card,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: theme.border),
      ),
      child:
          agent == null ? null : Image.asset(AgentData.agents[agent]!.iconPath),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: theme.textTheme.p),
          const SizedBox(height: 4),
          Text(hint, style: theme.textTheme.muted, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// Takes .vrf files dropped on the Replays tab into Icarus's replays folder.
class ReplayDropTarget extends ConsumerStatefulWidget {
  const ReplayDropTarget({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ReplayDropTarget> createState() => _ReplayDropTargetState();
}

class _ReplayDropTargetState extends ConsumerState<ReplayDropTarget> {
  bool _dragging = false;

  Future<void> _import(List<String> paths) async {
    final replays = [
      for (final path in paths)
        if (p.extension(path).toLowerCase() == ReplayFiles.extension) path,
    ];
    if (replays.isEmpty) {
      Settings.showToast(
        message: 'Only Valorant replays (.vrf) can be dropped here.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }
    for (final path in replays) {
      try {
        await ref.read(replayLibraryProvider.notifier).import(path);
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          "Couldn't import ${p.basename(path)}.",
          error: error,
          stackTrace: stackTrace,
          source: 'ReplayDropTarget',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _import([for (final file in details.files) file.path]);
      },
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          if (_dragging) ...[
            const Positioned.fill(
              child: ColoredBox(color: Color.fromARGB(118, 2, 2, 2)),
            ),
            const Positioned.fill(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.download, size: 60),
                    SizedBox(height: 10),
                    Text(
                      'Add replays',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
