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
/// detonation with the same glyphs, and a plant with the spike
/// ([replaySpikeAsset]).
IconData replayRoundEndIcon(ReplayRoundEnd end) => switch (end) {
      ReplayRoundEnd.elimination => LucideIcons.skull,
      ReplayRoundEnd.detonated => LucideIcons.flame,
      ReplayRoundEnd.defused => LucideIcons.scissors,
      ReplayRoundEnd.time => LucideIcons.timer,
      ReplayRoundEnd.surrender => LucideIcons.flag,
    };

/// Valorant's spike, the art the map draws a planted spike with.
const String replaySpikeAsset = 'assets/spike.svg';

/// How big an event line draws its parts. Everything but the clock and the
/// gaps follows the portrait.
class _LineSizes {
  const _LineSizes({
    required this.clock,
    required this.clockFont,
    required this.portrait,
    required this.gap,
  });

  /// The scrubber's hover card: as small as the line still reads.
  static const compact =
      _LineSizes(clock: 36, clockFont: 11, portrait: 22, gap: 6);

  /// A line [width] wide, as the killfeed draws it: the portraits take a
  /// sixth of what the clock leaves, so the line grows with its panel.
  factory _LineSizes.across(double width) {
    const clock = 40.0;
    return _LineSizes(
      clock: clock,
      clockFont: 12,
      portrait: ((width - clock) / 6).clamp(22.0, 40.0).floorToDouble(),
      gap: 8,
    );
  }

  final double clock;
  final double clockFont;
  final double portrait;
  final double gap;

  double get assist => (portrait * 0.64).roundToDouble();
  double get weapon => (portrait * 0.55).roundToDouble();

  /// An ability's icon, or a glyph standing for the event.
  double get glyph => (portrait * 0.73).roundToDouble();
  double get siteFont => (portrait * 0.55).roundToDouble().clamp(12, 16);
}

/// One event as the killfeed shows it: the time since barriers dropped,
/// then who did what. A kill reads killer, assists, what killed, victim.
/// The scrubber's hover card draws this same line, small.
class ReplayEventLine extends StatelessWidget {
  const ReplayEventLine({
    super.key,
    required this.event,
    required this.playback,
    this.fill = false,
  });

  final ReplayRoundEvent event;
  final ReplayPlayback playback;

  /// Whether the line spans its width, as the killfeed draws it: who acted
  /// on the left, the victim on the right edge, what happened centred
  /// between them, all sized to the room. Otherwise it is as narrow as it
  /// reads, for the hover card.
  final bool fill;

  @override
  Widget build(BuildContext context) {
    if (!fill) return _line(context, _LineSizes.compact);
    return LayoutBuilder(
      builder: (context, constraints) =>
          _line(context, _LineSizes.across(constraints.maxWidth)),
    );
  }

