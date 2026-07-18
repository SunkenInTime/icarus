import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/settings.dart';

/// Experimental dot-matrix loaders. Each loader samples an animated
/// intensity/color field at every point of a square dot lattice, so all of
/// them share the same halftone character as [HoverDotGrid] and
/// [DitherFireBanner]. Unlit lattice points render as faint "off" dots,
/// like a real dot-matrix display.

const _kViolet = Color(0xff7c3aed); // Settings.tacticalVioletTheme.primary
const _kDeepViolet = Color(0xff4c1d95);
const _kWhite = Color(0xfffafafa);

/// One lit dot: [intensity] (0..1) drives the dot radius, [color] its paint.
class _DotSample {
  const _DotSample(this.intensity, this.color);

  final double intensity;
  final Color color;
}

/// Walks the lattice and delegates each dot to [sample]. `uv` is the dot
/// center in 0..1 square coordinates, `t` is elapsed time in seconds.
abstract class _DotMatrixPainter extends CustomPainter {
  _DotMatrixPainter({
    required this.t,
    required this.columns,
    required this.offDotColor,
  });

  final double t;
  final int columns;
  final Color offDotColor;

  _DotSample? sample(Offset uv);

  @override
  void paint(Canvas canvas, Size size) {
    final spacing = size.width / columns;
    final rows = (size.height / spacing).round();
    final maxRadius = spacing * 0.46;
    final paint = Paint();
    final offPaint = Paint()..color = offDotColor;

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < columns; col++) {
        final center = Offset((col + 0.5) * spacing, (row + 0.5) * spacing);
        final uv = Offset(center.dx / size.width, center.dy / size.height);
        final dot = sample(uv);
        if (dot == null || dot.intensity < 0.03) {
          canvas.drawCircle(center, maxRadius * 0.22, offPaint);
          continue;
        }
        final lit = dot.intensity.clamp(0.0, 1.0);
        paint.color = dot.color;
        // sqrt so perceived area tracks intensity more linearly.
        canvas.drawCircle(center, maxRadius * math.sqrt(lit), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotMatrixPainter oldDelegate) =>
      oldDelegate.t != t;
}

/// Shared stateful shell: runs a ticker and rebuilds a painter every frame.
abstract class _DotLoaderState<T extends StatefulWidget> extends State<T>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double time = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => time = elapsed.inMicroseconds / 1e6);
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

double _sq(double x) => x * x;

double _smoothstep(double a, double b, double x) {
  final u = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return u * u * (3 - 2 * u);
}

// ---------------------------------------------------------------------------
// Wing
// ---------------------------------------------------------------------------

/// An Icarus wing fanned out of feather strokes, beating with a phase lag
/// that ripples from the leading feather to the trailing one. A brightness
/// pulse travels shoulder-to-tip once per beat.
class WingDotLoader extends StatefulWidget {
  const WingDotLoader({super.key, this.size = 96, this.columns = 18});

  final double size;
  final int columns;

  @override
  State<WingDotLoader> createState() => _WingDotLoaderState();
}

class _WingDotLoaderState extends _DotLoaderState<WingDotLoader> {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _WingDotPainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
        ),
      ),
    );
  }
}

