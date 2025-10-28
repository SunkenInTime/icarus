import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CustomButton extends ConsumerWidget {
  const CustomButton({
    required this.onPressed,
    required this.height,
    this.icon,
    required this.label,
    this.labelColor = Colors.white,
    this.backgroundColor = Colors.deepPurple,
    this.width,
    this.padding,
    this.fontWeight,
    super.key,
  });

  final Function()? onPressed;
  final double height;
  final double? width;
  final Widget? icon;
  final String label;
  final Color labelColor;
  final Color backgroundColor;
  final FontWeight? fontWeight;
  final WidgetStateProperty<EdgeInsetsGeometry>? padding;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ButtonStyle(
      alignment: Alignment.center,
      padding: padding,
      backgroundColor: WidgetStateProperty.all(backgroundColor),
      shape: WidgetStateProperty.all(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8.0),
        ),
      ),
      overlayColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) {
          if (states.contains(WidgetState.pressed)) {
            return Colors.white.withAlpha(51);
          }
          return null;
        },
      ),
    );

    final labelText = Text(
      label,
      style: TextStyle(color: labelColor, fontWeight: fontWeight),
    );

    return SizedBox(
      height: height,
      width: width,
      child: icon != null
          ? TextButton.icon(
              onPressed: onPressed,
              icon: icon!,
              label: labelText,
              style: style,
            )
          : TextButton(
              onPressed: onPressed,
              style: style,
              child: labelText,
            ),
    );
  }
}
