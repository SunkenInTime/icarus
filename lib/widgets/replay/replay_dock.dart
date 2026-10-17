import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_drawing.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/replay/replay_events.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:icarus/widgets/replay/replay_select.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Whether the round's story stays open: who killed when, and the spike.
/// Unpinned, it opens only while the pointer rests on the dock. Kept while
/// the app is open; it starts unpinned.
final replayRoundStoryProvider = StateProvider<bool>((ref) => false);

/// Playback along the bottom of the map, in one card: every round of the
/// match on top, then the round being watched with its kills and plant
/// marked. The card is as wide as the rounds, no narrower than a usable
/// scrubber and no wider than a full regulation match; overtime past that
/// scrolls.
///
/// Resting the pointer on the playback row opens the round's story, unless
/// the pen is out; it closes a moment after the pointer leaves the dock,
/// but not mid-drag. Resting on the rounds opens nothing: they move up as
/// the story opens, and would slide out from under a click.
class ReplayDock extends ConsumerStatefulWidget {
  const ReplayDock({super.key, required this.playback, this.drawing});

  final ReplayPlayback playback;

  /// The pen; while it is out the story never opens on its own.
  final ReplayDrawing? drawing;

  /// The narrowest the playback row gets, whatever the match: a 21-round
  /// match's strip. Below it the scrubber gets too short to tell kills a
  /// second apart, and a shorter match's strip only hugs its slots above.
  static const minPlaybackWidth = 560.0;

  /// The widest the card gets: a full regulation match's 24 rounds. Past it
  /// the playback row would only stretch, so overtime's rounds scroll.
  static final maxWidth = _RoundStrip.widthOf(24, half: 12);

  /// How long the pointer rests on the dock before the story opens; a
  /// pass across it is quicker.
  static const peekDwell = Duration(milliseconds: 200);

  /// How long after the pointer leaves the story stays open, so a slip off
  /// the edge doesn't shut it.
  static const peekLinger = Duration(milliseconds: 400);

  /// How long the story takes to grow open or fold shut.
  static const storyDuration = Duration(milliseconds: 200);

  /// How far below the dock its own margin from the window's edge is when
  /// the story is closed. The open story takes half of it, so the line it
  /// grows around moves only a few pixels.
  static const _margin = 4.0;

  /// The card's padding inside its border.
  static const _padding = 5.0;

  @override
  ConsumerState<ReplayDock> createState() => _ReplayDockState();
}