class _WingDotPainter extends _DotMatrixPainter {
  _WingDotPainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
  });

  static const _beat = 1.4; // seconds per wing beat
  static const _feathers = 5;
  static const _shoulder = Offset(0.16, 0.40);
  static const _spanX = 0.72; // wing length in local frame

  @override
  _DotSample? sample(Offset uv) {
    final phase = 2 * math.pi * t / _beat;
    final pulse = (t / _beat) % 1.0; // shoulder→tip shimmer position
    // Downstroke snappier than upstroke.
    final flap = math.sin(phase + 0.4 * math.sin(phase));

    // Rotate into the wing frame: x along the spine (shoulder→tip),
    // y down (feathers hang in +y).
    final alpha = -0.12 + flap * 0.42;
    final rel = uv - _shoulder;
    final ca = math.cos(alpha), sa = math.sin(alpha);
    final x = rel.dx * ca + rel.dy * sa;
    var y = -rel.dx * sa + rel.dy * ca;
    if (x < -0.03 || x > _spanX + 0.04) return null;
    final nx = (x / _spanX).clamp(0.0, 1.0);
    // The tip lags the shoulder through the beat.
    y += 0.07 * _sq(nx) * math.sin(phase - 1.1);

    // Leading edge arches up; feathers lengthen toward the tip, with
    // scalloped notches between them. Seams slant back toward the body.
    final yTop = -0.13 * math.sin(math.pi * nx * 0.9);
    final f = ((x + y * 0.55) / _spanX * _feathers) % 1.0;
    final notch = _sq((2 * (f - 0.5)).abs());
    final yBot = 0.11 + 0.34 * math.pow(nx, 1.35) - 0.11 * notch;

    final mask = _smoothstep(-0.02, 0.03, x) *
        (1 - _smoothstep(_spanX * 0.94, _spanX + 0.03, x)) *
        _smoothstep(yTop - 0.025, yTop + 0.03, y) *
        (1 - _smoothstep(yBot - 0.035, yBot + 0.02, y));
    if (mask < 0.05) return null;

    // Dark seams between feathers so they read individually.
    final seam = 0.30 + 0.70 * _smoothstep(0.85, 0.5, (2 * (f - 0.5)).abs());
    final shimmer = math.exp(-_sq((nx - pulse * 1.3) / 0.20));
    final brightness = mask * seam * (0.35 + 0.40 * nx + 0.35 * shimmer);
    final color = Color.lerp(
      _kViolet,
      _kWhite,
      (nx * 0.5 + shimmer * 0.35).clamp(0.0, 1.0),
    )!;
    return _DotSample(brightness, color);
  }
}

// ---------------------------------------------------------------------------
// Fire
// ---------------------------------------------------------------------------

/// A violet flame: scrolling value noise masked by a teardrop flame profile.
/// Hot core burns white, edges fall off through violet into deep violet.
class FireDotLoader extends StatefulWidget {
  const FireDotLoader({super.key, this.size = 96, this.columns = 16});

  final double size;
  final int columns;

  @override
  State<FireDotLoader> createState() => _FireDotLoaderState();
}

class _FireDotLoaderState extends _DotLoaderState<FireDotLoader> {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _FireDotPainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
        ),
      ),
    );
  }
}

double _hash(int x, int y) {
  var h = x * 374761393 + y * 668265263;
  h = (h ^ (h >> 13)) * 1274126177;
  return ((h ^ (h >> 16)) & 0x7fffffff) / 0x7fffffff;
}

double _valueNoise(double x, double y) {
  final xi = x.floor();
  final yi = y.floor();
  final fx = _smoothstep(0, 1, x - xi);
  final fy = _smoothstep(0, 1, y - yi);
  final a = _hash(xi, yi);
  final b = _hash(xi + 1, yi);
  final c = _hash(xi, yi + 1);
  final d = _hash(xi + 1, yi + 1);
  final top = a + (b - a) * fx;
  final bottom = c + (d - c) * fx;
  return top + (bottom - top) * fy;
}

double _fbm(double x, double y) =>
    0.65 * _valueNoise(x, y) + 0.35 * _valueNoise(2 * x + 17, 2 * y + 13);

class _FireDotPainter extends _DotMatrixPainter {
  _FireDotPainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
  });

  @override
  _DotSample? sample(Offset uv) {
    final h = 1 - uv.dy; // 0 at the base, 1 at the top
    final sway = math.sin(t * 2.3 + h * 4) * 0.03 * h;
    final width = 0.30 * math.pow(1 - h, 0.85) + 0.05;
    final radial = ((uv.dx - 0.5 + sway).abs() / width).clamp(0.0, 2.0);
    if (radial >= 1) return null;
    final core = 1 - radial * radial;

    final noise = _fbm(uv.dx * 3.2, uv.dy * 2.8 + t * 1.8);
    final intensity =
        (core * (0.55 + 0.95 * noise) - h * h * 0.65 - 0.12).clamp(0.0, 1.0);
    if (intensity < 0.04) return null;

    final color = intensity < 0.55
        ? Color.lerp(_kDeepViolet, _kViolet, intensity / 0.55)!
        : Color.lerp(_kViolet, _kWhite, (intensity - 0.55) / 0.45 * 0.8)!;
    return _DotSample(intensity, color);
  }
}

// ---------------------------------------------------------------------------
// Cube
// ---------------------------------------------------------------------------

