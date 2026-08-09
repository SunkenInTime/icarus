import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/shape_indicator_fade.dart';

class RotatableWidget extends ConsumerStatefulWidget {
  final Widget child;
  final double rotation;
  final Offset origin;
  final Function(DragUpdateDetails details) onPanUpdate;
  final Function(DragStartDetails details) onPanStart;

  final Function(DragEndDetails details) onPanEnd;
  final bool isDragging;
  final double? buttonLeft;
  final double? buttonTop;
  final bool showHandle;
  const RotatableWidget({
    super.key,
    required this.child,
    required this.rotation,
    required this.onPanUpdate,
    required this.onPanStart,
    required this.onPanEnd,
    required this.origin,
    required this.isDragging,
    this.buttonLeft,
    this.buttonTop,
    this.showHandle = true,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _RotatableWidgetState();
}

class _RotatableWidgetState extends ConsumerState<RotatableWidget>
    with SingleTickerProviderStateMixin {
  static const _hoverExitDelay = Duration(milliseconds: 150);

  late final AnimationController _animationController;
  late final Animation<double> _scaleAnimation;
  Timer? _hoverExitTimer;
  bool _isExitGraceActive = false;
  bool _isTargetHovered = false;
  bool _isHandleHovered = false;
  bool _isHandleDragging = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _hoverExitTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _showTargetHandle() {
    _hoverExitTimer?.cancel();
    if (_isTargetHovered && !_isExitGraceActive) return;

    setState(() {
      _isTargetHovered = true;
      _isExitGraceActive = false;
    });
  }

  void _scheduleTargetHandleHide() {
    _hoverExitTimer?.cancel();
    setState(() {
      _isTargetHovered = false;
      _isExitGraceActive = true;
    });
    _hoverExitTimer = Timer(_hoverExitDelay, () {
      if (!mounted) return;

      setState(() {
        _isExitGraceActive = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final rotationOrigin = widget.origin.scale(
      coordinateSystem.scaleFactor,
      coordinateSystem.scaleFactor,
    );
    final isScreenshot = ref.watch(screenshotProvider);
    final buttonSize = coordinateSystem.scale(15);
    final showHandle = _isTargetHovered ||
        _isExitGraceActive ||
        _isHandleHovered ||
        _isHandleDragging;

    return MouseRegion(
      opaque: false,
      // Keep spatially separated handles reachable across transparent parts
      // of a view cone without blocking pointer targets underneath.
      hitTestBehavior: HitTestBehavior.translucent,
      onEnter: (_) => _showTargetHandle(),
      onExit: (_) => _scheduleTargetHandleHide(),
      child: Transform.rotate(
        angle: widget.rotation,
        alignment: Alignment.topLeft,
        origin: rotationOrigin,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            if (widget.showHandle && !widget.isDragging && !isScreenshot)
              Positioned(
                left: coordinateSystem.scale(
                  (widget.buttonLeft ?? widget.origin.dx - 7.5),
                ),
                top: coordinateSystem.scale((widget.buttonTop ?? 0)),
                child: ShapeIndicatorFade(
                  visible: showHandle,
                  child: MouseRegion(
                    onEnter: (_) {
                      _hoverExitTimer?.cancel();
                      setState(() {
                        _isExitGraceActive = false;
                        _isHandleHovered = true;
                      });
                      _animationController.forward();
                    },
                    onExit: (_) {
                      setState(() {
                        _isHandleHovered = false;
                      });
                      if (!_isHandleDragging) {
                        _animationController.reverse();
                      }
                    },
                    child: SizedBox(
                      width: buttonSize,
                      height: buttonSize,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (details) {
                            setState(() {
                              _isHandleDragging = true;
                            });
                            _animationController.forward();
                            widget.onPanStart(details);
                          },
                          onPanUpdate: widget.onPanUpdate,
                          onPanEnd: (details) {
                            widget.onPanEnd(details);
                            setState(() {
                              _isHandleDragging = false;
                            });
                            if (!_isHandleHovered) {
                              _animationController.reverse();
                            }
                          },
                          onTap: () {},
                          child: Center(
                            child: AnimatedBuilder(
                              animation: _scaleAnimation,
                              builder: (context, child) {
                                return Transform.scale(
                                  scale: _scaleAnimation.value,
                                  child: child,
                                );
                              },
                              child: SizedBox(
                                width: buttonSize,
                                height: buttonSize,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: _isHandleHovered
                                        ? Colors.white
                                        : Colors.white.withAlpha(200),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
// }
// class RotatableWidget extends StatefulWidget {
//   final Widget child;
//   final double rotation;
//   final Offset origin;
//   final Function(DragUpdateDetails details) onPanUpdate;
//   final Function(DragStartDetails details) onPanStart;

//   final Function(DragEndDetails details) onPanEnd;
//   final bool isDragging;
//   final double? buttonLeft;
//   final double? buttonTop;
//   RotatableWidget({
//     super.key,
//     required this.child,
//     required this.rotation,
//     required this.onPanUpdate,
//     required this.onPanStart,
//     required this.onPanEnd,
//     required this.origin,
//     required this.isDragging,
//     this.buttonLeft,
//     this.buttonTop,
//   });
//   bool isHovered = false;

//   @override
//   State<RotatableWidget> createState() => _RotatableWidgetState();
// }

// class _RotatableWidgetState extends State<RotatableWidget> {
//   @override
//   Widget build(BuildContext context) {

//   }
// }