  Widget _line(BuildContext context, _LineSizes sizes) {
    final theme = ShadTheme.of(context);
    final round = playback.round;
    final since =
        round == null ? event.timeMs : event.timeMs - round.playStartMs;
    final (actor, what, victim) = switch (event.kind) {
      ReplayEventKind.kill => _kill(event.kill!, sizes),
      ReplayEventKind.plant => (
          _actor(event.subject, sizes),
          [_spike(sizes), ..._site(theme, sizes)],
          null,
        ),
      ReplayEventKind.defuse => (
          _actor(event.subject, sizes),
          [_glyph(replayRoundEndIcon(ReplayRoundEnd.defused), sizes)],
          null,
        ),
      ReplayEventKind.detonation => (
          null,
          [
            _glyph(replayRoundEndIcon(ReplayRoundEnd.detonated), sizes),
            ..._site(theme, sizes),
          ],
          null,
        ),
    };
    final clock = SizedBox(
      width: sizes.clock,
      child: Text(
        replayClockLabel(since),
        style: theme.textTheme.muted.copyWith(
          fontSize: sizes.clockFont,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    if (!fill) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          clock,
          if (actor != null) ...[actor, SizedBox(width: sizes.gap)],
          ...what,
          if (victim != null) ...[SizedBox(width: sizes.gap), victim],
        ],
      );
    }
    // An empty side keeps its room, so what happened stays centred.
    final empty = SizedBox(width: sizes.portrait);
    return Row(
      children: [
        clock,
        actor ?? empty,
        SizedBox(width: sizes.gap),
        Expanded(
          child: Center(
            // Four assists can crowd the gun; it shrinks rather than spill.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisSize: MainAxisSize.min, children: what),
            ),
          ),
        ),
        SizedBox(width: sizes.gap),
        victim ?? empty,
      ],
    );
  }

  /// Who killed with their assists, what killed, and who died.
  (Widget?, List<Widget>, Widget) _kill(ReplayKill kill, _LineSizes sizes) {
    final document = playback.document;
    final killer = document.playerBySubject(kill.killer);
    final source = _source(
      kill.damageSource,
      replayAgentType(killer?.agentId),
      sizes,
    );
    final victim = _AgentIcon(
      player: document.playerBySubject(kill.victim),
      perspective: playback.perspective,
      size: sizes.portrait,
    );
    // A fall or the spike: no killer, just what killed, or a skull when
    // that isn't known, so the row still reads as a death.
    if (kill.killer == null) {
      return (null, [source ?? _glyph(LucideIcons.skull, sizes)], victim);
    }
    final actor = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _AgentIcon(
          player: killer,
          perspective: playback.perspective,
          size: sizes.portrait,
        ),
        for (final assist in kill.assists) ...[
          const SizedBox(width: 2),
          Opacity(
            opacity: 0.6,
            child: _AgentIcon(
              player: document.playerBySubject(assist),
              perspective: playback.perspective,
              size: sizes.assist,
            ),
          ),
        ],
      ],
    );
    return (
      actor,
      [
        source ??
            Icon(
              LucideIcons.crosshair,
              size: sizes.weapon,
              color: Settings.tacticalVioletTheme.mutedForeground,
            ),
      ],
      victim,
    );
  }

  /// The gun or the ability that killed, or null when the source is unknown.
  static Widget? _source(
    String? damageSource,
    AgentType? killer,
    _LineSizes sizes,
  ) {
    final weapon = replayWeaponType(damageSource);
    if (weapon != WeaponType.none) {
      // The silhouettes point left; turned, the barrel faces the victim.
      return Transform.flip(
        flipX: true,
        child: Image.asset(weapon.iconPath, height: sizes.weapon),
      );
    }
    final ability = replayKillAbility(damageSource, killer);
    if (ability != null) {
      return Image.asset(
        ability.iconPath,
        width: sizes.glyph,
        height: sizes.glyph,
      );
    }
    return null;
  }

  Widget? _actor(String? subject, _LineSizes sizes) {
    final player = playback.document.playerBySubject(subject);
    if (player == null) return null;
    return _AgentIcon(
      player: player,
      perspective: playback.perspective,
      size: sizes.portrait,
    );
  }

  static Widget _glyph(IconData icon, _LineSizes sizes) => Icon(
        icon,
        size: sizes.glyph,
        color: Settings.tacticalVioletTheme.mutedForeground,
      );

  /// The spike, in the muted ink of the other event glyphs.
  static Widget _spike(_LineSizes sizes) => SvgPicture.asset(
        replaySpikeAsset,
        height: sizes.glyph,
        colorFilter: ColorFilter.mode(
          Settings.tacticalVioletTheme.mutedForeground,
          BlendMode.srcIn,
        ),
      );

  List<Widget> _site(ShadThemeData theme, _LineSizes sizes) {
    final site = event.site;
    if (site == null) return const [];
    return [
      const SizedBox(width: 4),
      Text(
        site,
        style: TextStyle(
          fontSize: sizes.siteFont,
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
        borderRadius: BorderRadius.circular(
          size < 22
              ? 3
              : size < 28
                  ? 4
                  : 6,
        ),
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