/// A wireframe cube tumbling in 3D, rasterized onto the dot lattice: dots
/// near a projected edge light up, nearer edges render brighter and whiter,
/// vertices get a soft glow. Reads as a hologram scan.
class CubeDotLoader extends StatefulWidget {
  const CubeDotLoader({super.key, this.size = 96, this.columns = 18});

  final double size;
  final int columns;

  @override
  State<CubeDotLoader> createState() => _CubeDotLoaderState();
}

class _CubeDotLoaderState extends _DotLoaderState<CubeDotLoader> {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _CubeDotPainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
        ),
      ),
    );
  }
}

class _CubeDotPainter extends _DotMatrixPainter {
  _CubeDotPainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
  }) {
    final ry = t * 0.9;
    final rx = t * 0.55 + 0.45;
    final cosY = math.cos(ry), sinY = math.sin(ry);
    final cosX = math.cos(rx), sinX = math.sin(rx);

    for (var i = 0; i < 8; i++) {
      final x = (i & 1) == 0 ? -1.0 : 1.0;
      final y = (i & 2) == 0 ? -1.0 : 1.0;
      final z = (i & 4) == 0 ? -1.0 : 1.0;
      // Rotate around Y, then X.
      final x1 = x * cosY + z * sinY;
      final z1 = -x * sinY + z * cosY;
      final y1 = y * cosX - z1 * sinX;
      final z2 = y * sinX + z1 * cosX;
      // Perspective projection into uv space.
      final persp = _focal / (_focal + z2);
      _projected[i] =
          Offset(0.5 + x1 * persp * 0.20, 0.5 + y1 * persp * 0.20);
      _nearness[i] = ((persp - _perspMin) / (_perspMax - _perspMin))
          .clamp(0.0, 1.0);
    }
  }

  static const _focal = 3.2;
  static const _perspMin = _focal / (_focal + 1.75);
  static const _perspMax = _focal / (_focal - 1.75);

  static const _edges = [
    [0, 1], [2, 3], [4, 5], [6, 7], // along x
    [0, 2], [1, 3], [4, 6], [5, 7], // along y
    [0, 4], [1, 5], [2, 6], [3, 7], // along z
  ];

  final List<Offset> _projected = List.filled(8, Offset.zero);
  final List<double> _nearness = List.filled(8, 0);

  @override
  _DotSample? sample(Offset uv) {
    var best = 0.0;
    var bestDepth = 0.0;

    for (final edge in _edges) {
      final a = _projected[edge[0]];
      final b = _projected[edge[1]];
      final ab = b - a;
      final lenSq = ab.distanceSquared;
      final u = lenSq == 0
          ? 0.0
          : (((uv - a).dx * ab.dx + (uv - a).dy * ab.dy) / lenSq)
              .clamp(0.0, 1.0);
      final closest = a + ab * u;
      final dist = (uv - closest).distance;
      final depth =
          _nearness[edge[0]] + (_nearness[edge[1]] - _nearness[edge[0]]) * u;
      final glow = math.exp(-_sq(dist / 0.026)) * (0.25 + 0.75 * depth);
      if (glow > best) {
        best = glow;
        bestDepth = depth;
      }
    }

    // Vertex hotspots.
    for (var i = 0; i < 8; i++) {
      final glow = math.exp(-_sq((uv - _projected[i]).distance / 0.034)) *
          (0.45 + 0.55 * _nearness[i]);
      if (glow > best) {
        best = glow;
        bestDepth = _nearness[i];
      }
    }

    if (best < 0.05) return null;
    final color = Color.lerp(_kViolet, _kWhite, bestDepth * 0.65)!;
    return _DotSample(best, color);
  }
}

// ---------------------------------------------------------------------------
// Ember spinner
// ---------------------------------------------------------------------------

/// The everywhere-loader: a circular comet chase on the dot lattice. The
/// head burns white and trails off through violet embers that flicker as
/// they fade. Reads clearly from 24px up.
class EmberSpinLoader extends StatefulWidget {
  const EmberSpinLoader({super.key, this.size = 32, this.columns = 11});

  final double size;
  final int columns;

  @override
  State<EmberSpinLoader> createState() => _EmberSpinLoaderState();
}

class _EmberSpinLoaderState extends _DotLoaderState<EmberSpinLoader> {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _EmberSpinPainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
        ),
      ),
    );
  }
}

