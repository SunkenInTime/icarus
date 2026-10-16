import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/replay/replay_events.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:icarus/widgets/replay/replay_select.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Whether the dock shows the match's rounds above playback, kept while the
/// app is open.
final replayRoundsShownProvider = StateProvider<bool>((ref) => true);

/// Whether the scrubber opens into the round's story: who killed when, and
/// the spike. Kept while the app is open; it starts closed.
final replayRoundStoryProvider = StateProvider<bool>((ref) => false);

/// Playback along the bottom of the map, as a stack of small surfaces with
/// the map showing between them: every round of the match on top, then the
/// round being watched with its kills and plant marked. Both share the
/// round strip's width, so hiding the strip moves nothing.
class ReplayDock extends ConsumerWidget {
  const ReplayDock({super.key, required this.playback});

  final ReplayPlayback playback;

  /// The narrowest the playback row gets, whatever the match: a 21-round
  /// match's strip. Below it the scrubber gets too short to tell kills a
  /// second apart, and a shorter match's strip only hugs its slots above.
  static const minPlaybackWidth = 560.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roundsShown = ref.watch(replayRoundsShownProvider);
    final story = ref.watch(replayRoundStoryProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth;
        final strip = _RoundStrip.naturalWidth(playback.document.rounds);
        final width = math.min(room, math.max(strip, minPlaybackWidth));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (roundsShown) ...[
              _Surface(
                // Too many rounds for the room: the strip scrolls.
                width: math.min(strip, room),
                child: ReplaySelect(
                  listenable: playback,
                  select: () => (playback.round?.index, playback.perspective),
                  builder: (context, _) => _RoundStrip(playback: playback),
                ),
              ),
              const SizedBox(height: 4),
            ],
            _Surface(
              width: width,
              child: _PlaybackRow(
                playback: playback,
                story: story,
                roundsShown: roundsShown,
                onStory: () => ref
                    .read(replayRoundStoryProvider.notifier)
                    .update((open) => !open),
                onRounds: () => ref
                    .read(replayRoundsShownProvider.notifier)
                    .update((shown) => !shown),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One row of the dock: a card of its own, so the map shows around it.
class _Surface extends StatelessWidget {
  const _Surface({required this.width, required this.child});

  static const padding = 5.0;

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: child,
    );
  }
}

/// Play, the round's clock, the scrubber and the speed, then the two
/// switches for what the dock shows. Only the clock and the scrubber change
/// every frame; the rest rebuilds when what it shows does.
class _PlaybackRow extends StatelessWidget {
  const _PlaybackRow({
    required this.playback,
    required this.story,
    required this.roundsShown,
    required this.onStory,
    required this.onRounds,
  });

  final ReplayPlayback playback;
  final bool story;
  final bool roundsShown;
  final VoidCallback onStory;
  final VoidCallback onRounds;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Row(
      spacing: 4,
      children: [
        ReplaySelect(
          listenable: playback,
          select: () => playback.playing,
          builder: (context, playing) => ShadIconButton.ghost(
            width: 24,
            height: 24,
            padding: EdgeInsets.zero,
            onPressed: playback.togglePlaying,
            icon: Icon(
              playing ? LucideIcons.pause : LucideIcons.play,
              size: 16,
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: ListenableBuilder(
            listenable: playback,
            builder: (context, _) => Text(
              _roundClock(playback),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        Expanded(child: _RoundScrubber(playback: playback, story: story)),
        ReplaySelect(
          listenable: playback,
          select: () => playback.speed,
          builder: (context, _) => _SpeedButton(playback: playback),
        ),
        Container(
          width: 1,
          height: 16,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          color: theme.input,
        ),
        _ViewToggle(
          icon: story ? LucideIcons.chevronsDownUp : LucideIcons.chevronsUpDown,
          tooltip: story ? 'Hide round story' : 'Show round story',
          onPressed: onStory,
        ),
        // At the row's end, where it stays whether the rounds show or not,
        // so a second click undoes the first.
        _ViewToggle(
          icon: roundsShown ? LucideIcons.chevronDown : LucideIcons.chevronUp,
          tooltip: roundsShown ? 'Hide rounds' : 'Show rounds',
          onPressed: onRounds,
        ),
      ],
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

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return ShadTooltip(
      builder: (context) => Text(tooltip),
      child: ShadIconButton.ghost(
        width: 24,
        height: 24,
        padding: EdgeInsets.zero,
        foregroundColor: theme.mutedForeground,
        hoverForegroundColor: theme.foreground,
        onPressed: onPressed,
        icon: Icon(icon, size: 14),
      ),
    );
  }
}

/// Where the round strip breaks: before the second half, where the teams
/// first swap sides, and before overtime, as long again after it. The swaps
/// every overtime round get no break.
({int? half, int? overtime}) _breaks(List<ReplayRound> rounds) {
  for (var i = 1; i < rounds.length; i++) {
    if (rounds[i - 1].attackingTeam != rounds[i].attackingTeam) {
      return (half: i, overtime: 2 * i < rounds.length ? 2 * i : null);
    }
  }
  return (half: null, overtime: null);
}

/// One slot per round, showing how it ended on the winner's colour, with a
/// thin divider at the half and "OT" before overtime. A hairline rail below
/// numbers the first round, every fifth, and the second half's first.
class _RoundStrip extends StatelessWidget {
  const _RoundStrip({required this.playback});

  final ReplayPlayback playback;

  static const _slot = 24.0;
  static const _gap = 2.0;
  static const _half = 8.0;
  static const _overtime = 18.0;

  /// The strip's surface wide enough for every slot, unscrolled.
  static double naturalWidth(List<ReplayRound> rounds) {
    final (:half, :overtime) = _breaks(rounds);
    var width = rounds.length * _slot;
    var items = rounds.length;
    if (half != null) {
      width += _half;
      items++;
    }
    if (overtime != null) {
      width += _overtime;
      items++;
    }
    width += math.max(0, items - 1) * _gap;
    // The surface's padding and border.
    return width + 2 * _Surface.padding + 2;
  }

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final rounds = playback.document.rounds;
    final current = playback.round?.index;
    final (:half, :overtime) = _breaks(rounds);
    final children = <Widget>[];
    for (var i = 0; i < rounds.length; i++) {
      final round = rounds[i];
      if (i == half) {
        children.add(SizedBox(
          width: _half,
          height: _slot,
          child: Center(
            child: Container(width: 1, height: 18, color: theme.input),
          ),
        ));
      } else if (i == overtime) {
        children.add(SizedBox(
          width: _overtime,
          height: _slot,
          child: Center(
            child: Text(
              'OT',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: theme.mutedForeground,
              ),
            ),
          ),
        ));
      }
      final number = i + 1;
      children.add(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RoundSlot(
            round: round,
            perspective: playback.perspective,
            selected: round.index == current,
            onTap: () => playback.seekRound(round.index),
          ),
          _RailMark(
            label: i == 0 || i == half || number % 5 == 0 ? '$number' : null,
          ),
        ],
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: _gap,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// The rail under one slot: a hairline, and the round's number when it is
/// one of the rail's landmarks.
class _RailMark extends StatelessWidget {
  const _RailMark({required this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return SizedBox(
      width: _RoundStrip._slot,
      height: 10,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 1,
            height: 1,
            child: ColoredBox(color: theme.input),
          ),
          if (label != null)
            Positioned(
              left: 0,
              right: 0,
              top: 2,
              child: Text(
                label!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 8,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  color: theme.mutedForeground,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundSlot extends StatelessWidget {
  const _RoundSlot({
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
    final end = round.endReason;
    return ShadTooltip(
      builder: (context) => Text(_outcome(round, perspective)),
      // A Shad gesture detector, so the tooltip hears the hover.
      child: ShadGestureDetector(
        cursor: SystemMouseCursors.click,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: _RoundStrip._slot,
          height: _RoundStrip._slot,
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
          alignment: Alignment.center,
          child: end == null
              ? null
              : ReplayRoundEndGlyph(end, size: 14, color: theme.foreground),
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
/// and the detonation, and dots ability uses (in the caster's), as far as
/// the killfeed's filter shows them. Hovering a mark shows its killfeed
/// line above it.
///
/// Opened into the round's story, it grows upward: each kill's killer sits
/// above the line for the watched team's kills and below it for the other
/// team's, and the spike sits on it.
class _RoundScrubber extends ConsumerStatefulWidget {
  const _RoundScrubber({required this.playback, required this.story});

  final ReplayPlayback playback;
  final bool story;

  @override
  ConsumerState<_RoundScrubber> createState() => _RoundScrubberState();
}

class _RoundScrubberState extends ConsumerState<_RoundScrubber> {
  /// How near, in pixels, the pointer must come to a mark to show its card.
  static const _hoverReach = 6.0;

  final _card = OverlayPortalController();
  final _link = LayerLink();

  ReplayRound? _eventsRound;
  Set<ReplayEventFilter>? _eventsFilters;
  List<ReplayRoundEvent> _events = const [];

  List<_StoryMark>? _story;
  List<ReplayRoundEvent>? _storyEvents;
  double? _storyWidth;
  ReplayTeam? _storyPerspective;

  /// The mark under the pointer, and where along the track its card sits.
  ReplayRoundEvent? _hovered;
  double _hoveredX = 0;

  /// [round]'s events that [filters] show, worked out when either changes
  /// rather than every frame.
  List<ReplayRoundEvent> _eventsOf(
    ReplayRound? round,
    Set<ReplayEventFilter> filters,
  ) {
    if (!identical(round, _eventsRound) ||
        !identical(filters, _eventsFilters)) {
      _eventsRound = round;
      _eventsFilters = filters;
      _events = round == null
          ? const []
          : [
              for (final event
                  in replayRoundEvents(widget.playback.document, round))
                if (filters.contains(event.kind.filter)) event,
            ];
    }
    return _events;
  }

  /// Where the story draws [events] across [width], worked out once per
  /// round, filter, width and perspective: swapping sides swaps the lanes.
  List<_StoryMark> _storyOf(
    List<ReplayRoundEvent> events,
    double Function(int ms) x,
    double width,
  ) {
    final perspective = widget.playback.perspective;
    if (!identical(events, _storyEvents) ||
        width != _storyWidth ||
        perspective != _storyPerspective) {
      _storyEvents = events;
      _storyWidth = width;
      _storyPerspective = perspective;
      _story = _StoryMark.layout(widget.playback, events, x, width);
    }
    return _story!;
  }

  @override
  void didUpdateWidget(_RoundScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The marks move when the story opens or closes; the card would point
    // at where one was. Without a mark the card draws nothing.
    if (oldWidget.story != widget.story) _hovered = null;
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
    final filters = ref.watch(replayEventFiltersProvider);
    // Rebuilt when the round changes; within it, the painters follow the
    // clock on their own.
    return ReplaySelect(
      listenable: playback,
      select: () => (playback.round, playback.perspective),
      builder: (context, _) {
        final round = playback.round;
        final start = round?.startMs ?? 0;
        final end = round?.endMs ?? playback.durationMs;
        final span = (end - start).clamp(1, 1 << 31);
        final events = _eventsOf(round, filters);
        return LayoutBuilder(
          builder: (context, constraints) => _track(
            events,
            start,
            span,
            constraints.maxWidth,
          ),
        );
      },
    );
  }

  Widget _track(
    List<ReplayRoundEvent> events,
    int start,
    int span,
    double width,
  ) {
    final playback = widget.playback;
    final story = widget.story;
    double x(int ms) => ((ms - start) / span).clamp(0.0, 1.0) * width;
    final marks = story ? _storyOf(events, x, width) : null;

    void seekTo(double dx) {
      final fraction = (dx / width).clamp(0.0, 1.0);
      playback.seek(start + (span * fraction).round());
    }

    /// The mark under [local], and where its card goes.
    (ReplayRoundEvent, double)? markAt(Offset local) {
      if (marks != null) return _StoryMark.hit(marks, local, _hoverReach);
      ReplayRoundEvent? nearest;
      var nearestX = 0.0;
      var distance = double.infinity;
      for (final event in events) {
        final eventX = x(event.timeMs);
        final d = (eventX - local.dx).abs();
        if (d <= _hoverReach && d < distance) {
          nearest = event;
          nearestX = eventX;
          distance = d;
        }
      }
      return nearest == null ? null : (nearest, nearestX);
    }

    void hoverAt(Offset local) {
      final mark = markAt(local);
      _hover(mark?.$1, mark?.$2 ?? 0);
    }

    final painter = _ScrubberPainter(
      playback: playback,
      events: story ? const [] : events,
      start: start,
      span: span,
    );
    final playhead = _PlayheadPainter(
      playback: playback,
      start: start,
      span: span,
      story: story,
    );
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _card,
        overlayChildBuilder: _buildCard,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (event) => hoverAt(event.localPosition),
          onExit: (_) => _hover(null, 0),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              // In the story, a killer pushed aside from their tick still
              // goes to their kill.
              final mark = marks == null ? null : markAt(details.localPosition);
              mark == null
                  ? seekTo(details.localPosition.dx)
                  : playback.seek(mark.$1.timeMs);
            },
            onHorizontalDragUpdate: (details) =>
                seekTo(details.localPosition.dx),
            // The track repaints every frame; nothing around it need.
            child: RepaintBoundary(
              child: SizedBox(
                height: story ? _StoryMark.height : 24,
                child: CustomPaint(
                  painter: painter,
                  foregroundPainter: playhead,
                  child: marks == null
                      ? const SizedBox.expand()
                      : RepaintBoundary(
                          // Marks still ahead are drawn faint; this
                          // rebuilds only as the playhead passes one.
                          child: ReplaySelect(
                            listenable: playback,
                            select: () => _passed(events, playback.timeMs),
                            builder: (context, passed) => _StoryMarks(
                              playback: playback,
                              marks: marks,
                              passed: passed,
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// How many of [events], in time order, have happened by [timeMs].
  static int _passed(List<ReplayRoundEvent> events, int timeMs) {
    var passed = 0;
    while (passed < events.length && events[passed].timeMs <= timeMs) {
      passed++;
    }
    return passed;
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

/// The colour a mark takes for [team]'s doing, as the watched team sees it.
Color _teamInk(ReplayTeam? team, ReplayTeam perspective) => team == null
    ? Settings.tacticalVioletTheme.mutedForeground
    : team == perspective
        ? Settings.allyInk
        : Settings.enemyInk;

/// The team a kill counts for: the killer's, or for a fall or a spike death,
/// the other team's.
ReplayTeam? _scoringTeam(ReplayPlayback playback, ReplayKill kill) {
  final document = playback.document;
  return document.playerBySubject(kill.killer)?.team ??
      document.playerBySubject(kill.victim)?.team?.other;
}

/// How faint a mark still ahead of the playhead is drawn.
const _aheadOpacity = 0.55;

/// The track along the middle and how far through the round the playhead
/// is; at rest, the round's marks on it too. Repaints with the clock.
class _ScrubberPainter extends CustomPainter {
  _ScrubberPainter({
    required this.playback,
    required this.events,
    required this.start,
    required this.span,
  })  : perspective = playback.perspective,
        super(repaint: playback);

  final ReplayPlayback playback;

  /// The marks to draw on the track; none when the story draws them.
  final List<ReplayRoundEvent> events;
  final int start;
  final int span;
  final ReplayTeam perspective;

  @override
  void paint(Canvas canvas, Size size) {
    const theme = Settings.tacticalVioletTheme;
    final midY = size.height / 2;
    final timeMs = playback.timeMs;
    double x(int ms) => ((ms - start) / span).clamp(0.0, 1.0) * size.width;
    Color ahead(Color color, int ms) =>
        ms > timeMs ? color.withValues(alpha: _aheadOpacity) : color;

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
    if (round == null) return;
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
    // Ability uses first, and small, so kills and the spike stay on top.
    for (final event in events) {
      if (event.kind != ReplayEventKind.ability) continue;
      final team = playback.document.playerBySubject(event.subject)?.team;
      canvas.drawCircle(
        Offset(x(event.timeMs), midY),
        2.5,
        Paint()..color = ahead(_teamInk(team, perspective), event.timeMs),
      );
    }
    for (final event in events) {
      final ex = x(event.timeMs);
      final ink = ahead(theme.foreground, event.timeMs);
      switch (event.kind) {
        case ReplayEventKind.ability:
          break;
        case ReplayEventKind.kill:
          canvas.drawRRect(
            RRect.fromLTRBR(
              ex - 1.5,
              midY - 7,
              ex + 1.5,
              midY + 7,
              const Radius.circular(1.5),
            ),
            Paint()
              ..color = ahead(
                _teamInk(_scoringTeam(playback, event.kill!), perspective),
                event.timeMs,
              ),
          );
        case ReplayEventKind.plant:
          canvas.drawPath(diamond(ex), Paint()..color = ink);
        // The plant's diamond, emptied.
        case ReplayEventKind.defuse:
          canvas.drawPath(
            diamond(ex),
            Paint()
              ..color = ink
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
          canvas.drawPath(burst, Paint()..color = ink);
      }
    }
  }

  @override
  bool shouldRepaint(_ScrubberPainter old) =>
      !identical(old.playback, playback) ||
      !identical(old.events, events) ||
      old.start != start ||
      old.span != span ||
      old.perspective != perspective;
}

/// The playhead, over every mark; in the story, a faint line through the
/// whole track too, to read the portraits against.
class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter({
    required this.playback,
    required this.start,
    required this.span,
    required this.story,
  }) : super(repaint: playback);

  final ReplayPlayback playback;
  final int start;
  final int span;
  final bool story;

  @override
  void paint(Canvas canvas, Size size) {
    const theme = Settings.tacticalVioletTheme;
    final x = ((playback.timeMs - start) / span).clamp(0.0, 1.0) * size.width;
    if (story) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = theme.foreground.withValues(alpha: 0.45)
          ..strokeWidth = 1,
      );
    }
    canvas.drawCircle(
      Offset(x, size.height / 2),
      6,
      Paint()..color = theme.foreground,
    );
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) =>
      !identical(old.playback, playback) ||
      old.start != start ||
      old.span != span ||
      old.story != story;
}

/// Where the story draws one event: its tick on the line, and for a kill
/// with a known killer, the killer's portrait above the line (the watched
/// team's kills) or below it (the other team's), pushed sideways off
/// others in its lane.
class _StoryMark {
  const _StoryMark(
    this.event,
    this.tick, {
    this.portrait,
    this.above,
    this.spike,
  });

  static const height = 64.0;
  static const portraitSize = 22.0;

  /// Centre to centre, the closest two portraits in a lane sit.
  static const portraitGap = 24.0;

  /// The circle the spike's marks sit in on the line.
  static const spikeRadius = 11.0;

  final ReplayRoundEvent event;
  final double tick;

  /// The centre of the killer's portrait, along the track.
  final double? portrait;
  final bool? above;

  /// The centre of a plant's, defuse's or detonation's circle, along the
  /// track: on its tick, or held inside the track at either end.
  final double? spike;

  static const mid = height / 2;

  Rect? get portraitRect => portrait == null
      ? null
      : Rect.fromLTWH(
          portrait! - portraitSize / 2,
          above! ? 0 : height - portraitSize,
          portraitSize,
          portraitSize,
        );

  static bool _onLine(ReplayRoundEvent event) => switch (event.kind) {
        ReplayEventKind.plant ||
        ReplayEventKind.defuse ||
        ReplayEventKind.detonation =>
          true,
        _ => false,
      };

  static List<_StoryMark> layout(
    ReplayPlayback playback,
    List<ReplayRoundEvent> events,
    double Function(int ms) x,
    double width,
  ) {
    final document = playback.document;
    final lanes = <bool, List<ReplayRoundEvent>>{true: [], false: []};
    for (final event in events) {
      if (event.kind != ReplayEventKind.kill) continue;
      final team = document.playerBySubject(event.kill!.killer)?.team;
      if (team != null) lanes[team == playback.perspective]!.add(event);
    }
    final placed = <ReplayRoundEvent, (double, bool)>{};
    for (final MapEntry(key: above, value: kills) in lanes.entries) {
      final centres = replayStoryLane(
        [for (final kill in kills) x(kill.timeMs)],
        width,
        gap: portraitGap,
        size: portraitSize,
      );
      for (var i = 0; i < kills.length; i++) {
        placed[kills[i]] = (centres[i], above);
      }
    }
    // A defuse at the round's very end would hang half outside the track,
    // over the speed button.
    final spikeRange = math.max(spikeRadius, width - spikeRadius);
    return [
      for (final event in events)
        _StoryMark(
          event,
          x(event.timeMs),
          portrait: placed[event]?.$1,
          above: placed[event]?.$2,
          spike: _onLine(event)
              ? x(event.timeMs).clamp(spikeRadius, spikeRange)
              : null,
        ),
    ];
  }

  /// The mark under [local] and where its card goes: a spike mark or a
  /// portrait under the pointer, the one drawn on top where they overlap,
  /// else the nearest tick or dot within [reach] along the line.
  static (ReplayRoundEvent, double)? hit(
    List<_StoryMark> marks,
    Offset local,
    double reach,
  ) {
    for (final mark in marks.reversed) {
      final spike = mark.spike;
      if (spike != null &&
          (local - Offset(spike, mid)).distance <= spikeRadius) {
        return (mark.event, spike);
      }
    }
    for (final mark in marks.reversed) {
      final rect = mark.portraitRect;
      if (rect != null && rect.contains(local)) {
        return (mark.event, rect.center.dx);
      }
    }
    if ((local.dy - mid).abs() > 8) return null;
    _StoryMark? nearest;
    var distance = double.infinity;
    for (final mark in marks) {
      final d = (mark.tick - local.dx).abs();
      if (d <= reach && d < distance) {
        nearest = mark;
        distance = d;
      }
    }
    return nearest == null ? null : (nearest.event, nearest.tick);
  }
}

/// Where one lane's portraits go, centre by centre, for [ticks] in
/// ascending order: at its tick where there is room, else pushed apart to
/// [gap] as evenly as it takes, kept inside [width]. With more than fit,
/// they close up evenly.
List<double> replayStoryLane(
  List<double> ticks,
  double width, {
  required double gap,
  required double size,
}) {
  if (ticks.isEmpty) return const [];
  final lo = size / 2;
  final hi = math.max(lo, width - size / 2);
  final step = ticks.length < 2
      ? gap
      : math.min(gap, (hi - lo) / (ticks.length - 1));
  // Runs of portraits that touch, each centred on its ticks' average.
  final runs = <({int first, int count, double sum})>[];
  double left(({int first, int count, double sum}) run) {
    final span = (run.count - 1) * step;
    final centre = (run.sum / run.count).clamp(lo + span / 2, hi - span / 2);
    return centre - span / 2;
  }

  for (var i = 0; i < ticks.length; i++) {
    runs.add((first: i, count: 1, sum: ticks[i]));
    while (runs.length > 1) {
      final last = runs[runs.length - 1];
      final before = runs[runs.length - 2];
      final beforeEnd = left(before) + (before.count - 1) * step;
      if (left(last) - beforeEnd >= step - 1e-6) break;
      runs
        ..removeLast()
        ..removeLast()
        ..add((
          first: before.first,
          count: before.count + last.count,
          sum: before.sum + last.sum,
        ));
    }
  }
  return [
    for (final run in runs)
      for (var i = 0; i < run.count; i++) left(run) + i * step,
  ];
}

/// The story's marks for one round: ability dots and kill ticks on the
/// line, each killer's portrait with a stem back to its tick, and the
/// spike's marks over the line. Rebuilt per round, per filter, and as the
/// playhead passes a mark.
class _StoryMarks extends StatelessWidget {
  const _StoryMarks({
    required this.playback,
    required this.marks,
    required this.passed,
  });

  final ReplayPlayback playback;

  /// In time order.
  final List<_StoryMark> marks;

  /// How many of [marks] have happened.
  final int passed;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    Widget faint(int index, Widget child) => index >= passed
        ? Opacity(opacity: _aheadOpacity, child: child)
        : child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _StoryPainter(
              playback: playback,
              marks: marks,
              passed: passed,
            ),
          ),
        ),
        for (final (i, mark) in marks.indexed)
          if (mark.portraitRect case final rect?)
            Positioned(
              left: rect.left - 2,
              top: rect.top - 2,
              child: faint(
                i,
                // A ring of the card's colour lifts it off the line.
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: theme.card,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: ReplayAgentIcon(
                    player: playback.document
                        .playerBySubject(mark.event.kill!.killer),
                    perspective: playback.perspective,
                    size: _StoryMark.portraitSize,
                  ),
                ),
              ),
            ),
        for (final (i, mark) in marks.indexed)
          if (mark.spike case final spike?)
            Positioned(
              left: spike - _StoryMark.spikeRadius,
              top: _StoryMark.mid - _StoryMark.spikeRadius,
              child: faint(i, _SpikeMark(kind: mark.event.kind)),
            ),
      ],
    );
  }
}

/// A plant, defuse or detonation on the story's line, in a small circle.
class _SpikeMark extends StatelessWidget {
  const _SpikeMark({required this.kind});

  final ReplayEventKind kind;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      width: 2 * _StoryMark.spikeRadius,
      height: 2 * _StoryMark.spikeRadius,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.card,
        shape: BoxShape.circle,
        border: Border.all(color: theme.foreground),
      ),
      child: switch (kind) {
        ReplayEventKind.defuse => ReplayRoundEndGlyph(
            ReplayRoundEnd.defused,
            size: 14,
            color: theme.foreground,
          ),
        ReplayEventKind.detonation => ReplayRoundEndGlyph(
            ReplayRoundEnd.detonated,
            size: 14,
            color: theme.foreground,
          ),
        _ => SvgPicture.asset(
            replaySpikeAsset,
            height: 12,
            colorFilter: ColorFilter.mode(theme.foreground, BlendMode.srcIn),
          ),
      },
    );
  }
}

/// The story's ability dots, kill ticks and stems.
class _StoryPainter extends CustomPainter {
  _StoryPainter({
    required this.playback,
    required this.marks,
    required this.passed,
  });

  final ReplayPlayback playback;
  final List<_StoryMark> marks;
  final int passed;

  @override
  void paint(Canvas canvas, Size size) {
    const mid = _StoryMark.mid;
    final perspective = playback.perspective;
    Color faint(Color color, int index) => index >= passed
        ? color.withValues(alpha: _aheadOpacity)
        : color;
    for (final (i, mark) in marks.indexed) {
      if (mark.event.kind != ReplayEventKind.ability) continue;
      final team = playback.document.playerBySubject(mark.event.subject)?.team;
      canvas.drawCircle(
        Offset(mark.tick, mid),
        2.5,
        Paint()..color = faint(_teamInk(team, perspective), i),
      );
    }
    for (final (i, mark) in marks.indexed) {
      if (mark.event.kind != ReplayEventKind.kill) continue;
      final ink = faint(
        _teamInk(_scoringTeam(playback, mark.event.kill!), perspective),
        i,
      );
      final rect = mark.portraitRect;
      if (rect != null) {
        canvas.drawLine(
          Offset(mark.tick, mid),
          Offset(rect.center.dx, mark.above! ? rect.bottom : rect.top),
          Paint()
            ..color = ink
            ..strokeWidth = 1,
        );
      }
      canvas.drawRRect(
        RRect.fromLTRBR(
          mark.tick - 1.5,
          mid - 6,
          mark.tick + 1.5,
          mid + 6,
          const Radius.circular(1.5),
        ),
        Paint()..color = ink,
      );
    }
    // A spike mark held inside the track keeps a line at its true moment.
    for (final (i, mark) in marks.indexed) {
      final spike = mark.spike;
      if (spike == null || spike == mark.tick) continue;
      canvas.drawLine(
        Offset(mark.tick, mid - _StoryMark.spikeRadius - 3),
        Offset(mark.tick, mid + _StoryMark.spikeRadius + 3),
        Paint()
          ..color = faint(Settings.tacticalVioletTheme.foreground, i)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_StoryPainter old) =>
      !identical(old.marks, marks) || old.passed != passed;
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
        height: 24,
        width: 40,
        padding: EdgeInsets.zero,
        onPressed: () => playback.speed = next,
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}
