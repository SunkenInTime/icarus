import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/onboarding/intro_parts.dart';
import 'package:icarus/onboarding/wordmark_glyphs.dart';
import 'package:icarus/widgets/asset_svg.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

abstract final class SunriseTimeline {
  static const double length = 2800;
  static const double riseFrom = 150;
  static const double riseFor = 2600;
  static const double wordsFrom = 500;
  static const double wordEvery = 70;
  static const List<double> pulses = [500, 1000];
  static const double phraseFor = 620;
  static const double pulse = 0.11;
  static const double pulseFades = 320;
  static const double bodyFrom = 1750;
  static const double startFrom = 1950;
  static const double fadeFor = 500;
  static const Duration press = Duration(milliseconds: 700);
  static const double leaveFor = 260;

  static double rise(double ms) => _cubicOut((ms - riseFrom) / riseFor);

  static double pulseAt(double ms) {
    var heat = 0.0;
    for (final beat in pulses) {
      if (ms > beat) heat += pulse * math.exp(-(ms - beat) / pulseFades);
    }
    return heat;
  }

  static double word(int index, double ms) =>
      _quinticOut((ms - wordsFrom - index * wordEvery) / phraseFor);

  static double fadeIn(double ms, double from, [double length = fadeFor]) =>
      _cubicOut((ms - from) / length);

  static double _cubicOut(double x) =>
      1 - math.pow(1 - x.clamp(0.0, 1.0), 3).toDouble();

  static double _quinticOut(double x) =>
      1 - math.pow(1 - x.clamp(0.0, 1.0), 5).toDouble();
}

enum PieceKind { agent, ability, smoke, arrow, loop }

final class Piece {
  const Piece(
    this.kind, {
    required this.onLeft,
    required this.inset,
    required this.y,
    required this.size,
    required this.depth,
    required this.enters,
    this.turn = 0,
    this.art,
    this.ally = true,
  });

  final PieceKind kind;
  final bool onLeft;
  final double inset;
  final double y;
  final double size;
  final double depth;
  final double enters;
  final double turn;
  final String? art;
  final bool ally;
}

abstract final class Scatter {
  static const double designHeight = 900;
  static const double gutter = 400;
  static const double smallest = 0.6;
  static const double entersFor = 700;
  static const double slidesIn = 40;
  static const double bobs = 5;
  static const double sways = 1.5;

  static const List<Piece> pieces = [
    Piece(
      PieceKind.arrow,
      onLeft: true,
      inset: 196,
      y: 590,
      size: 280,
      depth: 5,
      enters: 1500,
    ),
    Piece(
      PieceKind.smoke,
      onLeft: false,
      inset: 268,
      y: 338,
      size: 150,
      depth: 6,
      enters: 1250,
      art: 'assets/agents/Omen/Smoke.webp',
    ),
    Piece(
      PieceKind.loop,
      onLeft: false,
      inset: 322,
      y: 126,
      size: 112,
      depth: 5,
      enters: 1650,
    ),
    Piece(
      PieceKind.ability,
      onLeft: true,
      inset: 318,
      y: 118,
      size: 58,
      depth: 8,
      enters: 1150,
      turn: 7,
      art: 'assets/agents/Jett/2.webp',
    ),
    Piece(
      PieceKind.ability,
      onLeft: true,
      inset: 262,
      y: 352,
      size: 58,
      depth: 7,
      enters: 1350,
      turn: -6,
      art: 'assets/agents/Sova/3.webp',
    ),
    Piece(
      PieceKind.ability,
      onLeft: false,
      inset: 292,
      y: 532,
      size: 58,
      depth: 8,
      enters: 1450,
      turn: 8,
      art: 'assets/agents/Cypher/2.webp',
    ),
    Piece(
      PieceKind.agent,
      onLeft: true,
      inset: 104,
      y: 452,
      size: 90,
      depth: 11,
      enters: 1050,
      turn: 5,
      art: 'assets/agents/Sova/icon.webp',
    ),
    Piece(
      PieceKind.agent,
      onLeft: false,
      inset: 110,
      y: 470,
      size: 92,
      depth: 11,
      enters: 1100,
      turn: -5,
      art: 'assets/agents/Cypher/icon.webp',
      ally: false,
    ),
    Piece(
      PieceKind.agent,
      onLeft: true,
      inset: 150,
      y: 210,
      size: 100,
      depth: 15,
      enters: 900,
      turn: -8,
      art: 'assets/agents/Jett/icon.webp',
    ),
    Piece(
      PieceKind.agent,
      onLeft: false,
      inset: 140,
      y: 178,
      size: 96,
      depth: 15,
      enters: 950,
      turn: 6,
      art: 'assets/agents/Sage/icon.webp',
      ally: false,
    ),
  ];

