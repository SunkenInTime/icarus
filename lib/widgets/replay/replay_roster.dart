import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/replay/replay_agents.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay/replay_weapons.dart';
import 'package:icarus/widgets/keybind_badge.dart';
import 'package:icarus/widgets/replay/replay_events.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:icarus/widgets/replay/replay_select.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Both teams as they stand right now, then the round's events.
class ReplayRoster extends StatelessWidget {
  const ReplayRoster({super.key, required this.playback});

  static const double width = 280;

  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: ReplaySelect<List<Object?>>(
        listenable: playback,
        select: _shown,
        builder: (context, _) {
          final perspective = playback.perspective;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TeamBlock(
                playback: playback,
                team: perspective,
                label: 'Allies',
              ),
              Divider(height: 1, color: theme.colorScheme.border),
              _TeamBlock(
                playback: playback,
                team: perspective.other,
                label: 'Enemies',
              ),
              Divider(height: 1, color: theme.colorScheme.border),
              Expanded(child: _Killfeed(playback: playback)),
            ],
          );
        },
      ),
    );
  }
}

extension on ReplayRoster {
  /// Everything the roster shows, coarsely: it rebuilds when this changes,
  /// not on every frame.
  List<Object?> _shown() {
    final now = playback.timeMs;
    final round = playback.round;
    return [
      playback.perspective,
      playback.watching,
      playback.following,
      round?.index,
      for (final player in playback.document.players)
        if (playback.frames.playerState(player, now) case final state) ...[
          state.alive,
          state.health?.round(),
          state.armor?.round(),
        ],
      if (round != null)
        replayRoundEvents(playback.document, round)
            .where((event) => event.timeMs <= now)
            .length,
    ];
  }
}

class _TeamBlock extends StatelessWidget {
  const _TeamBlock({
    required this.playback,
    required this.team,
    required this.label,
  });

  final ReplayPlayback playback;
  final ReplayTeam team;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final states = [
      for (final player in playback.playersOf(team))
        playback.frames.playerState(player, playback.timeMs),
    ];
    final alive = states.where((state) => state.alive).length;
    // Rows reach 6px further out than the header, so a watched row's
    // surface frames its content and the content lines up with the header.
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: team.colorFor(playback.perspective),
                  ),
                ),
                const Spacer(),
                Text('$alive alive', style: theme.textTheme.muted),
              ],
            ),
          ),
          const SizedBox(height: 6),
          for (final state in states)
            _PlayerRow(
              // Keyed: a swap moves each player to the other block, and
              // a row (its hover, its watched state) must go with them.
              key: ValueKey(state.player.subject),
              state: state,
              economy: playback.round?.economyFor(state.player.subject),
              watched: playback.watching == state.player.subject,
              following: playback.following,
              watchKey: playback.watchKeyOf(state.player),
              onWatch: () => playback.watch(state.player.subject),
            ),
        ],
      ),
    );
  }
}

/// One player as they stand. Clicking the row, or pressing the key drawn at
/// its left edge, watches them; the watched player's row is raised and
/// ringed in violet.
class _PlayerRow extends StatefulWidget {
  const _PlayerRow({
    super.key,
    required this.state,
    required this.economy,
    required this.watched,
    required this.following,
    required this.watchKey,
    required this.onWatch,
  });

  final ReplayPlayerState state;
  final ReplayEconomy? economy;
  final bool watched;

  /// Whether the camera follows the watched player.
  final bool following;

  /// The number key that watches this player, when they have one.
  final String? watchKey;
  final VoidCallback onWatch;

  @override
  State<_PlayerRow> createState() => _PlayerRowState();
}

class _PlayerRowState extends State<_PlayerRow> {
  var _hovered = false;

