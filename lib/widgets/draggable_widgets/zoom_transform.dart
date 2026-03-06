import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';

class ZoomTransform extends ConsumerWidget {
  const ZoomTransform({
    super.key,
    required this.child,
  });
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Transform.scale(
      scale: ref.watch(screenZoomProvider),
      alignment: Alignment.topLeft,
      child: child,
    );
  }
}