class _EmberSpinPainter extends _DotMatrixPainter {
  _EmberSpinPainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
  });

  static const _turn = 1.1; // seconds per revolution

  @override
  _DotSample? sample(Offset uv) {
    final rel = uv - const Offset(0.5, 0.5);
    final r = rel.distance;
    final band = math.exp(-_sq((r - 0.33) / 0.075));
    if (band < 0.05) return null;

    final head = 2 * math.pi * t / _turn;
    final ang = math.atan2(rel.dy, rel.dx);
    // How far behind the head this dot sits, 0..2π.
    var behind = (head - ang) % (2 * math.pi);
    if (behind < 0) behind += 2 * math.pi;

    // Comet falloff over a faint always-on ring, with a light ember
    // flicker in the tail. The dim ring keeps the circular shape legible
    // even where the tail has died out.
    final tail = math.exp(-behind * 0.55);
    final flicker = 0.85 + 0.15 * _valueNoise(behind * 2.5 + 40, t * 6);
    final intensity =
        (band * (0.14 + 0.72 * tail) * flicker).clamp(0.0, 0.9);
    if (intensity < 0.05) return null;

    final color = Color.lerp(
      _kDeepViolet,
      _kWhite,
      (tail * 1.15).clamp(0.0, 1.0),
    )!;
    return _DotSample(intensity, color);
  }
}

// ---------------------------------------------------------------------------
// Icarus mark
// ---------------------------------------------------------------------------

/// The Icarus flame mark itself, rasterized onto the dot lattice and lit
/// from within: rising ember noise plus a periodic shimmer sweep. For
/// splash screens, update dialogs — anywhere the brand should burn.
class IcarusMarkLoader extends StatefulWidget {
  const IcarusMarkLoader({super.key, this.size = 96, this.columns = 16});

  final double size;
  final int columns;

  @override
  State<IcarusMarkLoader> createState() => _IcarusMarkLoaderState();
}

/// Alpha channel of the logo, downsampled and cropped to its bounding box.
class _AlphaMask {
  _AlphaMask(this.width, this.height, this.alpha) {
    var minX = width, minY = height, maxX = 0, maxY = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (alpha[y * width + x] > 32) {
          minX = math.min(minX, x);
          minY = math.min(minY, y);
          maxX = math.max(maxX, x);
          maxY = math.max(maxY, y);
        }
      }
    }
    _minX = minX.toDouble();
    _minY = minY.toDouble();
    _spanX = math.max(1, maxX - minX).toDouble();
    _spanY = math.max(1, maxY - minY).toDouble();
  }

  final int width;
  final int height;
  final Uint8List alpha;
  late final double _minX, _minY, _spanX, _spanY;

  /// Samples with the glyph's bounding box fitted to 0..1 (8% margin),
  /// preserving aspect ratio.
  double sample(Offset uv) {
    final scale = math.max(_spanX, _spanY) / 0.84;
    final x = (_minX + _spanX / 2 + (uv.dx - 0.5) * scale).round();
    final y = (_minY + _spanY / 2 + (uv.dy - 0.5) * scale).round();
    if (x < 0 || x >= width || y < 0 || y >= height) return 0;
    return alpha[y * width + x] / 255;
  }
}

class _IcarusMarkLoaderState extends _DotLoaderState<IcarusMarkLoader> {
  static _AlphaMask? _cachedMask;
  static Future<_AlphaMask>? _maskFuture;

  _AlphaMask? _mask = _cachedMask;

  static Future<_AlphaMask> _loadMask() {
    return _maskFuture ??= () async {
      final data = await rootBundle.load('assets/logo_mark.png');
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: 64,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final alpha = Uint8List(image.width * image.height);
      for (var i = 0; i < alpha.length; i++) {
        alpha[i] = bytes.getUint8(i * 4 + 3);
      }
      final mask = _AlphaMask(image.width, image.height, alpha);
      image.dispose();
      return _cachedMask = mask;
    }();
  }

  @override
  void initState() {
    super.initState();
    if (_mask == null) {
      _loadMask().then((mask) {
        if (mounted) setState(() => _mask = mask);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _IcarusMarkPainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
          mask: _mask,
        ),
      ),
    );
  }
}

