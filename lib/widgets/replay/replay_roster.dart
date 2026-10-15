import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/replay/replay_agents.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay/replay_weapons.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:icarus/widgets/replay/replay_select.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Both teams as they stand right now, then the round's kills.
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
        playback.document.kills
            .where((kill) => kill.timeMs >= round.startMs && kill.timeMs <= now)
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

/// One player as they stand. Clicking the row watches them; the watched
/// player's row is raised and ringed in violet.
class _PlayerRow extends StatefulWidget {
  const _PlayerRow({
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
          child: _content(theme, agentData, name, weapon, credits),
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

/// This round's kills so far, newest first. Clicking one replays it.
class _Killfeed extends StatelessWidget {
  const _Killfeed({required this.playback});

  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final round = playback.round;
    final now = playback.timeMs;
    final kills = [
      for (final kill in playback.document.kills)
        if (round != null && kill.timeMs >= round.startMs && kill.timeMs <= now)
          kill,
    ].reversed.toList();
    if (kills.isEmpty) {
      return Center(
        child: Text('No kills yet this round', style: theme.textTheme.muted),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: kills.length,
      itemBuilder: (context, index) => _KillRow(
        kill: kills[index],
        playback: playback,
      ),
    );
  }
}

class _KillRow extends StatelessWidget {
  const _KillRow({required this.kill, required this.playback});

  final ReplayKill kill;
  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final document = playback.document;
    final killer = document.playerBySubject(kill.killer);
    final victim = document.playerBySubject(kill.victim);
    final round = playback.round;
    final since = round == null ? kill.timeMs : kill.timeMs - round.playStartMs;
    return ShadButton.ghost(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      mainAxisAlignment: MainAxisAlignment.start,
      onPressed: () => playback.seek(kill.timeMs - 2000),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              replayClockLabel(since),
              style: theme.textTheme.muted.copyWith(fontSize: 11),
            ),
          ),
          _KillIcon(player: killer, perspective: playback.perspective),
          const SizedBox(width: 6),
          Icon(
            LucideIcons.crosshair,
            size: 12,
            color: theme.colorScheme.mutedForeground,
          ),
          const SizedBox(width: 6),
          _KillIcon(player: victim, perspective: playback.perspective),
        ],
      ),
    );
  }
}

class _KillIcon extends StatelessWidget {
  const _KillIcon({required this.player, required this.perspective});

  final ReplayPlayer? player;
  final ReplayTeam perspective;

  @override
  Widget build(BuildContext context) {
    final agent = player == null ? null : replayAgentType(player!.agentId);
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.secondary,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: player?.team?.colorFor(perspective) ??
              Settings.tacticalVioletTheme.border,
        ),
      ),
      child:
          agent == null ? null : Image.asset(AgentData.agents[agent]!.iconPath),
    );
  }
}
