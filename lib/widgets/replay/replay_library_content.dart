import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/replay/recycle_bin.dart';
import 'package:icarus/replay/replay_agents.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay_view.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/widgets/context_menu_region.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/hover_dot_grid.dart';
import 'package:icarus/widgets/replay/replay_failure_text.dart';
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
                title: context.l10n.replayLibraryListFailed,
                hint: '$error',
              ),
              data: (listings) => listings.isEmpty
                  ? _Message(
                      title: context.l10n.replayLibraryEmptyTitle,
                      hint: context.l10n.replayLibraryEmptyHint,
                    )
                  : _ReplayGrid(listings: listings),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplayGrid extends ConsumerStatefulWidget {
  const _ReplayGrid({required this.listings});

  final List<ReplayListing> listings;

  @override
  ConsumerState<_ReplayGrid> createState() => _ReplayGridState();
}

class _ReplayGridState extends ConsumerState<_ReplayGrid> {
  static const _padding = 16 - strategyTileGutterOutset;

  /// How long a just-added replay stays lit.
  static const _highlightDuration = Duration(milliseconds: 1800);

  final _scroll = ScrollController();
  int _columns = 1;
  Set<String> _highlighted = const {};
  Timer? _unhighlight;

  @override
  void dispose() {
    _unhighlight?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the highest of [reveal]'s replays into view and lights them
  /// all up for a moment. Waits for a listing that has them.
  void _reveal(ReplayReveal reveal) {
    final indices = [
      for (final (index, listing) in widget.listings.indexed)
        if (reveal.paths.contains(listing.file.path)) index,
    ];
    if (indices.isEmpty) return;
    ref.read(replayRevealProvider.notifier).state = null;
    if (_scroll.hasClients) {
      final position = _scroll.position;
      const extent = strategyTileGridMainAxisExtent;
      final top = _padding + (indices.reduce(math.min) ~/ _columns) * extent;
      final hidden = top < position.pixels ||
          top + extent > position.pixels + position.viewportDimension;
      if (hidden) {
        // Centered, so the toast at the bottom doesn't cover it.
        final target = top + extent / 2 - position.viewportDimension / 2;
        _scroll.animateTo(
          target.clamp(position.minScrollExtent, position.maxScrollExtent),
          duration: const Duration(milliseconds: 250),
          curve: Settings.easeOut,
        );
      }
    }
    setState(() => _highlighted = reveal.paths.toSet());
    _unhighlight?.cancel();
    _unhighlight = Timer(_highlightDuration, () {
      if (mounted) setState(() => _highlighted = const {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final reveal = ref.watch(replayRevealProvider);
    if (reveal != null) {
      // After layout, so the grid knows its columns and scroll extent.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(replayRevealProvider) == reveal) {
          _reveal(reveal);
        }
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // The strategy grid's columns, so the two tabs line up.
        const minTileWidth = 250.0;
        const padding = 32.0;
        _columns = ((constraints.maxWidth - padding + strategyTileGridSpacing) /
                (minTileWidth + strategyTileGridSpacing))
            .floor()
            .clamp(1, 1 << 20);
        return GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(_padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columns,
            mainAxisExtent: strategyTileGridMainAxisExtent,
          ),
          itemCount: widget.listings.length,
          itemBuilder: (context, index) {
            final listing = widget.listings[index];
            return ReplayTile(
              key: ValueKey(listing.file.path),
              listing: listing,
              highlighted: _highlighted.contains(listing.file.path),
            );
          },
        );
      },
    );
  }
}

/// One replay on the grid. Built like a strategy tile: map art above, the
/// match below.
class ReplayTile extends ConsumerStatefulWidget {
  const ReplayTile({
    super.key,
    required this.listing,
    this.highlighted = false,
  });

  final ReplayListing listing;

  /// Lit up because the user just added it.
  final bool highlighted;

  @override
  ConsumerState<ReplayTile> createState() => _ReplayTileState();
}

class _ReplayTileState extends ConsumerState<ReplayTile> {
  static const _ringWidth = 2.0;
  bool _hovered = false;

  /// The ring fades slower when it lights up for a reveal than on hover.
  bool _revealing = false;

  @override
  void didUpdateWidget(ReplayTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.highlighted != widget.highlighted) _revealing = true;
  }

  void _setHovered(bool hovered) => setState(() {
        _hovered = hovered;
        _revealing = false;
      });

  Future<void> _keep() async {
    final l10n = context.l10n;
    try {
      await ref.read(replayLibraryProvider.notifier).import(
            widget.listing.file.path,
          );
      Settings.showToast(
        message: l10n.replayLibraryKept,
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        l10n.replayLibraryKeepFailed,
        error: error,
        stackTrace: stackTrace,
        source: 'ReplayTile.keep',
      );
    }
  }

  /// Asks, then removes. The dialog says what will be left; if that stops
  /// being true before the file is deleted, nothing is deleted and it asks
  /// again with the new answer.
  Future<void> _remove() async {
    final library = ref.read(replayLibraryProvider.notifier);
    var file = widget.listing.file;
    while (true) {
      if (!mounted) return;
      final l10n = context.l10n;
      final confirmed = await ConfirmAlertDialog.show(
        context: context,
        title: l10n.replayLibraryRemoveTitle,
        content: file.valorantHasCopy
            ? l10n.replayLibraryRemoveValorantCopyBody
            : l10n.replayLibraryRemoveBody,
        confirmText: l10n.replayLibraryRemoveConfirm,
        isDestructive: true,
      );
      if (!confirmed) return;
      try {
        await library.remove(file);
        return;
      } on RecycleBinUnavailable catch (error) {
        Settings.showToast(
          message: error.deleted
              ? l10n.replayLibraryRecycleBinDeleted
              : l10n.replayLibraryRecycleBinFailed,
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return;
      } on ReplayRemoveRefused catch (refused) {
        if (refused.current case final current?
            when refused.reason == ReplayRemoveRefusal.valorantCopyChanged) {
          file = current;
          continue;
        }
        Settings.showToast(
          message: refused.reason == ReplayRemoveRefusal.fileChanged
              ? l10n.replayLibraryRemoveFileChanged
              : l10n.replayLibraryRemoveNotOwned,
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return;
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          l10n.replayLibraryRemoveFailed,
          error: error,
          stackTrace: stackTrace,
          source: 'ReplayTile.remove',
        );
        return;
      }
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
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: ContextMenuRegion(
          items: [
            if (listing.file.source == ReplaySource.valorant)
              ShadContextMenuItem(
                leading: const Icon(LucideIcons.archive),
                onPressed: _keep,
                child: Text(context.l10n.replayLibraryKeepInIcarus),
              )
            // Removing sends the file to the Recycle Bin, which only
            // Windows has.
            else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
              ShadContextMenuItem(
                leading: Icon(LucideIcons.trash2, color: theme.destructive),
                onPressed: _remove,
                child: Text(
                  context.l10n.replayLibraryRemoveFromIcarus,
                  style: TextStyle(color: theme.destructive),
                ),
              ),
          ],
          child: GestureDetector(
            onTap: () => openReplayListing(context, widget.listing),
            child: AnimatedContainer(
              duration: Duration(milliseconds: _revealing ? 250 : 100),
              curve: Settings.easeOut,
              decoration: BoxDecoration(
                color: theme.border,
                gradient: (_hovered && available) || widget.highlighted
                    ? Settings.raisedPrimaryFill
                    : null,
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
                        child: _ReplayDetails(
                          listing: listing,
                          map: map,
                          onKeep: listing.file.source == ReplaySource.valorant
                              ? _keep
                              : null,
                        ),
                      ),
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

/// Opens [listing] in the viewer, or says why it can't be watched.
void openReplayListing(BuildContext context, ReplayListing listing) {
  final probe = listing.probe;
  if (probe == null || !probe.supported) {
    Settings.showToast(
      message: _unavailableReason(context.l10n, listing),
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
    return;
  }
  Navigator.push(context, ReplayView.route(file: listing.file, probe: probe));
}

String _unavailableReason(AppLocalizations l10n, ReplayListing listing) {
  final probe = listing.probe;
  if (probe == null) {
    final error = listing.error;
    return error == null
        ? l10n.replayLibraryNotAReplay
        : replayFailureText(l10n, error);
  }
  if (!probe.supported) {
    return l10n.replayLibraryPatchUnsupported(replayPatchLabel(probe.build));
  }
  return l10n.replayMapNotSupported;
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
  const _ReplayDetails({
    required this.listing,
    required this.map,
    required this.onKeep,
  });

  final ReplayListing listing;
  final MapValue? map;

  /// Set when the replay lives only in Valorant's folder.
  final VoidCallback? onKeep;

  @override
  Widget build(BuildContext context) {
    final probe = listing.probe;
    final theme = ShadTheme.of(context);
    final mapName = map == null
        ? (probe == null
            ? context.l10n.replayLibraryUnreadableFile
            : context.l10n.replayLibraryUnknownMap)
        : Maps.mapNames[map]!.replaceRange(
            0,
            1,
            Maps.mapNames[map]![0].toUpperCase(),
          );
    final date = listing.date;
    final status = probe == null || !listing.canOpen
        ? (probe == null
            ? context.l10n.replayLibraryNotAReplayStatus
            : context.l10n.replayLibraryPatchStatus(
                replayPatchLabel(probe.build)))
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
          Row(
            children: [
              Expanded(
                child: Text(
                  MaterialLocalizations.of(context).formatMediumDate(date),
                  style: theme.textTheme.muted,
                ),
              ),
              if (onKeep case final onKeep?) _KeepButton(onPressed: onKeep),
            ],
          ),
          const Spacer(),
          if (probe != null) _AgentStrip(agentIds: probe.agentIds),
        ],
      ),
    );
  }
}

/// Marks a replay that lives only in Valorant's folder and keeps a copy in
/// Icarus. Valorant's replays stop playing in Valorant after a patch, and
/// Valorant may clear the folder, so the copy is what lasts.
class _KeepButton extends StatelessWidget {
  const _KeepButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadTooltip(
      builder: (context) => Text(context.l10n.replayLibraryKeepTooltip),
      child: ShadButton.ghost(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        foregroundColor: theme.colorScheme.mutedForeground,
        hoverForegroundColor: theme.colorScheme.foreground,
        leading: const Icon(LucideIcons.hourglass, size: 14),
        onPressed: onPressed,
        child: Text(
          context.l10n.replayLibraryKeepButton,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
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
    // Cut to the rounded square, the border drawn over the portrait.
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.card,
        borderRadius: BorderRadius.circular(4),
      ),
      foregroundDecoration: BoxDecoration(
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

/// Adds replay files the user picked or dropped, says what happened, and
/// shows them where the replays landed. Returns what the add did, or null
/// when it failed outright.
Future<ReplayAddResult?> addReplays(WidgetRef ref, List<String> paths) async {
  if (paths.isEmpty) return null;
  // Read before the add: the widget that asked may be gone when it finishes.
  final library = ref.read(replayLibraryProvider.notifier);
  final reveal = ref.read(replayRevealProvider.notifier);
  final l10n = ref.read(l10nProvider);
  final ReplayAddResult result;
  try {
    result = await library.add(paths);
  } catch (error, stackTrace) {
    AppErrorReporter.reportError(
      l10n.replayLibraryAddFailed,
      error: error,
      stackTrace: stackTrace,
      source: 'addReplays',
    );
    return null;
  }
  final shown = [...result.added, ...result.alreadyListed];
  Settings.showToast(
    message: replayAddMessage(l10n, result),
    backgroundColor: shown.isEmpty
        ? Settings.tacticalVioletTheme.destructive
        : Settings.tacticalVioletTheme.primary,
  );
  if (shown.isNotEmpty) {
    // Joins any reveal still waiting for the tab to open.
    reveal.state = ReplayReveal([...?reveal.state?.paths, ...shown]);
  }
  return result;
}

/// One toast's worth of what an add did, the way strategy imports report.
String replayAddMessage(AppLocalizations l10n, ReplayAddResult result) {
  final added = result.added.length;
  final already = result.alreadyListed.length;
  final unreadable = result.unreadable.length;
  final failed = result.failed.length;
  return [
    if (added > 0) l10n.replayLibraryAdded(added),
    if (already > 0 && added == 0) l10n.replayLibraryAlreadyListed(already),
    if (already > 0 && added > 0)
      l10n.replayLibrarySomeAlreadyListed(already),
    if (unreadable == 1)
      l10n.replayLibraryUnreadableOne(p.basename(result.unreadable.single)),
    if (unreadable > 1) l10n.replayLibraryUnreadableMany(unreadable),
    if (failed == 1)
      l10n.replayLibraryCopyFailedOne(p.basename(result.failed.single)),
    if (failed > 1) l10n.replayLibraryCopyFailedMany(failed),
  ].join(l10n.commonSentenceSpace);
}

/// Says what a drop on the Replays tab will do. The replays in it are taken
/// by `ReplayWindowDropTarget`, which catches them anywhere on the window;
/// this reports any other files as ones Icarus can't read.
class ReplayDropTarget extends ConsumerStatefulWidget {
  const ReplayDropTarget({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ReplayDropTarget> createState() => _ReplayDropTargetState();
}

class _ReplayDropTargetState extends ConsumerState<ReplayDropTarget> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        final others = [
          for (final file in details.files)
            if (p.extension(file.path).toLowerCase() != ReplayFiles.extension)
              file.path,
        ];
        if (others.isNotEmpty) addReplays(ref, others);
      },
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          if (_dragging) ...[
            const Positioned.fill(
              child: ColoredBox(color: Color.fromARGB(118, 2, 2, 2)),
            ),
            Positioned.fill(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(LucideIcons.download, size: 60),
                    const SizedBox(height: 10),
                    Text(
                      context.l10n.replayLibraryDropToAdd,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
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