  static ({double size, double spread})? fit(Size window, double copyWidth) {
    final room = (window.width - copyWidth) / 2 / gutter;
    final size = math.min(
      (window.height / designHeight).clamp(0.75, 1.4).toDouble(),
      room,
    );
    if (size < smallest) return null;
    return (size: size, spread: math.min(room, size * 1.3));
  }

  static Offset center(Piece piece, Size window, double spread) => Offset(
        piece.onLeft
            ? piece.inset * spread
            : window.width - piece.inset * spread,
        piece.y / designHeight * window.height,
      );

  static double entered(Piece piece, double ms) =>
      SunriseTimeline._quinticOut((ms - piece.enters) / entersFor);
}

class Sunrise extends StatefulWidget {
  const Sunrise({
    super.key,
    required this.onStart,
    required this.onSkip,
    this.onLogIn,
    this.held = false,
    this.wordmarkShown = true,
  });

  final VoidCallback onStart;
  final VoidCallback onSkip;
  final VoidCallback? onLogIn;
  final bool held;
  final bool wordmarkShown;

  static const double cell = 9;

  static Future<ui.FragmentProgram>? _program;

  static Future<ui.FragmentProgram> _load() =>
      _program ??= ui.FragmentProgram.fromAsset('shaders/sunrise.frag');

  @override
  State<Sunrise> createState() => _SunriseState();
}

