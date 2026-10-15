import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/replay/replay_agents.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay/replay_weapons.dart';
import 'package:icarus/widgets/replay/replay_events.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:icarus/widgets/replay/replay_select.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Both teams as they stand right now, then the round's kills and spike
/// events.
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
      for (final player in playback.document.players)
        if (player.team == team)
          playback.frames.playerState(player, playback.timeMs),
    ];
    final alive = states.where((state) => state.alive).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
          const SizedBox(height: 6),
          for (final state in states)
            _PlayerRow(
              state: state,
              economy: playback.round?.economyFor(state.player.subject),
            ),
        ],
      ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({required this.state, required this.economy});

  final ReplayPlayerState state;
  final ReplayEconomy? economy;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final agent = replayAgentType(state.player.agentId);
    final agentData = agent == null ? null : AgentData.agents[agent];
    final weapon = replayWeaponType(economy?.weapon);
    final name = state.player.name ?? agentData?.name ?? 'Unknown agent';
    final credits = economy?.credits;
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

/// This round's kills and spike events so far, newest first. Clicking one
/// replays it.
class _Killfeed extends StatelessWidget {
  const _Killfeed({required this.playback});

  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final round = playback.round;
    final now = playback.timeMs;
    final events = [
      if (round != null)
        for (final event in replayRoundEvents(playback.document, round))
          if (event.timeMs <= now) event,
    ].reversed.toList();
    if (events.isEmpty) {
      return Center(
        child: Text('No kills yet this round', style: theme.textTheme.muted),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: events.length,
      itemBuilder: (context, index) => ShadButton.ghost(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        mainAxisAlignment: MainAxisAlignment.start,
        onPressed: () => playback.seek(events[index].timeMs - 2000),
        child: ReplayEventLine(event: events[index], playback: playback),
      ),
    );
  }
}
