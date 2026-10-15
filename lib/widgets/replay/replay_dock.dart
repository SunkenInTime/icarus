import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/replay/replay_events.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:icarus/widgets/replay/replay_select.dart';
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
      // Only the clock and the scrubber change every frame; the rest
      // rebuilds when what it shows does.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReplaySelect(
            listenable: playback,
            select: () => (playback.round?.index, playback.perspective),
            builder: (context, _) => _RoundStrip(playback: playback),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ReplaySelect(
                listenable: playback,
                select: () => playback.playing,
                builder: (context, playing) => ShadIconButton.ghost(
                  width: 32,
                  height: 32,
                  onPressed: playback.togglePlaying,
                  icon: Icon(
                    playing ? LucideIcons.pause : LucideIcons.play,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 40,
                child: ListenableBuilder(
                  listenable: playback,
                  builder: (context, _) => Text(
                    _roundClock(playback),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ListenableBuilder(
                  listenable: playback,
                  builder: (context, _) => _RoundScrubber(playback: playback),
                ),
              ),
              const SizedBox(width: 12),
              ReplaySelect(
                listenable: playback,
                select: () => playback.speed,
                builder: (context, _) => _SpeedButton(playback: playback),
              ),
            ],
          ),
        ],
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

/// One chip per round, filled with the winner's colour and marked with how
/// the round ended; a gap where the teams swap sides.
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
      height: 30,
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
    final ink = selected ? theme.foreground : theme.mutedForeground;
    final end = round.endReason;
    return ShadTooltip(
      builder: (context) => Text(_outcome(round, perspective)),
      // A Shad gesture detector, so the tooltip hears the hover.
      child: ShadGestureDetector(
        cursor: SystemMouseCursors.click,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 22,
          height: 30,
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
          // The number keeps its place whether or not an outcome is known.
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${round.index + 1}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
              const SizedBox(height: 2),
              SizedBox.square(
                dimension: 10,
                child: end == null
                    ? null
                    : Icon(replayRoundEndIcon(end), size: 10, color: ink),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "Round 7 · Won · Spike defused on A", from [perspective]'s side.
  static String _outcome(ReplayRound round, ReplayTeam perspective) {
    final winner = round.winningTeam;
    final plant = round.plant;
    final on = plant?.site == null ? '' : ' on ${plant!.site}';
    final afterPlant = plant == null ? '' : ' after plant$on';
    final ending = switch (round.endReason) {
      null => null,
      ReplayRoundEnd.elimination => 'Elimination$afterPlant',
      ReplayRoundEnd.detonated => 'Spike detonated$on',
      ReplayRoundEnd.defused => 'Spike defused$on',
      ReplayRoundEnd.time => 'Time ran out$afterPlant',
      ReplayRoundEnd.surrender => 'Surrender$afterPlant',
    };
    return [
      'Round ${round.index + 1}',
      if (winner != null) winner == perspective ? 'Won' : 'Lost',
      if (ending != null) ending,
    ].join(' · ');
  }
}

/// The round being watched, start to end. Drag or click to move through it;
/// ticks mark kills (in the killer's team colour), the plant, the defuse
/// and the detonation. Hovering a mark shows its killfeed line above it.
class _RoundScrubber extends StatefulWidget {
  const _RoundScrubber({required this.playback});

  final ReplayPlayback playback;

  @override
  State<_RoundScrubber> createState() => _RoundScrubberState();
}

class _RoundScrubberState extends State<_RoundScrubber> {
  /// How near, in pixels, the pointer must come to a mark to show its card.
  static const _hoverReach = 6.0;

  final _card = OverlayPortalController();
  final _link = LayerLink();

  ReplayRound? _eventsRound;
  List<ReplayRoundEvent> _events = const [];

  /// The mark under the pointer, and where along the track it sits.
  ReplayRoundEvent? _hovered;
  double _hoveredX = 0;

  /// [round]'s events, worked out once per round rather than every frame.
  List<ReplayRoundEvent> _eventsOf(ReplayRound? round) {
    if (!identical(round, _eventsRound)) {
      _eventsRound = round;
      _events = round == null
          ? const []
          : replayRoundEvents(widget.playback.document, round);
    }
    return _events;
  }

  void _hover(ReplayRoundEvent? event, double x) {
    if (!mounted || (event == _hovered && x == _hoveredX)) return;
    setState(() {
      _hovered = event;
      _hoveredX = x;
    });
    event == null ? _card.hide() : _card.show();
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final round = playback.round;
    final start = round?.startMs ?? 0;
    final end = round?.endMs ?? playback.durationMs;
    final span = (end - start).clamp(1, 1 << 31);
    final events = _eventsOf(round);

    void seekTo(Offset local, double width) {
      final fraction = (local.dx / width).clamp(0.0, 1.0);
      playback.seek(start + (span * fraction).round());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double x(int ms) => ((ms - start) / span).clamp(0.0, 1.0) * width;

        void hoverAt(double dx) {
          ReplayRoundEvent? nearest;
          var nearestX = 0.0;
          var distance = double.infinity;
          for (final event in events) {
            final eventX = x(event.timeMs);
            final d = (eventX - dx).abs();
            if (d <= _hoverReach && d < distance) {
              nearest = event;
              nearestX = eventX;
              distance = d;
            }
          }
          _hover(nearest, nearestX);
        }

        return CompositedTransformTarget(
          link: _link,
          child: OverlayPortal(
            controller: _card,
            overlayChildBuilder: _buildCard,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onHover: (event) => hoverAt(event.localPosition.dx),
              onExit: (_) => _hover(null, 0),
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
                      events: events,
                      start: start,
                      span: span,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The hovered mark's killfeed line, in a card centred above it.
  Widget _buildCard(BuildContext context) {
    final hovered = _hovered;
    // Play can carry the clock into the next round under a still pointer.
    if (hovered == null || !_events.contains(hovered)) {
      return const SizedBox.shrink();
    }
    final theme = ShadTheme.of(context);
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomCenter,
        offset: Offset(_hoveredX, -4),
        child: IgnorePointer(
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.popover,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.border),
              boxShadow: const [Settings.floatingMenuShadow],
            ),
            child: DefaultTextStyle(
              style: theme.textTheme.muted,
              child: ReplayEventLine(event: hovered, playback: widget.playback),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScrubberPainter extends CustomPainter {
  _ScrubberPainter({
    required this.playback,
    required this.events,
    required this.start,
    required this.span,
  })  : timeMs = playback.timeMs,
        perspective = playback.perspective;

  final ReplayPlayback playback;
  final List<ReplayRoundEvent> events;
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
      Path diamond(double px) => Path()
        ..moveTo(px, midY - 8)
        ..lineTo(px + 5, midY)
        ..lineTo(px, midY + 8)
        ..lineTo(px - 5, midY)
        ..close();
      for (final event in events) {
        final ex = x(event.timeMs);
        switch (event.kind) {
          case ReplayEventKind.kill:
            final kill = event.kill!;
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
                ex - 1.5,
                midY - 7,
                ex + 1.5,
                midY + 7,
                const Radius.circular(1.5),
              ),
              Paint()..color = color,
            );
          case ReplayEventKind.plant:
            canvas.drawPath(diamond(ex), Paint()..color = theme.foreground);
          // The plant's diamond, emptied.
          case ReplayEventKind.defuse:
            canvas.drawPath(
              diamond(ex),
              Paint()
                ..color = theme.foreground
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5,
            );
          // A four-pointed burst.
          case ReplayEventKind.detonation:
            final burst = Path()
              ..moveTo(ex, midY - 8)
              ..lineTo(ex + 2, midY - 2)
              ..lineTo(ex + 7, midY)
              ..lineTo(ex + 2, midY + 2)
              ..lineTo(ex, midY + 8)
              ..lineTo(ex - 2, midY + 2)
              ..lineTo(ex - 7, midY)
              ..lineTo(ex - 2, midY - 2)
              ..close();
            canvas.drawPath(burst, Paint()..color = theme.foreground);
        }
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