class _SunriseState extends State<Sunrise> with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _press;
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier(0);
  final GlobalKey _copy = GlobalKey();
  final GlobalKey _action = GlobalKey();

  ui.FragmentShader? _shader;
  _BakedPieces? _pieces;
  Duration _lastTick = Duration.zero;
  double _seconds = 0;
  Offset _pointer = const Offset(-9999, -9999);
  Offset _torch = const Offset(-9999, -9999);
  double _pointerOn = 0;
  double _torchOn = 0;
  Offset _surgeAt = Offset.zero;
  bool _prepared = false;
  bool _still = false;
  Ticker? _calm;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: SunriseTimeline.length.round()),
    );
    _press = AnimationController(vsync: this, duration: SunriseTimeline.press);
    _ticker = createTicker(_tick)..start();
    Sunrise._load().then(
      (program) {
        if (mounted) setState(() => _shader = program.fragmentShader());
      },
      onError: (_) {},
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prepared) return;
    _prepared = true;
    _still = MediaQuery.disableAnimationsOf(context);
    if (_still) {
      _intro.value = 1;
      return;
    }
    _BakedPieces.bake(DefaultAssetBundle.of(context)).then(
      (pieces) {
        if (mounted) {
          _pieces = pieces;
        } else {
          pieces.dispose();
        }
      },
      onError: (_) {},
    );
    if (!widget.held) _calm = whenFramesAreCalm(this, _play);
  }

  @override
  void didUpdateWidget(Sunrise old) {
    super.didUpdateWidget(old);
    if (old.held && !widget.held && !_still) _play();
  }

  @override
  void dispose() {
    _calm?.dispose();
    _ticker.dispose();
    _intro.dispose();
    _press.dispose();
    _shader?.dispose();
    _pieces?.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _play() {
    if (_intro.isAnimating || _intro.isCompleted) return;
    _intro.forward();
  }

  void _tick(Duration elapsed) {
    final dt = math.min(
      0.1,
      (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond,
    );
    _lastTick = elapsed;
    if (!_still) _seconds += dt;
    final follow = 1 - math.exp(-dt * 12);
    _torch =
        _torchOn < 0.01 ? _pointer : Offset.lerp(_torch, _pointer, follow)!;
    _torchOn += (_pointerOn - _torchOn) * (1 - math.exp(-dt * 6));
    _frame.value++;
  }

  Future<void> _go(VoidCallback then) async {
    if (widget.held || _press.isAnimating || _press.isCompleted) return;
    _calm?.stop();
    final root = context.findRenderObject();
    final button = _action.currentContext?.findRenderObject();
    if (root is RenderBox) {
      _surgeAt = button is RenderBox && button.hasSize
          ? button.localToGlobal(
              button.size.center(Offset.zero),
              ancestor: root,
            )
          : root.size.center(Offset.zero);
    }
    if (_still) {
      then();
      return;
    }
    await _press.forward();
    if (mounted) then();
  }

  Rect _quietAir(Size window) {
    final root = context.findRenderObject();
    final copy = _copy.currentContext?.findRenderObject();
    if (root is! RenderBox || copy is! RenderBox || !copy.hasSize) {
      return Rect.fromCenter(
        center: Offset(window.width / 2, window.height * 0.38),
        width: window.width * 0.9,
        height: window.height * 0.5,
      );
    }
    final box = copy.localToGlobal(Offset.zero, ancestor: root) & copy.size;
    return Rect.fromCenter(
      center: box.center,
      width: math.min(window.width * 0.92, 1520),
      height: box.height * 1.8,
    );
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.onLogIn ?? widget.onStart;
    return KeyCapture(
      onKey: (event) {
        final key = event.logicalKey;
        if (key != LogicalKeyboardKey.escape &&
            key != LogicalKeyboardKey.enter) {
          return false;
        }
        if (event is KeyDownEvent && !widget.held) {
          key == LogicalKeyboardKey.escape ? widget.onSkip() : _go(start);
        }
        return true;
      },
      child: MouseRegion(
        opaque: true,
        onHover: (event) {
          _pointer = event.localPosition;
          _pointerOn = 1;
        },
        onExit: (_) => _pointerOn = 0,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final window = constraints.biggest;
            return Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  child: RepaintBoundary(
                    child: CustomPaint(painter: _SunPainter(this, window)),
                  ),
                ),
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(painter: _ScatterPainter(this)),
                  ),
                ),
                AnimatedBuilder(
                  animation: Listenable.merge([_intro, _press]),
                  builder: (context, _) => _foreground(context, window, start),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  double get _staying =>
      1 -
      SunriseTimeline.fadeIn(
        _press.value * SunriseTimeline.press.inMilliseconds,
        0,
        SunriseTimeline.leaveFor,
      );

  Widget _foreground(BuildContext context, Size window, VoidCallback start) {
    final l10n = context.l10n;
    const theme = Settings.tacticalVioletTheme;
    final ms = _intro.value * SunriseTimeline.length;
    final staying = _staying;
    final headline = (window.width * 0.046).clamp(36.0, 74.0);
    final startShown = SunriseTimeline.fadeIn(ms, SunriseTimeline.startFrom);
    final words = l10n.onboardingSunTitle.split(' ');

    return Opacity(
      opacity: staying,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: window.height * 0.13,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  key: _copy,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: widget.wordmarkShown
                          ? SunriseTimeline.fadeIn(ms, 100, 400)
                          : 0,
                      child: const AssetSvg(
                        wordmarkAsset,
                        height: 22,
                        semanticsLabel: 'Icarus',
                      ),
                    ),
                    const SizedBox(height: 28),
                    Semantics(
                      label: l10n.onboardingSunTitle,
                      excludeSemantics: true,
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: headline * 0.26,
                        children: [
                          for (var i = 0; i < words.length; i++)
                            ClipRect(
                              child: FractionalTranslation(
                                translation: Offset(
                                  0,
                                  1.05 * (1 - SunriseTimeline.word(i, ms)),
                                ),
                                child: Padding(
                                  padding:
                                      EdgeInsets.only(bottom: headline * 0.12),
                                  child: Text(
                                    words[i],
                                    style: TextStyle(
                                      fontFamily: 'Onest',
                                      fontSize: headline,
                                      height: 1.02,
                                      letterSpacing: -0.02 * headline,
                                      fontWeight: FontWeight.w700,
                                      fontVariations: const [
                                        FontVariation('wght', 700),
                                      ],
                                      color: theme.foreground,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Opacity(
                      opacity:
                          SunriseTimeline.fadeIn(ms, SunriseTimeline.bodyFrom),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: (window.width * 0.5).clamp(480.0, 780.0),
                        ),
                        child: Text(
                          widget.onLogIn == null
                              ? l10n.onboardingSunBody
                              : l10n.onboardingSunBodyLogIn,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16.5,
                            height: 1.6,
                            fontWeight: FontWeight.w500,
                            color: theme.mutedForeground,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    IgnorePointer(
                      ignoring: startShown < 0.5 || _press.value > 0,
                      child: Opacity(
                        opacity: startShown,
                        child: Transform.translate(
                          offset: Offset(0, 8 * (1 - startShown)),
                          child: KeyedSubtree(
                            key: _action,
                            child: widget.onLogIn == null
                                ? ShadButton(
                                    key: const ValueKey('onboarding-start'),
                                    onPressed: () => _go(start),
                                    child: Text(l10n.onboardingSunStart),
                                  )
                                : ShadButton(
                                    key: const ValueKey('onboarding-log-in'),
                                    onPressed: () => _go(start),
                                    child: Text(l10n.commonLogIn),
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
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: BareStrip(onSkip: widget.onSkip),
          ),
        ],
      ),
    );
  }
}

class _SunPainter extends CustomPainter {
  _SunPainter(this.sun, this.window) : super(repaint: sun._frame);

  final _SunriseState sun;
  final Size window;

  @override
  void paint(Canvas canvas, Size size) {
    final ground = Settings.tacticalVioletTheme.background;
    final shader = sun._shader;
    if (shader == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = ground);
      return;
    }
    final ms = sun._intro.value * SunriseTimeline.length;
    final surge = sun._press.value == 0
        ? 0.0
        : 1 - math.pow(1 - sun._press.value, 3).toDouble();
    final quiet = sun._quietAir(size);
    var i = 0;
    shader
      ..setFloat(i++, size.width)
      ..setFloat(i++, size.height)
      ..setFloat(i++, sun._seconds + 3)
      ..setFloat(i++, Sunrise.cell)
      ..setFloat(i++, SunriseTimeline.rise(ms))
      ..setFloat(i++, SunriseTimeline.pulseAt(ms))
      ..setFloat(i++, sun._torch.dx)
      ..setFloat(i++, sun._torch.dy)
      ..setFloat(i++, sun._torchOn)
      ..setFloat(i++, sun._surgeAt.dx)
      ..setFloat(i++, sun._surgeAt.dy)
      ..setFloat(i++, surge)
      ..setFloat(i++, quiet.center.dx)
      ..setFloat(i++, quiet.center.dy)
      ..setFloat(i++, quiet.width / 2)
      ..setFloat(i++, quiet.height / 2)
      ..setFloat(i++, ground.r)
      ..setFloat(i++, ground.g)
      ..setFloat(i++, ground.b)
      ..setFloat(i++, 1);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_SunPainter old) => old.window != window;
}

final class _BakedPieces {
  _BakedPieces(this.images);

  final List<ui.Image?> images;

  static const double ratio = 2;
  static const double margin = 18;

  static Future<_BakedPieces> bake(AssetBundle bundle) async {
    final images = <ui.Image?>[];
    for (final piece in Scatter.pieces) {
      final art = piece.art;
      if (art == null) {
        images.add(null);
        continue;
      }
      final codec = await ui.instantiateImageCodec(
        (await bundle.load(art)).buffer.asUint8List(),
      );
      final source = (await codec.getNextFrame()).image;
      codec.dispose();
      images.add(_baked(piece, source));
      source.dispose();
    }
    return _BakedPieces(images);
  }

  static ui.Image _baked(Piece piece, ui.Image source) {
    const theme = Settings.tacticalVioletTheme;
    final side = piece.size;
    final box = Offset.zero & Size.square(side);
    final whole = Offset.zero & Size(source.width + 0.0, source.height + 0.0);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(ratio)
      ..translate(margin, margin);
    void shadowUnder(RRect shape) {
      const shadow = Settings.cardForegroundBackdrop;
      canvas.drawRRect(
        shape.shift(shadow.offset),
        Paint()
          ..color = shadow.color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blurSigma),
      );
    }

    final smooth = Paint()..filterQuality = FilterQuality.medium;
    switch (piece.kind) {
      case PieceKind.agent:
        final shape = RRect.fromRectAndRadius(
          box,
          Radius.circular(side * 0.15),
        );
        shadowUnder(shape);
        canvas
          ..drawRRect(
            shape,
            Paint()
              ..color =
                  piece.ally ? Settings.allyBGColor : Settings.enemyBGColor,
          )
          ..save()
          ..clipRRect(shape)
          ..drawImageRect(source, whole, box, smooth)
          ..restore()
          ..drawRRect(
            shape.deflate(1),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = piece.ally
                  ? Settings.allyOutlineColor
                  : Settings.enemyOutlineColor,
          );
      case PieceKind.ability:
        final shape = RRect.fromRectAndRadius(
          box,
          Radius.circular(side * 0.2),
        );
        shadowUnder(shape);
        canvas
          ..drawRRect(shape, Paint()..color = Settings.abilityBGColor)
          ..drawRRect(
            shape.deflate(0.5),
            Paint()
              ..style = PaintingStyle.stroke
              ..color = theme.border,
          )
          ..drawImageRect(source, whole, box.deflate(side * 0.17), smooth);
      case PieceKind.smoke:
        canvas
          ..drawImageRect(
            source,
            whole,
            box,
            Paint()
              ..filterQuality = FilterQuality.medium
              ..color = Colors.white.withValues(alpha: 0.92),
          )
          ..drawCircle(
            box.center,
            side / 2 - 0.75,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = Settings.accentInk.withValues(alpha: 0.55),
          )
          ..drawCircle(
            box.center,
            side * 0.025,
            Paint()..color = Settings.smokeCenterDotFill,
          )
          ..drawCircle(
            box.center,
            side * 0.025,
            Paint()
              ..style = PaintingStyle.stroke
              ..color = Settings.smokeCenterDotRim,
          );
      case PieceKind.arrow || PieceKind.loop:
        break;
    }
    final picture = recorder.endRecording();
    final edge = ((side + margin * 2) * ratio).ceil();
    final image = picture.toImageSync(edge, edge);
    picture.dispose();
    return image;
  }

  void dispose() {
    for (final image in images) {
      image?.dispose();
    }
  }
}

class _ScatterPainter extends CustomPainter {
  _ScatterPainter(this.sun) : super(repaint: sun._frame);

  final _SunriseState sun;

  @override
  void paint(Canvas canvas, Size size) {
    final baked = sun._pieces;
    final copy = sun._copy.currentContext?.findRenderObject();
    if (baked == null || copy is! RenderBox || !copy.hasSize) return;
    final fit = Scatter.fit(size, copy.size.width);
    if (fit == null) return;
    final ms = sun._intro.value * SunriseTimeline.length;
    final staying = sun._staying;
    if (staying <= 0) return;
    final k = fit.size;
    final lean = Offset(
          ((sun._torch.dx / size.width) * 2 - 1).clamp(-1.0, 1.0).toDouble(),
          ((sun._torch.dy / size.height) * 2 - 1).clamp(-1.0, 1.0).toDouble(),
        ) *
        sun._torchOn;
    for (final (index, piece) in Scatter.pieces.indexed) {
      final entered = Scatter.entered(piece, ms);
      if (entered <= 0) continue;
      final phase = index * 1.3;
      final center = Scatter.center(piece, size, fit.spread) +
          Offset(
            (piece.onLeft ? -1 : 1) * Scatter.slidesIn * (1 - entered) -
                lean.dx * piece.depth,
            Scatter.bobs * k * math.sin(sun._seconds * 0.6 + phase) -
                lean.dy * piece.depth * 0.5,
          );
      final image = baked.images[index];
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..rotate(
          (piece.turn +
                  Scatter.sways * math.sin(sun._seconds * 0.45 + phase * 1.7)) *
              math.pi /
              180,
        );
      if (image == null) {
        canvas.scale(k);
        _pen(
          canvas,
          Size.square(piece.size),
          drawn: entered,
          color: (piece.kind == PieceKind.arrow
                  ? Settings.tacticalVioletTheme.foreground
                  : Settings.penColors[3].color)
              .withValues(alpha: staying),
          dashed: piece.kind == PieceKind.arrow,
        );
      } else {
        final edge = piece.size + _BakedPieces.margin * 2;
        canvas
          ..scale(k * (0.86 + 0.14 * entered))
          ..drawImageRect(
            image,
            Offset.zero & Size(image.width + 0.0, image.height + 0.0),
            Rect.fromCenter(center: Offset.zero, width: edge, height: edge),
            Paint()
              ..filterQuality = FilterQuality.medium
              ..color = Colors.white.withValues(alpha: entered * staying),
          );
      }
      canvas.restore();
    }
  }

  static void _pen(
    Canvas canvas,
    Size size, {
    required double drawn,
    required Color color,
    required bool dashed,
  }) {
    final w = size.width;
    final h = size.height;
    canvas.translate(-w / 2, -h / 2);
    final ink = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * (dashed ? 0.02 : 0.045)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    if (dashed) {
      path
        ..moveTo(w * 0.04, h * 0.80)
        ..cubicTo(w * 0.30, h * 0.52, w * 0.46, h * 0.66, w * 0.62, h * 0.50)
        ..cubicTo(w * 0.72, h * 0.40, w * 0.82, h * 0.34, w * 0.95, h * 0.34);
    } else {
      path
        ..moveTo(w * 0.18, h * 0.22)
        ..cubicTo(w * 0.52, -h * 0.04, w * 1.02, h * 0.16, w * 0.93, h * 0.56)
        ..cubicTo(w * 0.86, h * 0.90, w * 0.40, h * 1.02, w * 0.14, h * 0.76)
        ..cubicTo(-w * 0.04, h * 0.56, w * 0.02, h * 0.30, w * 0.24, h * 0.17);
    }
    final metric = path.computeMetrics().first;
    final reach = metric.length * drawn;
    if (!dashed) {
      canvas.drawPath(metric.extractPath(0, reach), ink);
      return;
    }
    final dash = w * 0.075;
    final gap = w * 0.055;
    for (var at = 0.0; at < reach; at += dash + gap) {
      canvas.drawPath(metric.extractPath(at, math.min(at + dash, reach)), ink);
    }
    if (drawn < 0.98) return;
    final tip = metric.getTangentForOffset(metric.length)!;
    final back = -tip.vector / tip.vector.distance;
    final side = Offset(-back.dy, back.dx);
    final barb = w * 0.07;
    final left = tip.position + (back + side) * barb;
    final right = tip.position + (back - side) * barb;
    canvas.drawPath(
      Path()
        ..moveTo(left.dx, left.dy)
        ..lineTo(tip.position.dx, tip.position.dy)
        ..lineTo(right.dx, right.dy),
      ink,
    );
  }

  @override
  bool shouldRepaint(_ScatterPainter old) => false;
}