class _IcarusMarkPainter extends _DotMatrixPainter {
  _IcarusMarkPainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
    required this.mask,
  });

  final _AlphaMask? mask;

  @override
  _DotSample? sample(Offset uv) {
    final a = mask?.sample(uv) ?? 0;
    if (a < 0.25) return null;

    // Embers rising through the mark, plus a diagonal shimmer sweep.
    final ember = _fbm(uv.dx * 2.8, uv.dy * 2.4 + t * 1.2);
    final sweep = math.exp(
      -_sq(((uv.dx + uv.dy) / 2 - ((t / 2.4) % 1.0) * 1.4 + 0.2) / 0.12),
    );
    final intensity =
        (a * (0.45 + 0.45 * ember + 0.4 * sweep)).clamp(0.0, 1.0);

    final color = intensity < 0.6
        ? Color.lerp(_kDeepViolet, _kViolet, intensity / 0.6)!
        : Color.lerp(_kViolet, _kWhite, (intensity - 0.6) / 0.4)!;
    return _DotSample(intensity, color);
  }
}

// ---------------------------------------------------------------------------
// Flight trail
// ---------------------------------------------------------------------------

/// A point of light flying an endless figure-eight, leaving a violet
/// contrail that fades behind it. Flight that never lands — loading.
class FlightTrailLoader extends StatefulWidget {
  const FlightTrailLoader({super.key, this.size = 48, this.columns = 15});

  final double size;
  final int columns;

  @override
  State<FlightTrailLoader> createState() => _FlightTrailLoaderState();
}

class _FlightTrailLoaderState extends _DotLoaderState<FlightTrailLoader> {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _FlightTrailPainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
        ),
      ),
    );
  }
}

class _FlightTrailPainter extends _DotMatrixPainter {
  _FlightTrailPainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
  });

  static const _lap = 2.6; // seconds per figure-eight
  static const _trailSamples = 34;
  static const _trailSpan = 0.52; // fraction of the lap the trail covers
  static const _hintSamples = 24; // faint trace of the whole route

  static Offset _path(double s) {
    final u = 2 * math.pi * s;
    return Offset(
      0.5 + 0.36 * math.sin(u),
      0.5 + 0.30 * math.sin(u) * math.cos(u),
    );
  }

  @override
  _DotSample? sample(Offset uv) {
    final head = (t / _lap) % 1.0;

    // The whole route stays faintly visible so the figure-eight reads.
    var best = 0.0;
    var bestAge = 1.0; // 0 at the head, 1 at the trail's end
    for (var j = 0; j < _hintSamples; j++) {
      final p = _path(j / _hintSamples);
      final w = 0.12 * math.exp(-_sq((uv - p).distance / 0.020));
      if (w > best) best = w;
    }

    for (var j = 0; j < _trailSamples; j++) {
      final age = j / (_trailSamples - 1);
      final p = _path(head - age * _trailSpan);
      final w = math.exp(-age * 2.2) * math.exp(-_sq((uv - p).distance / 0.024));
      if (w > best) {
        best = w;
        bestAge = age;
      }
    }

    if (best < 0.05) return null;
    final color = Color.lerp(
      _kDeepViolet,
      _kWhite,
      (1 - bestAge * 1.6).clamp(0.0, 1.0),
    )!;
    return _DotSample(best, color);
  }
}

// ---------------------------------------------------------------------------
// Feather fall
// ---------------------------------------------------------------------------

/// A single feather drifting down, swaying side to side like a falling
/// leaf and tilting into each swing. The feather Icarus lost.
class FeatherFallLoader extends StatefulWidget {
  const FeatherFallLoader({super.key, this.size = 48, this.columns = 15});

  final double size;
  final int columns;

  @override
  State<FeatherFallLoader> createState() => _FeatherFallLoaderState();
}

class _FeatherFallLoaderState extends _DotLoaderState<FeatherFallLoader> {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _FeatherFallPainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
        ),
      ),
    );
  }
}

