import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/screenshot_provider.dart';

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
  late final AnimationController _animationController;
  late final Animation<double> _scaleAnimation;
  bool _isHovered = false;
  bool _isHandleDragging = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.03,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final rotationOrigin = widget.origin
        .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);
    final isScreenshot = ref.watch(screenshotProvider);
    final buttonSize = coordinateSystem.scale(15);
    return Transform.rotate(
      angle: widget.rotation,
      alignment: Alignment.topLeft,
      origin: rotationOrigin,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (widget.showHandle && !widget.isDragging && !isScreenshot)
            Positioned(
              left: coordinateSystem
                  .scale((widget.buttonLeft ?? widget.origin.dx - 7.5)),
              top: coordinateSystem.scale((widget.buttonTop ?? 0)),
              child: MouseRegion(
                onEnter: (event) {
                  setState(() {
                    _isHovered = true;
                  });
                  _animationController.forward();
                },
                onExit: (event) {
                  setState(() {
                    _isHovered = false;
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
                        if (!_isHovered) {
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
                                color: _isHovered
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
        ],
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
