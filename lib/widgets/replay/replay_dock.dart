import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Playback along the bottom: every round of the match, then the round being
/// watched with its kills and plant marked.
class ReplayDock extends StatelessWidget {
  const ReplayDock({super.key, required this.playback});

  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 880),
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: ListenableBuilder(
        listenable: playback,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RoundStrip(playback: playback),
            const SizedBox(height: 8),
            Row(
              children: [
                ShadIconButton.ghost(
                  width: 32,
                  height: 32,
                  onPressed: playback.togglePlaying,
                  icon: Icon(
                    playback.playing ? LucideIcons.pause : LucideIcons.play,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 40,
                  child: Text(
                    _roundClock(playback),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _RoundScrubber(playback: playback)),
                const SizedBox(width: 12),
                _SpeedButton(playback: playback),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Time since barriers dropped, counting into negative through the buy.
  static String _roundClock(ReplayPlayback playback) {
    final round = playback.round;
    if (round == null) return replayClockLabel(playback.timeMs);
    final sincePlay = playback.timeMs - round.playStartMs;
    return sincePlay < 0
        ? '-${replayClockLabel(-sincePlay)}'
        : replayClockLabel(sincePlay);
  }
}

/// One chip per round, filled with the winner's colour; a gap where the
/// teams swap sides.
class _RoundStrip extends StatelessWidget {
  const _RoundStrip({required this.playback});

  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context) {
    final rounds = playback.document.rounds;
    final current = playback.round?.index;
    final chips = <Widget>[];
    for (var i = 0; i < rounds.length; i++) {
      final round = rounds[i];
      if (i > 0 && rounds[i - 1].attackingTeam != round.attackingTeam) {
        chips.add(const SizedBox(width: 8));
      }
      chips.add(
        _RoundChip(
          round: round,
          perspective: playback.perspective,
          selected: round.index == current,
          onTap: () => playback.seekRound(round.index),
        ),
      );
    }
    return SizedBox(
      height: 22,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(spacing: 3, children: chips),
      ),
    );
  }
}

class _RoundChip extends StatelessWidget {
  const _RoundChip({
    required this.round,
    required this.perspective,
    required this.selected,
    required this.onTap,
  });

  final ReplayRound round;
  final ReplayTeam perspective;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final winner = round.winningTeam;
    final fill = winner == null
        ? theme.secondary
        : winner == perspective
            ? Settings.allyBGColor
            : Settings.enemyBGColor;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: selected
              ? Settings.raised(fill, 4)
              : BoxDecoration(
                  color: fill.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
          foregroundDecoration: selected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Settings.accentInk, width: 1.5),
                )
              : null,
          child: Text(
            '${round.index + 1}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: selected ? theme.foreground : theme.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

/// The round being watched, start to end. Drag or click to move through it;
/// ticks mark kills (in the killer's team colour) and the plant.
class _RoundScrubber extends StatelessWidget {
  const _RoundScrubber({required this.playback});

  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context) {
    final round = playback.round;
    final start = round?.startMs ?? 0;
    final end = round?.endMs ?? playback.durationMs;
    final span = (end - start).clamp(1, 1 << 31);

    void seekTo(Offset local, double width) {
      final fraction = (local.dx / width).clamp(0.0, 1.0);
      playback.seek(start + (span * fraction).round());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => seekTo(details.localPosition, width),
            onHorizontalDragUpdate: (details) =>
                seekTo(details.localPosition, width),
            child: SizedBox(
              height: 24,
              child: CustomPaint(
                painter: _ScrubberPainter(
                  playback: playback,
                  start: start,
                  span: span,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScrubberPainter extends CustomPainter {
  _ScrubberPainter({
    required this.playback,
    required this.start,
    required this.span,
  })  : timeMs = playback.timeMs,
        perspective = playback.perspective;

  final ReplayPlayback playback;
  final int start;
  final int span;
  final int timeMs;
  final ReplayTeam perspective;

  @override
  void paint(Canvas canvas, Size size) {
    const theme = Settings.tacticalVioletTheme;
    final midY = size.height / 2;
    double x(int ms) => ((ms - start) / span).clamp(0.0, 1.0) * size.width;

    final track = RRect.fromLTRBR(
      0,
      midY - 2,
      size.width,
      midY + 2,
      const Radius.circular(2),
    );
    canvas.drawRRect(track, Paint()..color = theme.secondary);
    canvas.drawRRect(
      RRect.fromLTRBR(
          0, midY - 2, x(timeMs), midY + 2, const Radius.circular(2)),
      Paint()..color = theme.mutedForeground,
    );

    final round = playback.round;
    if (round != null) {
      final play = x(round.playStartMs);
      canvas.drawLine(
        Offset(play, midY - 6),
        Offset(play, midY + 6),
        Paint()
          ..color = theme.mutedForeground
          ..strokeWidth = 1,
      );
      for (final kill in playback.document.kills) {
        if (!round.contains(kill.timeMs)) continue;
        final killer = playback.document.playerBySubject(kill.killer);
        final victim = playback.document.playerBySubject(kill.victim);
        // A kill counts for the killer's team; a fall or spike death for
        // the other team.
        final scoringTeam = killer?.team ?? victim?.team?.other;
        final color = scoringTeam == null
            ? theme.mutedForeground
            : scoringTeam == playback.perspective
                ? Settings.allyInk
                : Settings.enemyInk;
        canvas.drawRRect(
          RRect.fromLTRBR(
            x(kill.timeMs) - 1.5,
            midY - 7,
            x(kill.timeMs) + 1.5,
            midY + 7,
            const Radius.circular(1.5),
          ),
          Paint()..color = color,
        );
      }
      final plant = round.plant;
      if (plant != null) {
        final px = x(plant.timeMs);
        final path = Path()
          ..moveTo(px, midY - 8)
          ..lineTo(px + 5, midY)
          ..lineTo(px, midY + 8)
          ..lineTo(px - 5, midY)
          ..close();
        canvas.drawPath(path, Paint()..color = theme.foreground);
      }
    }

    canvas.drawCircle(
      Offset(x(timeMs), midY),
      6,
      Paint()..color = theme.foreground,
    );
  }

  @override
  bool shouldRepaint(_ScrubberPainter old) =>
      old.timeMs != timeMs ||
      old.start != start ||
      old.span != span ||
      old.perspective != perspective;
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.playback});

  final ReplayPlayback playback;

  @override
  Widget build(BuildContext context) {
    const speeds = ReplayPlayback.speeds;
    final next = speeds[(speeds.indexOf(playback.speed) + 1) % speeds.length];
    final label = playback.speed == playback.speed.roundToDouble()
        ? '${playback.speed.round()}×'
        : '${playback.speed}×';
    return ShadTooltip(
      builder: (context) => const Text('Playback speed'),
      child: ShadButton.outline(
        height: 28,
        width: 44,
        padding: EdgeInsets.zero,
        onPressed: () => playback.speed = next,
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}