class _FeatherFallPainter extends _DotMatrixPainter {
  _FeatherFallPainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
  });

  static const _drop = 2.6; // seconds per descent

  @override
  _DotSample? sample(Offset uv) {
    final p = (t / _drop) % 1.0;
    // Sways twice per descent; tilts into the direction of travel.
    final center = Offset(
      0.5 + 0.14 * math.sin(p * 4 * math.pi),
      -0.18 + 1.36 * p,
    );
    final tilt = -0.16 + 0.5 * math.cos(p * 4 * math.pi);

    // Elongated ellipse in the feather's local frame.
    final rel = uv - center;
    final ca = math.cos(tilt), sa = math.sin(tilt);
    final x = rel.dx * ca + rel.dy * sa;
    final y = -rel.dx * sa + rel.dy * ca;
    final body = math.exp(-_sq(x / 0.19) - _sq(y / 0.068));
    if (body < 0.10) return null;

    // Fade at the loop seam so the feather dissolves and re-forms.
    final fade = _smoothstep(0.0, 0.10, p) * (1 - _smoothstep(0.90, 1.0, p));
    if (fade < 0.05) return null;

    // Bright central spine, softer vanes.
    final spine = math.exp(-_sq(y / 0.022));
    final intensity = (body * fade * (0.55 + 0.65 * spine)).clamp(0.0, 1.0);
    final color = Color.lerp(_kViolet, _kWhite, 0.25 + spine * 0.5)!;
    return _DotSample(intensity, color);
  }
}

// ---------------------------------------------------------------------------
// Ember rise
// ---------------------------------------------------------------------------

/// Loose embers floating up and burning out — the flame mark,
/// deconstructed. Quietest of the set; reads at very small sizes.
class EmberRiseLoader extends StatefulWidget {
  const EmberRiseLoader({super.key, this.size = 32, this.columns = 11});

  final double size;
  final int columns;

  @override
  State<EmberRiseLoader> createState() => _EmberRiseLoaderState();
}

class _EmberRiseLoaderState extends _DotLoaderState<EmberRiseLoader> {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _EmberRisePainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
        ),
      ),
    );
  }
}

class _EmberRisePainter extends _DotMatrixPainter {
  _EmberRisePainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
  });

  static const _embers = 12;

  @override
  _DotSample? sample(Offset uv) {
    var best = 0.0;
    var bestLife = 0.0; // 1 fresh at the bottom, 0 burnt out at the top

    // A smoldering bed at the base anchors the rising embers.
    final bed = math.exp(
      -_sq((uv.dx - 0.5) / 0.30) - _sq((uv.dy - 0.96) / 0.10),
    );
    if (bed > 0.06) {
      final flicker = 0.5 + 0.5 * _valueNoise(uv.dx * 6 + t * 2.5, t * 1.5);
      best = bed * flicker * 0.8;
      bestLife = 0.9;
    }

    for (var k = 0; k < _embers; k++) {
      final lane = _hash(k, 7);
      final speed = 1.6 + 1.2 * _hash(k, 13);
      final phase = (t / speed + _hash(k, 29)) % 1.0;
      final pos = Offset(
        0.14 + 0.72 * lane + 0.06 * math.sin(t * 2 + k * 2.4),
        0.92 - 0.88 * phase,
      );
      final life = 1 - phase;
      // Embers swell as they lift off, then shrink as they burn out.
      final size = 0.024 + 0.024 * math.sin(math.pi * math.min(1, phase * 1.6));
      final w = math.exp(-_sq((uv - pos).distance / size)) *
          _smoothstep(0.0, 0.12, phase) *
          life;
      if (w > best) {
        best = w;
        bestLife = life;
      }
    }

    if (best < 0.06) return null;
    final color = Color.lerp(
      _kDeepViolet,
      _kWhite,
      (bestLife * 1.2 - 0.2).clamp(0.0, 1.0),
    )!;
    return _DotSample(best, color);
  }
}

// ---------------------------------------------------------------------------
// Ping
// ---------------------------------------------------------------------------

/// A tactical map ping: staggered rings expanding from a pulsing center
/// dot. Less the myth, more the product — this is what Icarus is for.
class PingLoader extends StatefulWidget {
  const PingLoader({super.key, this.size = 32, this.columns = 11});

  final double size;
  final int columns;

  @override
  State<PingLoader> createState() => _PingLoaderState();
}

class _PingLoaderState extends _DotLoaderState<PingLoader> {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _PingPainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
        ),
      ),
    );
  }
}

class _PingPainter extends _DotMatrixPainter {
  _PingPainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
  });

  static const _period = 1.7; // seconds per ping

  @override
  _DotSample? sample(Offset uv) {
    final r = (uv - const Offset(0.5, 0.5)).distance;

    var best = 0.0;
    for (final offset in const [0.0, 0.5]) {
      final p = (t / _period + offset) % 1.0;
      final ringR = 0.05 + 0.40 * p;
      final ring = math.exp(-_sq((r - ringR) / 0.030)) * _sq(1 - p);
      best = math.max(best, ring);
    }

    // Pulsing center dot: the ping's origin.
    final pulse = 0.75 + 0.25 * math.sin(2 * math.pi * t / _period);
    best = math.max(best, math.exp(-_sq(r / 0.055)) * pulse);

    if (best < 0.05) return null;
    final color = Color.lerp(_kViolet, _kWhite, (best - 0.4).clamp(0.0, 1.0))!;
    return _DotSample(best, color);
  }
}