class _ReplayDockState extends ConsumerState<ReplayDock>
    with SingleTickerProviderStateMixin {
  Timer? _dwell;
  Timer? _linger;
  bool _inside = false;
  bool _overPlayback = false;
  bool _peeking = false;

  /// Whether the scrubber holds the story open: a drag, or a hover card.
  bool _held = false;

  /// How far open the story is, 0 to 1; it slows into both ends.
  late final _storyController = AnimationController(
    vsync: this,
    duration: ReplayDock.storyDuration,
    // A pinned story is open from the first frame.
    value: ref.read(replayRoundStoryProvider) ? 1 : 0,
  );
  late final _story = CurvedAnimation(
    parent: _storyController,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeOutCubic.flipped,
  );

  bool get _penOut => widget.drawing?.active ?? false;

  @override
  void initState() {
    super.initState();
    widget.drawing?.addListener(_penChanged);
  }

  @override
  void didUpdateWidget(ReplayDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drawing != widget.drawing) {
      oldWidget.drawing?.removeListener(_penChanged);
      widget.drawing?.addListener(_penChanged);
    }
  }

  @override
  void dispose() {
    widget.drawing?.removeListener(_penChanged);
    _dwell?.cancel();
    _linger?.cancel();
    _story.dispose();
    _storyController.dispose();
    super.dispose();
  }

  /// Opens or closes the story to match the pin and the peek, leaving it
  /// be when it is already on its way there.
  void _showStory() {
    if (!mounted) return;
    final open = ref.read(replayRoundStoryProvider) || _peeking;
    if (open == _storyController.status.isForwardOrCompleted) return;
    open ? _storyController.forward() : _storyController.reverse();
  }

  void _penChanged() {
    if (_penOut) {
      _close();
    } else if (_overPlayback) {
      // Put away under a still pointer, the pen leaves it resting there.
      _restOnPlayback();
    }
  }

  void _enter() {
    _inside = true;
    _linger?.cancel();
  }

  void _exit() {
    _inside = false;
    _dwell?.cancel();
    _closeSoon();
  }

  void _restOnPlayback() {
    if (_peeking || _penOut) return;
    _dwell?.cancel();
    _dwell = Timer(ReplayDock.peekDwell, () {
      if (!_inside || _penOut) return;
      _peeking = true;
      _showStory();
    });
  }

  void _closeSoon() {
    if (!_peeking || _held) return;
    _linger?.cancel();
    _linger = Timer(ReplayDock.peekLinger, () {
      if (!_inside && !_held) _close();
    });
  }

  void _close() {
    _dwell?.cancel();
    _linger?.cancel();
    _peeking = false;
    _showStory();
  }

  void _hold(bool held) {
    if (_held == held) return;
    _held = held;
    if (!held && !_inside) _closeSoon();
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final theme = ShadTheme.of(context);
    final pinned = ref.watch(replayRoundStoryProvider);
    ref.listen(replayRoundStoryProvider, (_, __) => _showStory());
    const padding = ReplayDock._padding;
    return MouseRegion(
      // The margin under the card counts as the dock, but the map under it
      // still hears the pointer.
      hitTestBehavior: HitTestBehavior.translucent,
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final room = constraints.maxWidth;
          final strip = _RoundStrip.naturalWidth(playback.document.rounds);
          final width = math.min(
            room,
            strip.clamp(ReplayDock.minPlaybackWidth, ReplayDock.maxWidth),
          );
          return AnimatedBuilder(
            animation: _story,
            // The rounds keep still while the story opens under them.
            child: ReplaySelect(
              listenable: playback,
              select: () => (playback.round?.index, playback.perspective),
              // Too many rounds for the room: the strip scrolls.
              builder: (context, _) => _RoundStrip(playback: playback),
            ),
            builder: (context, rounds) {
              final open = _story.value;
              return Padding(
                padding: EdgeInsets.only(
                  bottom: ReplayDock._margin * (1 - open),
                ),
                child: Container(
                  width: width,
                  // The open story's lower lane reaches the border, so the
                  // scrubber answers over every portrait it draws.
                  padding: EdgeInsets.fromLTRB(
                    padding,
                    padding,
                    padding,
                    padding * (1 - open),
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.border),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      rounds!,
                      const SizedBox(height: 4),
                      MouseRegion(
                        onEnter: (_) {
                          _overPlayback = true;
                          _restOnPlayback();
                        },
                        onExit: (_) {
                          _overPlayback = false;
                          _dwell?.cancel();
                        },
                        child: _PlaybackRow(
                          playback: playback,
                          open: open,
                          pinned: pinned,
                          onHold: _hold,
                          onPin: () => ref
                              .read(replayRoundStoryProvider.notifier)
                              .update((pinned) => !pinned),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Play, the round's clock, the scrubber and the speed, then the pin that
/// keeps the round's story open. Only the clock and the scrubber change
/// every frame; the rest rebuilds when what it shows does.
class _PlaybackRow extends StatelessWidget {
  const _PlaybackRow({
    required this.playback,
    required this.open,
    required this.pinned,
    required this.onHold,
    required this.onPin,
  });

  final ReplayPlayback playback;

  /// How far open the round's story is, 0 to 1.
  final double open;
  final bool pinned;
  final ValueChanged<bool> onHold;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    // The controls stay level with the scrubber's line, which the story
    // grows around.
    final lift = (_StoryMark.height - _StoryMark.mid - 12) * open;
    Widget level(Widget child) => Padding(
          padding: EdgeInsets.only(bottom: lift),
          child: child,
        );
    return Row(
      spacing: 4,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        level(ReplaySelect(
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
        )),
        level(SizedBox(
          width: 40,
          height: 24,
          child: Center(
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
        )),
        Expanded(
          child: _RoundScrubber(
            playback: playback,
            open: open,
            onHold: onHold,
          ),
        ),
        level(ReplaySelect(
          listenable: playback,
          select: () => playback.speed,
          builder: (context, _) => _SpeedButton(playback: playback),
        )),
        level(Container(
          width: 1,
          height: 16,
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          color: theme.input,
        )),
        // Resting on the dock opens the story; the pin keeps it open.
        level(_ViewToggle(
          icon: LucideIcons.pin,
          checked: pinned,
          tooltip: pinned ? 'Unpin round story' : 'Pin round story',
          onPressed: onPin,
        )),
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
    this.checked = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// Drawn in violet, the checked item's colour.
  final bool checked;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return ShadTooltip(
      builder: (context) => Text(tooltip),
      child: ShadIconButton.ghost(
        width: 24,
        height: 24,
        padding: EdgeInsets.zero,
        foregroundColor: checked ? Settings.accentInk : theme.mutedForeground,
        hoverForegroundColor: checked ? Settings.accentInk : theme.foreground,
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
///
/// When the rounds outrun the card, the strip scrolls, by wheel as well as
/// trackpad, and follows the round being watched into view.
class _RoundStrip extends StatefulWidget {
  const _RoundStrip({required this.playback});

  final ReplayPlayback playback;

  static const _slot = 24.0;
  static const _gap = 2.0;
  static const _half = 8.0;
  static const _overtime = 18.0;

  /// The dock's card wide enough for every slot, unscrolled.
  static double naturalWidth(List<ReplayRound> rounds) {
    final (:half, :overtime) = _breaks(rounds);
    return widthOf(rounds.length, half: half, overtime: overtime);
  }

  /// The card wide enough for [count] slots, broken at [half] and
  /// [overtime].
  static double widthOf(int count, {int? half, int? overtime}) =>
      // The card's padding and border either side.
      _slotLeft(count, half: half, overtime: overtime) -
      (count > 0 ? _gap : 0) +
      2 * ReplayDock._padding +
      2;

  /// Where slot [index] starts along the strip.
  static double _slotLeft(int index, {int? half, int? overtime}) {
    var left = index * (_slot + _gap);
    if (half != null && index >= half) left += _half + _gap;
    if (overtime != null && index >= overtime) left += _overtime + _gap;
    return left;
  }

  @override
  State<_RoundStrip> createState() => _RoundStripState();
}

class _RoundStripState extends State<_RoundStrip> {
  final _scroll = ScrollController();

  /// The round last brought into view.
  int? _followed;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls just far enough to show round [index] with a neighbour either
  /// side: at once the first time, smoothly after.
  void _follow(int index, ({int? half, int? overtime}) breaks) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    const slot = _RoundStrip._slot;
    final left = _RoundStrip._slotLeft(
          index,
          half: breaks.half,
          overtime: breaks.overtime,
        ) -
        slot;
    final right = left + 3 * slot;
    final target = (left < position.pixels
            ? left
            : right > position.pixels + position.viewportDimension
                ? right - position.viewportDimension
                : position.pixels)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return;
    _followed == null
        ? _scroll.jumpTo(target)
        : _scroll.animateTo(
            target,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
          );
  }

  /// A plain mouse wheel turns the strip, which on its own only answers to
  /// a sideways scroll; over the strip, the map doesn't zoom.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dx != 0) return;
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.maxScrollExtent == position.minScrollExtent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final delta = (event as PointerScrollEvent).scrollDelta.dy;
      _scroll.jumpTo((position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final playback = widget.playback;
    final rounds = playback.document.rounds;
    final current = playback.round?.index;
    final breaks = _breaks(rounds);
    final (:half, :overtime) = breaks;
    if (current != null && current != _followed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _follow(current, breaks);
        _followed = current;
      });
    }
    final children = <Widget>[];
    for (var i = 0; i < rounds.length; i++) {
      final round = rounds[i];
      if (i == half) {
        children.add(SizedBox(
          width: _RoundStrip._half,
          height: _RoundStrip._slot,
          child: Center(
            child: Container(width: 1, height: 18, color: theme.input),
          ),
        ));
      } else if (i == overtime) {
        children.add(SizedBox(
          width: _RoundStrip._overtime,
          height: _RoundStrip._slot,
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
    return Listener(
      onPointerSignal: _wheel,
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        child: Row(
          spacing: _RoundStrip._gap,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
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
      // Its colour says who won and its glyph how; the number is all the
      // slot itself doesn't show.
      builder: (context) => Text('Round ${round.index + 1}'),
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
}

/// The round being watched, start to end. Drag or click to move through it;
/// ticks mark kills (in the killer's team colour), the plant, the defuse
/// and the detonation, and dots ability uses (in the caster's), as far as
/// the killfeed's filter shows them. Hovering a mark shows its killfeed
/// line above it.
///
/// Opened into the round's story, it grows upward: each kill's killer sits
/// above the line for the watched team's kills and below it for the other
/// team's, and the spike sits on it. While it grows the story's marks fade
/// in over the track's own; the pointer answers to the story only once it
/// is fully open.
class _RoundScrubber extends ConsumerStatefulWidget {
  const _RoundScrubber({
    required this.playback,
    required this.open,
    required this.onHold,
  });

  final ReplayPlayback playback;

  /// How far open the round's story is, 0 to 1.
  final double open;

  /// Told when a drag or a hover card starts or stops holding the story
  /// open.
  final ValueChanged<bool> onHold;

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
    if ((oldWidget.open == 1) != (widget.open == 1) && _hovered != null) {
      _hovered = null;
      widget.onHold(_dragging);
    }
  }

  bool _dragging = false;

  void _hover(ReplayRoundEvent? event, double x) {
    if (!mounted || (event == _hovered && x == _hoveredX)) return;
    setState(() {
      _hovered = event;
      _hoveredX = x;
    });
    event == null ? _card.hide() : _card.show();
    _holding();
  }

  void _drag(bool dragging) {
    _dragging = dragging;
    _holding();
  }

  void _holding() => widget.onHold(_dragging || _hovered != null);

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
    final open = widget.open;
    double x(int ms) => ((ms - start) / span).clamp(0.0, 1.0) * width;
    final marks = open > 0 ? _storyOf(events, x, width) : null;
    // What the pointer hovers and clicks: the story's marks once it is
    // open, else the track's.
    final story = open == 1 ? marks : null;

    void seekTo(double dx) {
      final fraction = (dx / width).clamp(0.0, 1.0);
      playback.seek(start + (span * fraction).round());
    }

    /// The mark under [local], and where its card goes.
    (ReplayRoundEvent, double)? markAt(Offset local) {
      if (story != null) {
        final passed = _passed(events, playback.timeMs);
        return _StoryMark.hit(story, passed, local, _hoverReach);
      }
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

    final line = 12 + (_StoryMark.mid - 12) * open;
    final height = 24 + (_StoryMark.height - 24) * open;
    final painter = _ScrubberPainter(
      playback: playback,
      events: open == 1 ? const [] : events,
      opacity: 1 - open,
      start: start,
      span: span,
      line: line,
    );
    final playhead = _PlayheadPainter(
      playback: playback,
      start: start,
      span: span,
      open: open,
      line: line,
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
              final mark = story == null ? null : markAt(details.localPosition);
              mark == null
                  ? seekTo(details.localPosition.dx)
                  : playback.seek(mark.$1.timeMs);
            },
            onHorizontalDragStart: (_) => _drag(true),
            onHorizontalDragUpdate: (details) =>
                seekTo(details.localPosition.dx),
            onHorizontalDragEnd: (_) => _drag(false),
            onHorizontalDragCancel: () => _drag(false),
            // The track repaints every frame; nothing around it need.
            child: RepaintBoundary(
              child: SizedBox(
                height: height,
                child: CustomPaint(
                  painter: painter,
                  foregroundPainter: playhead,
                  child: marks == null
                      ? const SizedBox.expand()
                      // Laid out for the open story around its line, and
                      // cut to the track while it grows.
                      : Stack(
                          clipBehavior: Clip.hardEdge,
                          children: [
                            Positioned(
                              left: 0,
                              right: 0,
                              top: line - _StoryMark.mid,
                              height: _StoryMark.height,
                              child: Opacity(
                                opacity: open,
                                child: RepaintBoundary(
                                  // Marks still ahead are drawn faint; this
                                  // rebuilds only as the playhead passes one.
                                  child: ReplaySelect(
                                    listenable: playback,
                                    select: () =>
                                        _passed(events, playback.timeMs),
                                    builder: (context, passed) => _StoryMarks(
                                      playback: playback,
                                      marks: marks,
                                      passed: passed,
                                    ),
                                  ),
                                ),
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
    required this.opacity,
    required this.start,
    required this.span,
    required this.line,
  })  : perspective = playback.perspective,
        super(repaint: playback);

  final ReplayPlayback playback;

  /// The marks to draw on the track; none when the story draws them.
  final List<ReplayRoundEvent> events;

  /// How strongly [events] are drawn: they fade as the story opens.
  final double opacity;
  final int start;
  final int span;
  final ReplayTeam perspective;

  /// How far down the track its line runs.
  final double line;

  @override
  void paint(Canvas canvas, Size size) {
    const theme = Settings.tacticalVioletTheme;
    final midY = line;
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
    if (events.isEmpty) return;
    // Faded together, while the story's own marks fade in over them.
    if (opacity < 1) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
      );
    }
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
    if (opacity < 1) canvas.restore();
  }

  @override
  bool shouldRepaint(_ScrubberPainter old) =>
      !identical(old.playback, playback) ||
      !identical(old.events, events) ||
      old.opacity != opacity ||
      old.start != start ||
      old.span != span ||
      old.perspective != perspective ||
      old.line != line;
}

/// The playhead, over every mark; in the story, a faint line through the
/// whole track too, to read the portraits against, coming in as it opens.
class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter({
    required this.playback,
    required this.start,
    required this.span,
    required this.open,
    required this.line,
  }) : super(repaint: playback);

  final ReplayPlayback playback;
  final int start;
  final int span;
  final double open;
  final double line;

  @override
  void paint(Canvas canvas, Size size) {
    const theme = Settings.tacticalVioletTheme;
    final x = ((playback.timeMs - start) / span).clamp(0.0, 1.0) * size.width;
    if (open > 0) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = theme.foreground.withValues(alpha: 0.45 * open)
          ..strokeWidth = 1,
      );
    }
    canvas.drawCircle(
      Offset(x, line),
      6,
      Paint()..color = theme.foreground,
    );
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) =>
      !identical(old.playback, playback) ||
      old.start != start ||
      old.span != span ||
      old.open != open ||
      old.line != line;
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

  /// The open story's height, and how far down it the line runs. The line
  /// sits low, so opening grows the track upward and moves the line only a
  /// few pixels; the row drops its bottom padding to make room below.
  static const height = 54.0;
  static const mid = 27.0;
  static const portraitSize = 22.0;

  /// From the line to the nearer edge of a portrait.
  static const portraitInset = 3.0;

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

  Rect? get portraitRect => portrait == null
      ? null
      : Rect.fromLTWH(
          portrait! - portraitSize / 2,
          above! ? mid - portraitInset - portraitSize : mid + portraitInset,
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

  /// The story's portraits and spike marks bottom to top, as they are
  /// drawn: those already passed, then those still ahead, which fade
  /// together; within each, portraits and then the spike's marks over
  /// them. Drawing and hit-testing both go by this one list.
  static List<_StoryDrawn> drawOrder(List<_StoryMark> marks, int passed) => [
        for (final ahead in const [false, true]) ...[
          for (final (i, mark) in marks.indexed)
            if ((i >= passed) == ahead)
              if (mark.portraitRect case final rect?)
                // With the ring of the card's colour around it.
                _StoryDrawn(mark, rect.inflate(2), ahead: ahead),
          for (final (i, mark) in marks.indexed)
            if ((i >= passed) == ahead)
              if (mark.spike case final spike?)
                _StoryDrawn(
                  mark,
                  Rect.fromCircle(
                    center: Offset(spike, mid),
                    radius: spikeRadius,
                  ),
                  ahead: ahead,
                ),
        ],
      ];

  /// The mark under [local] and where its card goes: the topmost portrait
  /// or spike mark under the pointer, with [passed] of [marks] behind the
  /// playhead, else the nearest tick or dot within [reach] along the line.
  static (ReplayRoundEvent, double)? hit(
    List<_StoryMark> marks,
    int passed,
    Offset local,
    double reach,
  ) {
    for (final drawn in drawOrder(marks, passed).reversed) {
      if (drawn.covers(local)) {
        return (drawn.mark.event, drawn.box.center.dx);
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

/// One of the story's marks drawn over the line, a killer's portrait or a
/// spike mark, and what it covers.
class _StoryDrawn {
  const _StoryDrawn(this.mark, this.box, {required this.ahead});

  final _StoryMark mark;
  final Rect box;

  /// Still ahead of the playhead, so drawn faint.
  final bool ahead;

  bool get isSpike => mark.spike != null;

  bool covers(Offset local) => isSpike
      ? (local - box.center).distance <= box.width / 2
      : box.contains(local);
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
    Widget place(_StoryDrawn drawn) => Positioned.fromRect(
          rect: drawn.box,
          child: drawn.isSpike
              ? _SpikeMark(kind: drawn.mark.event.kind)
              // A ring of the card's colour lifts it off the line.
              : Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: theme.card,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: ReplayAgentIcon(
                    player: playback.document
                        .playerBySubject(drawn.mark.event.kill!.killer),
                    perspective: playback.perspective,
                    size: _StoryMark.portraitSize,
                  ),
                ),
        );
    final drawn = _StoryMark.drawOrder(marks, passed);
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
        for (final mark in drawn)
          if (!mark.ahead) place(mark),
        // Every mark still ahead faded together, one layer, not one each;
        // they come last in the drawing order too.
        if (drawn.any((mark) => mark.ahead))
          Positioned.fill(
            child: Opacity(
              opacity: _aheadOpacity,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final mark in drawn)
                    if (mark.ahead) place(mark),
                ],
              ),
            ),
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
          mid - 4,
          mark.tick + 1.5,
          mid + 4,
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
