import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';

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
    this.isDynamicWidth = false,
    this.isIconRight = false,
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
  final bool isDynamicWidth;
  final bool isIconRight;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ButtonStyle(
      alignment: Alignment.center,
      padding: padding,
      // Allow narrow widths when dynamic width is requested
      minimumSize:
          isDynamicWidth ? WidgetStateProperty.all(Size(0, height)) : null,
      backgroundColor: WidgetStateProperty.all(backgroundColor),
      shape: WidgetStateProperty.resolveWith<OutlinedBorder>(
        (Set<WidgetState> states) {
          if (states.contains(WidgetState.hovered)) {
            return RoundedRectangleBorder(
              side:
                  const BorderSide(color: Colors.deepPurpleAccent, width: 2.0),
              borderRadius: BorderRadius.circular(8.0),
            );
          }
          return RoundedRectangleBorder(
            side: const BorderSide(color: Settings.highlightColor, width: 2.0),
            borderRadius: BorderRadius.circular(8.0),
          );
        },
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

    final button = icon != null
        ? TextButton(
            onPressed: onPressed,
            style: style,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: isIconRight
                  ? [labelText, const SizedBox(width: 8), icon!]
                  : [icon!, const SizedBox(width: 8), labelText],
            ),
          )
        : TextButton(
            onPressed: onPressed,
            style: style,
            child: labelText,
          );

    // When dynamic, size to content; otherwise respect explicit width
    return SizedBox(
      height: height,
      width: isDynamicWidth ? null : width,
      child: isDynamicWidth ? IntrinsicWidth(child: button) : button,
    );
  }
}