// ---------------------------------------------------------------------------
// Cute
// ---------------------------------------------------------------------------

/// A little dot-matrix blob that bounces in place: squashes on landing,
/// stretches mid-air, blinks every few seconds. Eyes and mouth are unlit
/// cutouts; cheeks blush pink.
class CuteDotLoader extends StatefulWidget {
  const CuteDotLoader({super.key, this.size = 96, this.columns = 16});

  final double size;
  final int columns;

  @override
  State<CuteDotLoader> createState() => _CuteDotLoaderState();
}

class _CuteDotLoaderState extends _DotLoaderState<CuteDotLoader> {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _CuteDotPainter(
          t: time,
          columns: widget.columns,
          offDotColor: Settings.tacticalVioletTheme.border.withValues(
            alpha: 0.45,
          ),
        ),
      ),
    );
  }
}

class _CuteDotPainter extends _DotMatrixPainter {
  _CuteDotPainter({
    required super.t,
    required super.columns,
    required super.offDotColor,
  }) {
    final p = (t / _hop) % 1.0;
    final air = 4 * p * (1 - p); // 0 on the ground, 1 at the apex
    final ground = (p < 0.5 ? p : 1 - p) / 0.09;
    final squash = 0.22 * math.exp(-ground * ground);

    _center = Offset(0.5, 0.72 - 0.22 * air);
    _rx = 0.27 * (1 + squash - 0.08 * air);
    _ry = 0.23 * (1 - squash + 0.12 * air);

    // A quick blink every few seconds, plus one right after landing.
    final blink = math.exp(-_sq(((t / 3.1) % 1.0 - 0.55) / 0.025));
    _eyeOpen = 1 - blink;
  }

  static const _hop = 1.5; // seconds per bounce
  static final _bodyColor = Color.lerp(_kViolet, _kWhite, 0.22)!;
  static const _cheekColor = Color(0xfff0abfc);

  late final Offset _center;
  late final double _rx;
  late final double _ry;
  late final double _eyeOpen;

  double _ellipse(Offset uv, Offset center, double rx, double ry) {
    final d = uv - center;
    return _sq(d.dx / rx) + _sq(d.dy / ry);
  }

  @override
  _DotSample? sample(Offset uv) {
    final body = _ellipse(uv, _center, _rx, _ry);
    if (body > 1.15) return null;
    final edge = 1 - _smoothstep(0.85, 1.1, body);
    if (edge < 0.05) return null;

    // Eyes: unlit cutouts that squeeze shut on blink. Kept wider than the
    // dot spacing so they never fall between lattice points.
    final eyeRy = 0.016 + 0.036 * _eyeOpen;
    for (final side in const [-1.0, 1.0]) {
      final eye = _center + Offset(side * _rx * 0.40, -_ry * 0.20);
      if (_ellipse(uv, eye, 0.040, eyeRy) < 1) return null;
    }

    // Mouth: a smiling crescent (lower ellipse minus a raised one).
    final mouth = _center + Offset(0, _ry * 0.40);
    if (_ellipse(uv, mouth, 0.075, 0.055) < 1 &&
        _ellipse(uv, mouth + const Offset(0, -0.045), 0.085, 0.055) > 1) {
      return null;
    }

    // Cheeks blush.
    for (final side in const [-1.0, 1.0]) {
      final cheek = _center + Offset(side * _rx * 0.62, _ry * 0.12);
      if (_ellipse(uv, cheek, 0.045, 0.032) < 1) {
        return _DotSample(edge, _cheekColor);
      }
    }

    // Soft top-left highlight so the blob reads as round.
    final light = _ellipse(uv, _center + Offset(-_rx * 0.3, -_ry * 0.35),
        _rx * 0.55, _ry * 0.5);
    final shade = light < 1 ? 0.35 * (1 - light) : 0.0;
    return _DotSample(edge, Color.lerp(_bodyColor, _kWhite, shade)!);
  }
}
