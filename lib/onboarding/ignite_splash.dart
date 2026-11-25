import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/onboarding/intro_parts.dart';
import 'package:icarus/onboarding/page_loader.dart';
import 'package:icarus/onboarding/wordmark_glyphs.dart';
import 'package:icarus/widgets/window_chrome.dart';

abstract final class IgniteTimeline {
  static const double igniteEnd = 340;
  static const double resolveStart = 320;
  static const double resolveEnd = 660;
  static const double lettersStart = 520;
  static const double letterStagger = 45;
  static const double letterDuration = 240;
  static const double holdEnd = 1200;
  static const double total = 1620;
  static const Duration stillHold = Duration(milliseconds: 500);
  static const Duration loaderLights = Duration(milliseconds: 160);
}

class IgniteSplash extends StatefulWidget {
  const IgniteSplash({
    super.key,
    required this.findHome,
    required this.onDone,
    this.onLeaving,
    this.afterLoader = false,
  });

  final Rect? Function() findHome;
  final VoidCallback onDone;
  final VoidCallback? onLeaving;
  final bool afterLoader;

  static const double lockupHeight = 40;
  static const double latticeSize = 96;
  static const int latticeColumns = 18;

  static List<String> litRows(Path mark) {
    final dots = _LatticeDot.over(mark, latticeColumns);
    return [
      for (var row = 0; row < latticeColumns; row++)
        [
          for (var column = 0; column < latticeColumns; column++)
            dots[row * latticeColumns + column].lit ? '1' : '0',
        ].join(),
    ];
  }

  @override
  State<IgniteSplash> createState() => _IgniteSplashState();
}

