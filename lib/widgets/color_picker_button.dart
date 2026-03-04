import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ColorPickerButton extends ConsumerStatefulWidget {
  const ColorPickerButton({
    super.key,
    required this.onTap,
    required this.height,
    required this.width,
  });
  final double height;
  final double width;
  final VoidCallback onTap;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ColorButtonsState();
}

class _ColorButtonsState extends ConsumerState<ColorPickerButton> {
  final _hoverColor = Colors.white;
  // final _selectColor = const Color(0xFF2282FF);

  Color _currentColor = Colors.transparent;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        border: Border.all(
          color: _currentColor,
          width: 3,
          strokeAlign: BorderSide.strokeAlignCenter,
        ),
      ),
      height: widget.height,
      width: widget.width,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (event) {
          setState(() {
            _currentColor = _hoverColor;
          });
        },
        onExit: (event) {
          setState(() {
            _currentColor = Colors.transparent;
          });
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: Center(
            child: Container(
              height: widget.height - 2,
              width: widget.width - 2,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(Radius.circular(4)),
                border: Border.all(
                  color: const Color(0xFF272727),
                  width: 1,
                  strokeAlign: BorderSide.strokeAlignCenter,
                ),
              ),
              child: const Icon(Icons.add),
            ),
          ),
        ),
      ),
    );
  }
}
