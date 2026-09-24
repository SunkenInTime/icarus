import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ColorButtons extends ConsumerStatefulWidget {
  const ColorButtons({
    super.key,
    required this.color,
    required this.isSelected,
    required this.onTap,
    required this.height,
    required this.width,
  });
  final double height;
  final double width;
  final bool isSelected;
  final Color color;
  final VoidCallback onTap;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ColorButtonsState();
}

class _ColorButtonsState extends ConsumerState<ColorButtons> {
  final _hoverColor = Colors.white;
  // final _selectColor = const Color(0xFF2282FF);
  final _selectColor = Settings.accentInk;

  Color _currentColor = Colors.transparent;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        border: Border.all(
          color: widget.isSelected ? _selectColor : _currentColor,
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
                color: widget.color,
                // boxShadow: const [
                //   BoxShadow(
                //     blurRadius: 4,
                //     color: Colors.black,
                //     offset: Offset(0, 4),
                //   ),
                // ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// class ColorButtons extends ConsumerWidget {
//   const ColorButtons({
//     super.key,
//     required this.color,
//     required this.isSelected,
//     required this.onTap,

//   });
//   final bool isSelected;
//   final Color color;
//   final VoidCallback onTap;

//   @override
//   Widget build(BuildContext context, WidgetRef ref) {

//     return Container(
//       decoration: BoxDecoration(
//         borderRadius: const BorderRadius.all(Radius.circular(4)),
//         border: Border.all(
//           color: const Color.fromARGB(255, 34, 130, 255),
//           width: 3,
//           strokeAlign: BorderSide.strokeAlignCenter,
//         ),
//       ),
//       height: 26,
//       width: 26,
//       child: InkWell(
//         onTap: onTap,
//         onHover: (value) {

//         },
//         child: Center(
//           child: Container(
//             height: 24,
//             width: 24,
//             decoration: BoxDecoration(
//               borderRadius: const BorderRadius.all(Radius.circular(4)),
//               border: Border.all(
//                 color: const Color(0xFF272727),
//                 width: 1,
//                 strokeAlign: BorderSide.strokeAlignCenter,
//               ),
//               color: color,
//               // boxShadow: const [
//               //   BoxShadow(
//               //     blurRadius: 4,
//               //     color: Colors.black,
//               //     offset: Offset(0, 4),
//               //   ),
//               // ],
//             ),
//           ),
//         ),
//       ),
//     );
//   }
// }