class _IgniteSplashState extends State<IgniteSplash>
    with TickerProviderStateMixin {
  late final AnimationController _clock;
  WordmarkGlyphs? _glyphs;
  List<_LatticeDot> _lattice = const [];
  Rect? _home;
  bool _lookedForHome = false;
  bool _leaving = false;
  bool _still = false;
  Timer? _stillTimer;
  Timer? _handOver;
  Ticker? _calm;

  double get _ms => _clock.value * IgniteTimeline.total;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1620),
    )
      ..addListener(_leave)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onDone();
      });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_glyphs != null) return;
    final still = MediaQuery.disableAnimationsOf(context);
    WordmarkGlyphs.load(DefaultAssetBundle.of(context)).then((glyphs) {
      if (!mounted || _glyphs != null) return;
      setState(() {
        _glyphs = glyphs;
        _lattice = _LatticeDot.over(glyphs.mark, IgniteSplash.latticeColumns);
        _still = still;
      });
      if (still) {
        _clock.value = IgniteTimeline.holdEnd / IgniteTimeline.total;
        _stillTimer = Timer(IgniteTimeline.stillHold, _clock.forward);
        _takeOver();
      } else {
        if (widget.afterLoader) {
          _clock.value = IgniteTimeline.igniteEnd / IgniteTimeline.total;
        }
        _calm = whenFramesAreCalm(this, () {
          _takeOver();
          if (widget.afterLoader) {
            _handOver = Timer(IgniteTimeline.loaderLights, _clock.forward);
          } else {
            _clock.forward();
          }
        });
      }
    });
  }

  void _leave() {
    if (_ms < IgniteTimeline.holdEnd - 0.5) return;
    if (!_leaving) {
      setState(() => _leaving = true);
      widget.onLeaving?.call();
    }
    if (_lookedForHome || _still) return;
    _lookedForHome = true;
    _home = widget.findHome();
  }

  void _takeOver() {
    if (widget.afterLoader) releasePageLoader();
  }

  void _skip() {
    if (_glyphs == null || _ms >= IgniteTimeline.holdEnd) return;
    _stillTimer?.cancel();
    _handOver?.cancel();
    _calm?.stop();
    _takeOver();
    _clock
      ..value = IgniteTimeline.holdEnd / IgniteTimeline.total
      ..forward();
  }

  @override
  void dispose() {
    _takeOver();
    _handOver?.cancel();
    _stillTimer?.cancel();
    _calm?.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glyphs = _glyphs;
    return KeyCapture(
      onKey: (event) {
        if (event is KeyDownEvent) _skip();
      },
      child: Listener(
        behavior:
            _leaving ? HitTestBehavior.translucent : HitTestBehavior.opaque,
        onPointerDown: (_) => _skip(),
        child: Semantics(
          label: 'Icarus',
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (glyphs == null)
                ColoredBox(color: Settings.tacticalVioletTheme.background)
              else
                AnimatedBuilder(
                  animation: _clock,
                  builder: (context, _) => CustomPaint(
                    painter: _IgnitePainter(
                      ms: _ms,
                      glyphs: glyphs,
                      lattice: _lattice,
                      home: _home,
                    ),
                  ),
                ),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: kWindowStripHeight,
                child: Row(
                  children: [
                    Expanded(child: WindowDragArea(child: SizedBox.expand())),
                    WindowCaptionButtons(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _LatticeDot {
  const _LatticeDot({
    required this.at,
    required this.lit,
    required this.height,
    required this.grain,
  });

  final Offset at;
  final bool lit;
  final double height;
  final double grain;

  static const double _markShare = 0.84;

  static double side(Rect markBounds) => markBounds.longestSide / _markShare;

  static List<_LatticeDot> over(Path mark, int columns) {
    final bounds = mark.getBounds();
    final span = side(bounds);
    final spacing = span / columns;
    final origin = bounds.center - Offset(span / 2, span / 2);
    return [
      for (var row = 0; row < columns; row++)
        for (var column = 0; column < columns; column++)
          () {
            final at = origin +
                Offset((column + 0.5) * spacing, (row + 0.5) * spacing);
            final seed = math.sin(column * 12.9898 + row * 78.233) * 43758.5453;
            return _LatticeDot(
              at: at,
              lit: mark.contains(at),
              height: ((bounds.bottom - at.dy) / bounds.height).clamp(0.0, 1.0),
              grain: seed - seed.floorToDouble(),
            );
          }(),
    ];
  }
}

double _smoothstep(double from, double to, double x) {
  final u = ((x - from) / (to - from)).clamp(0.0, 1.0);
  return u * u * (3 - 2 * u);
}

class _IgnitePainter extends CustomPainter {
  _IgnitePainter({
    required this.ms,
    required this.glyphs,
    required this.lattice,
    required this.home,
  });

  final double ms;
  final WordmarkGlyphs glyphs;
  final List<_LatticeDot> lattice;
  final Rect? home;

  static final Color _ink = Settings.tacticalVioletTheme.foreground;
  static final Color _ember = Settings.tacticalVioletTheme.selection;
  static final Color _flame = Settings.tacticalVioletTheme.primary;
  static final Color _unlit =
      Settings.tacticalVioletTheme.border.withValues(alpha: 0.45);

  @override
  void paint(Canvas canvas, Size size) {
    final leave =
        eased(ms, IgniteTimeline.holdEnd, IgniteTimeline.holdEnd + 300);
    final travel = home == null
        ? 0.0
        : eased(ms, IgniteTimeline.holdEnd, IgniteTimeline.total);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Settings.tacticalVioletTheme.background
            .withValues(alpha: 1 - leave),
    );

    final box = glyphs.viewBox;
    final resting = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: IgniteSplash.lockupHeight * box.width / box.height,
      height: IgniteSplash.lockupHeight,
    );
    final lockup = Rect.lerp(resting, home ?? resting, travel)!;
    final lockupScale = lockup.height / box.height;
    final lockupOpacity = home == null ? 1 - leave : 1.0;
    Offset onScreen(Offset units) =>
        lockup.topLeft + (units - box.topLeft) * lockupScale;

    final markBounds = glyphs.mark.getBounds();
    final resolve =
        eased(ms, IgniteTimeline.resolveStart, IgniteTimeline.resolveEnd);
    final markScale = lerpDouble(
      IgniteSplash.latticeSize / _LatticeDot.side(markBounds),
      lockupScale,
      resolve,
    )!;
    final markCenter = Offset.lerp(
      size.center(Offset.zero),
      onScreen(markBounds.center),
      resolve,
    )!;

    _paintLattice(canvas, markBounds, markScale, markCenter, resolve);

    final solid = eased(
          ms,
          IgniteTimeline.resolveStart + 120,
          IgniteTimeline.resolveEnd,
        ) *
        lockupOpacity;
    if (solid > 0) {
      canvas
        ..save()
        ..translate(markCenter.dx, markCenter.dy)
        ..scale(markScale)
        ..translate(-markBounds.center.dx, -markBounds.center.dy)
        ..drawPath(
          glyphs.mark,
          Paint()..color = _ink.withValues(alpha: solid),
        )
        ..restore();
    }

    final markLeft = onScreen(markBounds.centerLeft).dx;
    final markRight = onScreen(markBounds.centerRight).dx;
    final ranked = _rankedByDistance(markBounds.center.dx);
    for (final (rank, letter) in ranked) {
      final start =
          IgniteTimeline.lettersStart + rank * IgniteTimeline.letterStagger;
      final arrive = eased(ms, start, start + IgniteTimeline.letterDuration);
      if (arrive <= 0) continue;
      final leftOfMark = letter.getBounds().center.dx < markBounds.center.dx;
      final slide = (leftOfMark ? 1 : -1) * (1 - arrive) * lockup.height * 0.55;
      canvas
        ..save()
        ..clipRect(
          leftOfMark
              ? Rect.fromLTRB(0, 0, markLeft, size.height)
              : Rect.fromLTRB(markRight, 0, size.width, size.height),
        )
        ..translate(lockup.left + slide, lockup.top)
        ..scale(lockupScale)
        ..translate(-box.left, -box.top)
        ..drawPath(
          letter,
          Paint()..color = _ink.withValues(alpha: arrive * lockupOpacity),
        )
        ..restore();
    }
  }

  List<(int, Path)> _rankedByDistance(double markX) {
    final left = <Path>[];
    final right = <Path>[];
    for (final letter in glyphs.letters) {
      (letter.getBounds().center.dx < markX ? left : right).add(letter);
    }
    return [
      for (var i = 0; i < left.length; i++) (left.length - 1 - i, left[i]),
      for (var i = 0; i < right.length; i++) (i, right[i]),
    ];
  }

  void _paintLattice(
    Canvas canvas,
    Rect markBounds,
    double scale,
    Offset center,
    double resolve,
  ) {
    final dots = 1 -
        eased(
          ms,
          IgniteTimeline.resolveStart + 180,
          IgniteTimeline.resolveEnd,
        );
    if (dots <= 0) return;
    final rest = 1 -
        eased(
          ms,
          IgniteTimeline.resolveStart,
          IgniteTimeline.resolveStart + 140,
        );
    final spacing =
        _LatticeDot.side(markBounds) / IgniteSplash.latticeColumns * scale;
    final radius = spacing * 0.46;
    final catching = (ms / IgniteTimeline.igniteEnd).clamp(0.0, 1.0);
    final paint = Paint();
    for (final dot in lattice) {
      final at = center + (dot.at - markBounds.center) * scale;
      final threshold = dot.height * 0.72 + dot.grain * 0.12;
      final lit = dot.lit
          ? _smoothstep(threshold, threshold + 0.22, catching * 1.06)
          : 0.0;
      if (lit < 0.03) {
        if (rest <= 0) continue;
        canvas.drawCircle(
          at,
          radius * 0.22,
          paint..color = _unlit.withValues(alpha: _unlit.a * rest),
        );
        continue;
      }
      final heat = math.max(
        _smoothstep(threshold, threshold + 0.45, catching * 1.25),
        resolve,
      );
      final color = heat < 0.5
          ? Color.lerp(_ember, _flame, heat / 0.5)!
          : Color.lerp(_flame, _ink, (heat - 0.5) / 0.5)!;
      canvas.drawCircle(
        at,
        radius * math.sqrt(lit) * lerpDouble(1, 1.6, resolve)!,
        paint..color = color.withValues(alpha: dots),
      );
    }
  }

  @override
  bool shouldRepaint(_IgnitePainter old) => old.ms != ms || old.home != home;
}
