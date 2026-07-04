import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Animated halftone hero: a lattice of round dots sized and colored by
/// layered noise fields (violet heat and cool silver drifting through each
/// other). [progress] (0..1) energizes the field — wire it to download
/// progress so the banner doubles as a progress indicator. The child
/// (e.g. the app logo) is composited on top.
class DitherFireBanner extends StatefulWidget {
  const DitherFireBanner({
    super.key,
    required this.progress,
    this.height = 150,
    this.cellSize = 9,
    this.child,
  });

  final double progress;
  final double height;

  /// Pitch of the halftone dot lattice in logical pixels.
  final double cellSize;

  final Widget? child;

  static Future<ui.FragmentProgram>? _programFuture;

  static Future<ui.FragmentProgram> _loadProgram() {
    return _programFuture ??=
        ui.FragmentProgram.fromAsset('shaders/dither_fire.frag');
  }

  @override
  State<DitherFireBanner> createState() => _DitherFireBannerState();
}

class _DitherFireBannerState extends State<DitherFireBanner>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final Ticker _ticker;
  double _time = 0;
  double _displayProgress = 0;

  @override
  void initState() {
    super.initState();
    _displayProgress = widget.progress;
    _ticker = createTicker(_onTick)..start();
    DitherFireBanner._loadProgram().then((program) {
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    setState(() {
      _time = elapsed.inMicroseconds / 1e6;
      // Chase the target so progress jumps render as a smooth swell.
      _displayProgress += (widget.progress - _displayProgress) * 0.06;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xff0c0612)),
          if (shader != null)
            CustomPaint(
              painter: _DitherFirePainter(
                shader: shader,
                time: _time,
                progress: _displayProgress.clamp(0.0, 1.0),
                cellSize: widget.cellSize,
              ),
            ),
          if (widget.child != null) Center(child: widget.child),
        ],
      ),
    );
  }
}

class _DitherFirePainter extends CustomPainter {
  _DitherFirePainter({
    required this.shader,
    required this.time,
    required this.progress,
    required this.cellSize,
  });

  final ui.FragmentShader shader;
  final double time;
  final double progress;
  final double cellSize;

  @override
  void paint(Canvas canvas, Size size) {
    var i = 0;
    shader.setFloat(i++, size.width);
    shader.setFloat(i++, size.height);
    shader.setFloat(i++, time);
    shader.setFloat(i++, progress);
    shader.setFloat(i++, cellSize);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_DitherFirePainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.progress != progress ||
        oldDelegate.cellSize != cellSize;
  }
}
