// import 'package:flutter/material.dart';
// import 'package:icarus/const/coordinate_system.dart';

// class DotGrid extends StatelessWidget {
//   const DotGrid({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return CustomPaint(painter: DotPainter());
//   }
// }

// class DotPainter extends CustomPainter {
//   final playAreaSize = CoordinateSystem.instance.playAreaSize;
//   static const double dotSize = 3; // Size of each dot
//   static const double dotSpacing = 9.5;

//   @override
//   @override
//   void paint(Canvas canvas, Size size) {
//     final paint = Paint()
//       ..color = const Color.fromRGBO(210, 214, 219, 0.1)
//       ..style = PaintingStyle.fill;

//     // Use ceiling instead of floor to include partial spaces
//     int rows = (size.height / dotSpacing).ceil();
//     int columns = (size.width / dotSpacing).ceil();

//     for (int row = 0; row < rows; row++) {
//       for (int column = 0; column < columns; column++) {
//         double x = column * dotSpacing;
//         // Don't draw dots that would go beyond the size
//         if (x > size.width) continue;

//         double y = row * dotSpacing;
//         if (y > size.height) continue;

//         canvas.drawCircle(Offset(x, y), dotSize / 2, paint);
//       }
//     }
//   }

//   @override
//   bool shouldRepaint(DotPainter oldDelegate) {
//     if (oldDelegate.playAreaSize != playAreaSize) {
//       return true;
//     }
//     return false;
//   }
// }
import 'dart:ui' as ui show FragmentProgram, FragmentShader, PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

class DotGrid extends ConsumerStatefulWidget {
  const DotGrid({
    super.key,
    this.isScreenshot = false,
    this.opacity,
    this.followsEditorZoom = false,
  });
  final bool isScreenshot;

  /// Whether the grid sits on the editor's zoomable canvas. On the web its
  /// dots then keep edges one device pixel wide at the editor's zoom.
  final bool followsEditorZoom;

  /// Offscreen captures pass the opacity in because their isolated provider
  /// container doesn't read Hive. Everywhere else the user's setting applies.
  final double? opacity;

  @override
  ConsumerState<DotGrid> createState() => _DotGridState();
}

class _DotGridState extends ConsumerState<DotGrid> {
  // The web redraws every point of the grid on every frame, which was most
  // of the editor's raster time while dragging; there one shader draws the
  // lattice instead. Desktop keeps the grid's pixels between frames, so it
  // keeps the points, as do screenshots. Until the shader loads, the points
  // draw.
  static final _lattice = ValueNotifier<ui.FragmentProgram?>(null);
  static bool _loading = false;

  // This grid's shader, kept for its lifetime: each holds uniforms that are
  // only freed by dispose. A recorded picture reads the shader's current
  // uniforms when drawn, which is safe because the grid only ever shows the
  // picture it painted last.
  ui.FragmentShader? _shader;

  bool get _usesShader => kIsWeb && !widget.isScreenshot;

  static void _load() {
    if (_loading) return;
    _loading = true;
    ui.FragmentProgram.fromAsset('shaders/dot_lattice.frag')
        .then((program) => _lattice.value = program, onError: (_) {});
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double opacity = widget.opacity ??
        ref.watch(
          appPreferencesProvider.select((prefs) => prefs.backgroundDotOpacity),
        );
    if (!_usesShader) {
      return CustomPaint(painter: DotPainter(opacity: opacity));
    }
    _load();
    final zoom = widget.followsEditorZoom ? ref.watch(screenZoomProvider) : 1.0;
    final pixel = 1 / (MediaQuery.devicePixelRatioOf(context) * zoom);
    return ValueListenableBuilder(
      valueListenable: _lattice,
      builder: (context, program, _) {
        if (program != null) _shader ??= program.fragmentShader();
        return CustomPaint(
          painter: DotPainter(opacity: opacity, shader: _shader, pixel: pixel),
        );
      },
    );
  }
}

class DotPainter extends CustomPainter {
  DotPainter({required this.opacity, this.shader, this.pixel = 1});

  final double opacity;

  /// dot_lattice.frag, to draw the grid with in place of its points.
  final ui.FragmentShader? shader;

  /// One device pixel in the grid's own units, for [shader].
  final double pixel;

  Size? _cachedSize;
  List<Offset> _cachedPoints = const [];

  static const double dotSize = 3; // Size of each dot
  static const double dotSpacing = 9.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final color = Settings.tacticalVioletTheme.border.withValues(
      alpha: 0.7 * opacity,
    );
    final shader = this.shader;
    if (shader != null) {
      _paintLattice(canvas, size, shader, color);
      return;
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = dotSize
      ..strokeCap = StrokeCap.round;

    canvas.drawPoints(ui.PointMode.points, _pointsFor(size), paint);
  }

  /// The same lattice as [_pointsFor], drawn by dot_lattice.frag.
  void _paintLattice(
      Canvas canvas, Size size, ui.FragmentShader shader, Color color) {
    final rows = (size.height / dotSpacing).ceil() + 1;
    final columns = (size.width / dotSpacing).ceil() + 1;
    var i = 0;
    shader
      ..setFloat(i++, columns > 1 ? size.width / (columns - 1) : 0)
      ..setFloat(i++, rows > 1 ? size.height / (rows - 1) : 0)
      ..setFloat(i++, columns - 1.0)
      ..setFloat(i++, rows - 1.0)
      ..setFloat(i++, dotSize / 2)
      ..setFloat(i++, pixel)
      ..setFloat(i++, color.r)
      ..setFloat(i++, color.g)
      ..setFloat(i++, color.b)
      ..setFloat(i++, color.a);
    // The outer dots straddle the edges, as points do.
    canvas.drawRect(
      (Offset.zero & size).inflate(dotSize),
      Paint()..shader = shader,
    );
  }

  List<Offset> _pointsFor(Size size) {
    if (_cachedSize == size) return _cachedPoints;

    // Calculate how many dots we need in each direction
    int rows = (size.height / dotSpacing).ceil() + 1;
    int columns = (size.width / dotSpacing).ceil() + 1;

    // Calculate the starting positions to ensure dots at edges
    double startX = 0;
    double startY = 0;

    // If we have more than one column/row, adjust spacing to ensure dots at edges
    double adjustedHorizontalSpacing =
        columns > 1 ? size.width / (columns - 1) : 0;
    double adjustedVerticalSpacing = rows > 1 ? size.height / (rows - 1) : 0;

    final points = <Offset>[];
    for (int row = 0; row < rows; row++) {
      for (int column = 0; column < columns; column++) {
        // Calculate position using adjusted spacing to ensure dots at edges
        double x = startX + column * adjustedHorizontalSpacing;
        double y = startY + row * adjustedVerticalSpacing;

        // Skip dots that would be outside the visible area
        if (x > size.width || y > size.height) continue;

        points.add(Offset(x, y));
      }
    }

    _cachedSize = size;
    _cachedPoints = points;
    return points;
  }

  @override
  bool shouldRepaint(DotPainter oldDelegate) {
    return oldDelegate.opacity != opacity ||
        oldDelegate.shader != shader ||
        oldDelegate.pixel != pixel;
  }
}