  /// What clicking the row (or pressing its key) does.
  String _tooltip(String name) {
    final action = !widget.watched
        ? 'Watch'
        : widget.following
            ? 'Stop watching'
            : 'Follow';
    final key = widget.watchKey;
    return key == null ? '$action $name' : '$action $name ($key)';
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final state = widget.state;
    final economy = widget.economy;
    final agent = replayAgentType(state.player.agentId);
    final agentData = agent == null ? null : AgentData.agents[agent];
    final weapon = replayWeaponType(economy?.weapon);
    final name = state.player.name ?? agentData?.name ?? 'Unknown agent';
    final credits = economy?.credits;
    const radius = 8.0;
    return ShadTooltip(
      builder: (context) => Text(_tooltip(name)),
      // A Shad detector, so the tooltip sees the hover.
      child: ShadGestureDetector(
        cursor: SystemMouseCursors.click,
        behavior: HitTestBehavior.opaque,
        onHoverChange: (hovered) => setState(() => _hovered = hovered),
        onTap: widget.onWatch,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: widget.watched
              ? Settings.raisedSurface(radius)
              : BoxDecoration(
                  color: _hovered ? theme.colorScheme.accent : null,
                  borderRadius: BorderRadius.circular(radius),
                ),
          foregroundDecoration: widget.watched
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: Settings.accentInk),
                )
              : null,
          child: Row(
            children: [
              // Numbered down the left edge, as a scoreboard numbers its
              // players. Outside the dead fade: the dead can be watched too.
              if (widget.watchKey case final key?)
                KeybindBadge(label: key, lit: _hovered || widget.watched)
              else
                const SizedBox(width: 20),
              const SizedBox(width: 8),
              Expanded(
                child: _content(theme, agentData, name, weapon, credits),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(
    ShadThemeData theme,
    AgentData? agentData,
    String name,
    WeaponType weapon,
    int? credits,
  ) {
    final state = widget.state;
    return Opacity(
      opacity: state.alive ? 1 : 0.4,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: theme.colorScheme.secondary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: agentData == null ? null : Image.asset(agentData.iconPath),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  _VitalsBar(health: state.health, armor: state.armor),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // What they carried out of the buy phase, and what they had
            // left to spend.
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (weapon != WeaponType.none)
                  Image.asset(weapon.iconPath, height: 14)
                else
                  const SizedBox(height: 14),
                if (credits != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.coins,
                        size: 10,
                        color: theme.colorScheme.mutedForeground,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '$credits',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.mutedForeground,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Health as a filled bar out of 100, armor as a thinner bar under it. An
/// unknown reading shows the empty track, never a guess.
class _VitalsBar extends StatelessWidget {
  const _VitalsBar({required this.health, required this.armor});

  final double? health;
  final double? armor;

  @override
  Widget build(BuildContext context) {
    final track = Settings.tacticalVioletTheme.secondary;
    Widget bar(double fraction, Color color, double height) => ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: SizedBox(
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: track),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: ColoredBox(color: color),
                ),
              ],
            ),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        bar((health ?? 0) / 100, Settings.tacticalVioletTheme.foreground, 3),
        const SizedBox(height: 2),
        bar((armor ?? 0) / 50, Settings.tacticalVioletTheme.mutedForeground, 2),
      ],
    );
  }
}

/// This round's events so far, newest first, as far as the filter above
/// them shows. Clicking one replays it.
class _Killfeed extends ConsumerWidget {
  const _Killfeed({required this.playback});

  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final filters = ref.watch(replayEventFiltersProvider);
    final round = playback.round;
    final now = playback.timeMs;
    final events = [
      if (round != null)
        for (final event in replayRoundEvents(playback.document, round))
          if (event.timeMs <= now && filters.contains(event.kind.filter)) event,
    ].reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            spacing: 8,
            children: [
              for (final filter in ReplayEventFilter.values)
                Expanded(
                  child: _FilterChip(
                    label: filter.label,
                    selected: filters.contains(filter),
                    onTap: () => ref
                        .read(replayEventFiltersProvider.notifier)
                        .update((shown) => shown.contains(filter)
                            ? ({...shown}..remove(filter))
                            : {...shown, filter}),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? Center(
                  child: Text(
                    _emptyText(filters),
                    style: theme.textTheme.muted,
                  ),
                )
              // Rows sit 6px in from the panel, like the players above, and
              // the line inside sets their height.
              : ListView.builder(
                  padding: const EdgeInsets.all(6),
                  itemCount: events.length,
                  itemBuilder: (context, index) => ShadButton.ghost(
                    height: 0,
                    expands: true,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    onPressed: () => playback.seek(events[index].timeMs - 2000),
                    child: ReplayEventLine(
                      event: events[index],
                      playback: playback,
                      fill: true,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// What an empty list means: with kills shown, that no one has died.
  static String _emptyText(Set<ReplayEventFilter> filters) {
    final spike = filters.contains(ReplayEventFilter.spike);
    final abilities = filters.contains(ReplayEventFilter.abilities);
    if (filters.contains(ReplayEventFilter.kills)) {
      return 'No kills yet this round';
    }
    if (spike && abilities) return 'No plant or abilities yet this round';
    if (spike) return 'No plant yet this round';
    if (abilities) return 'No abilities used yet this round';
    return 'Choose what to show';
  }
}

/// One choice in the killfeed's filter: a primary button, raised in
/// violet, while it shows; an outline one while it doesn't.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Semantics(
      toggled: selected,
      child: ShadButton.raw(
        variant:
            selected ? ShadButtonVariant.primary : ShadButtonVariant.outline,
        height: 24,
        expands: true,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: selected ? null : theme.colorScheme.mutedForeground,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        onPressed: onTap,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
        ),
      ),
    );
  }
}
