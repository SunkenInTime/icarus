import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/replay/replay_agents.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay/replay_weapons.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum ReplayEventKind { kill, plant, defuse, detonation }

/// Something that happened in a round: a kill, or the spike planted,
/// defused or detonating. The killfeed lists them; the scrubber marks them.
class ReplayRoundEvent {
  const ReplayRoundEvent._(
    this.kind,
    this.timeMs, {
    this.kill,
    this.subject,
    this.site,
  });

  final ReplayEventKind kind;
  final int timeMs;

  /// The kill, for a kill.
  final ReplayKill? kill;

  /// Who planted or defused, when the replay says.
  final String? subject;

  /// Where the spike was planted, for a plant or a detonation.
  final String? site;
}

/// [round]'s events in the order they happened; a kill comes before a
/// spike event in the same millisecond.
List<ReplayRoundEvent> replayRoundEvents(
  ReplayDocument document,
  ReplayRound round,
) {
  final plant = round.plant;
  final defuse = round.defuse;
  final detonateMs = round.detonateMs;
  // The round runs on past its end, through the post-round, until the next
  // one starts; a death there is still this round's.
  final nextStartMs = document.rounds
      .where((next) => next.index == round.index + 1)
      .firstOrNull
      ?.startMs;
  final events = [
    for (final kill in document.kills)
      if (kill.timeMs >= round.startMs &&
          (nextStartMs == null || kill.timeMs < nextStartMs))
        ReplayRoundEvent._(ReplayEventKind.kill, kill.timeMs, kill: kill),
    if (plant != null)
      ReplayRoundEvent._(
        ReplayEventKind.plant,
        plant.timeMs,
        subject: plant.subject,
        site: plant.site,
      ),
    if (defuse != null)
      ReplayRoundEvent._(
        ReplayEventKind.defuse,
        defuse.timeMs,
        subject: defuse.subject,
      ),
    if (detonateMs != null)
      ReplayRoundEvent._(
        ReplayEventKind.detonation,
        detonateMs,
        site: plant?.site,
      ),
  ];
  mergeSort(events, compare: (a, b) => a.timeMs.compareTo(b.timeMs));
  return events;
}

/// The glyph for how a round ended. The killfeed draws a defuse and a
/// detonation with the same glyphs, and a plant with [replaySpikeIcon].
IconData replayRoundEndIcon(ReplayRoundEnd end) => switch (end) {
      ReplayRoundEnd.elimination => LucideIcons.skull,
      ReplayRoundEnd.detonated => LucideIcons.flame,
      ReplayRoundEnd.defused => LucideIcons.scissors,
      ReplayRoundEnd.time => LucideIcons.timer,
      ReplayRoundEnd.surrender => LucideIcons.flag,
    };

const IconData replaySpikeIcon = LucideIcons.bomb;

/// One event as the killfeed shows it: the time since barriers dropped,
/// then who did what. A kill reads killer, assists, what killed, victim.
/// The scrubber's hover card draws this same line.
class ReplayEventLine extends StatelessWidget {
  const ReplayEventLine({
    super.key,
    required this.event,
    required this.playback,
  });

  final ReplayRoundEvent event;
  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final round = playback.round;
    final since =
        round == null ? event.timeMs : event.timeMs - round.playStartMs;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 36,
          child: Text(
            replayClockLabel(since),
            style: theme.textTheme.muted.copyWith(fontSize: 11),
          ),
        ),
        ...switch (event.kind) {
          ReplayEventKind.kill => _kill(event.kill!),
          ReplayEventKind.plant => [
              ..._actor(event.subject),
              _glyph(replaySpikeIcon),
              ..._site(theme),
            ],
          ReplayEventKind.defuse => [
              ..._actor(event.subject),
              _glyph(replayRoundEndIcon(ReplayRoundEnd.defused)),
            ],
          ReplayEventKind.detonation => [
              _glyph(replayRoundEndIcon(ReplayRoundEnd.detonated)),
              ..._site(theme),
            ],
        },
      ],
    );
  }

  List<Widget> _kill(ReplayKill kill) {
    final document = playback.document;
    final killer = document.playerBySubject(kill.killer);
    final source = _source(
      kill.damageSource,
      replayAgentType(killer?.agentId),
    );
    final victim = _AgentIcon(
      player: document.playerBySubject(kill.victim),
      perspective: playback.perspective,
    );
    // A fall or the spike: no killer, just what killed, or a skull when
    // that isn't known, so the row still reads as a death.
    if (kill.killer == null) {
      return [
        source ?? _glyph(LucideIcons.skull),
        const SizedBox(width: 6),
        victim,
      ];
    }
    return [
      _AgentIcon(player: killer, perspective: playback.perspective),
      for (final assist in kill.assists) ...[
        const SizedBox(width: 2),
        Opacity(
          opacity: 0.6,
          child: _AgentIcon(
            player: document.playerBySubject(assist),
            perspective: playback.perspective,
            size: 14,
          ),
        ),
      ],
      const SizedBox(width: 6),
      source ??
          Icon(
            LucideIcons.crosshair,
            size: 12,
            color: Settings.tacticalVioletTheme.mutedForeground,
          ),
      const SizedBox(width: 6),
      victim,
    ];
  }

  /// The gun or the ability that killed, or null when the source is unknown.
  static Widget? _source(String? damageSource, AgentType? killer) {
    final weapon = replayWeaponType(damageSource);
    if (weapon != WeaponType.none) {
      // The silhouettes point left; turned, the barrel faces the victim.
      return Transform.flip(
        flipX: true,
        child: Image.asset(weapon.iconPath, height: 12),
      );
    }
    final ability = replayKillAbility(damageSource, killer);
    if (ability != null) {
      return Image.asset(ability.iconPath, width: 16, height: 16);
    }
    return null;
  }

  List<Widget> _actor(String? subject) {
    final player = playback.document.playerBySubject(subject);
    if (player == null) return const [];
    return [
      _AgentIcon(player: player, perspective: playback.perspective),
      const SizedBox(width: 6),
    ];
  }

  static Widget _glyph(IconData icon) => Icon(
        icon,
        size: 16,
        color: Settings.tacticalVioletTheme.mutedForeground,
      );

  List<Widget> _site(ShadThemeData theme) {
    final site = event.site;
    if (site == null) return const [];
    return [
      const SizedBox(width: 4),
      Text(
        site,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.mutedForeground,
        ),
      ),
    ];
  }
}

/// A player as their agent's icon, bordered in their team's colour: the
/// replay has no names, and both teams can field the same agent.
class _AgentIcon extends StatelessWidget {
  const _AgentIcon({
    required this.player,
    required this.perspective,
    this.size = 22,
  });

  final ReplayPlayer? player;
  final ReplayTeam perspective;
  final double size;

  @override
  Widget build(BuildContext context) {
    final agent = player == null ? null : replayAgentType(player!.agentId);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.secondary,
        borderRadius: BorderRadius.circular(size < 22 ? 3 : 4),
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
