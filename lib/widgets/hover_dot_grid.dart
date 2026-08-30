import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:icarus/const/settings.dart';

/// A shader-driven replacement for [DotGrid] that reacts to the cursor:
/// dots near the mouse brighten and swell while the rest of the field dims.
/// Falls back to nothing while the shader is loading (a single frame).
class HoverDotGrid extends StatefulWidget {
  const HoverDotGrid({
    super.key,
    this.spacing = 9.5,
    this.dotRadius = 1.5,
    this.glowRadius = 28,
    this.baseColor,
    this.glowColor,
  });

  final double spacing;
  final double dotRadius;

  /// Sigma of the gaussian falloff around the cursor, in logical pixels.
  final double glowRadius;

  /// Resting dot color. Defaults to the same color DotPainter uses.
  final Color? baseColor;

  /// Dot color at the center of the glow. Defaults to the theme foreground.
  final Color? glowColor;

  static Future<ui.FragmentProgram>? _programFuture;

  static Future<ui.FragmentProgram> _loadProgram() {
    return _programFuture ??=
        ui.FragmentProgram.fromAsset('shaders/dot_grid.frag');
  }

  @override
  State<HoverDotGrid> createState() => _HoverDotGridState();
}

class _HoverDotGridState extends State<HoverDotGrid>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final Ticker _ticker;

  // Eased state (what the shader sees) vs targets (raw input).
  Offset _mouse = Offset.zero;
  Offset _mouseTarget = Offset.zero;
  double _hover = 0;
  double _hoverTarget = 0;
  bool _hasEverHovered = false;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    // Content stacked above the grid (scroll views, cards) wins the pointer
    // hit test, so a local MouseRegion would never see hover events. Listen
    // on the global route instead and convert to local coordinates.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handleGlobalPointer);
    HoverDotGrid._loadProgram().then((program) {
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    });
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter
        .removeGlobalRoute(_handleGlobalPointer);
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  void _handleGlobalPointer(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if (event is PointerRemovedEvent) {
      _onExit();
      return;
    }
    if (event is! PointerHoverEvent &&
        event is! PointerMoveEvent &&
        event is! PointerDownEvent) {
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final local = box.globalToLocal(event.position);
    final inside = local.dx >= 0 &&
        local.dy >= 0 &&
        local.dx <= box.size.width &&
        local.dy <= box.size.height;

    if (inside) {
      _onHover(local);
    } else {
      _onExit();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;

    // Exponential smoothing toward the targets; frame-rate independent.
    final posLerp = 1 - math.exp(-dt * 10);
    final hoverLerp = 1 - math.exp(-dt * 6);

    setState(() {
      _mouse = Offset.lerp(_mouse, _mouseTarget, posLerp)!;
      _hover += (_hoverTarget - _hover) * hoverLerp;
    });

    final settled = (_mouse - _mouseTarget).distanceSquared < 0.05 &&
        (_hoverTarget - _hover).abs() < 0.004;
    if (settled) {
      _mouse = _mouseTarget;
      _hover = _hoverTarget;
      _ticker.stop();
      _lastTick = Duration.zero;
    }
  }

  void _ensureTicking() {
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _onHover(Offset localPosition) {
    _mouseTarget = localPosition;
    if (!_hasEverHovered) {
      // Don't sweep in from (0,0) on first contact.
      _hasEverHovered = true;
      _mouse = _mouseTarget;
    }
    _hoverTarget = 1;
    _ensureTicking();
  }

  void _onExit() {
    if (_hoverTarget == 0) return;
    _hoverTarget = 0;
    _ensureTicking();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null) {
      return const SizedBox.expand();
    }

    return CustomPaint(
      size: Size.infinite,
      painter: _HoverDotGridPainter(
        shader: shader,
        mouse: _mouse,
        hover: _hover,
        spacing: widget.spacing,
        dotRadius: widget.dotRadius,
        glowRadius: widget.glowRadius,
        baseColor: widget.baseColor ??
            Settings.tacticalVioletTheme.border.withValues(alpha: 0.7),
        glowColor: widget.glowColor ??
            Settings.tacticalVioletTheme.foreground.withValues(alpha: 0.45),
      ),
    );
  }
}

class _HoverDotGridPainter extends CustomPainter {
  _HoverDotGridPainter({
    required this.shader,
    required this.mouse,
    required this.hover,
    required this.spacing,
    required this.dotRadius,
    required this.glowRadius,
    required this.baseColor,
    required this.glowColor,
  });

  final ui.FragmentShader shader;
  final Offset mouse;
  final double hover;
  final double spacing;
  final double dotRadius;
  final double glowRadius;
  final Color baseColor;
  final Color glowColor;

  @override
  void paint(Canvas canvas, Size size) {
    var i = 0;
    shader.setFloat(i++, size.width);
    shader.setFloat(i++, size.height);
    shader.setFloat(i++, mouse.dx);
    shader.setFloat(i++, mouse.dy);
    shader.setFloat(i++, hover);
    shader.setFloat(i++, spacing);
    shader.setFloat(i++, dotRadius);
    shader.setFloat(i++, glowRadius);
    shader.setFloat(i++, baseColor.r);
    shader.setFloat(i++, baseColor.g);
    shader.setFloat(i++, baseColor.b);
    shader.setFloat(i++, baseColor.a);
    shader.setFloat(i++, glowColor.r);
    shader.setFloat(i++, glowColor.g);
    shader.setFloat(i++, glowColor.b);
    shader.setFloat(i++, glowColor.a);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_HoverDotGridPainter oldDelegate) {
    return oldDelegate.mouse != mouse ||
        oldDelegate.hover != hover ||
        oldDelegate.spacing != spacing ||
        oldDelegate.dotRadius != dotRadius ||
        oldDelegate.glowRadius != glowRadius ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.glowColor != glowColor;
  }
}