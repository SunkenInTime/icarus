import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/widgets/delete_helpers.dart';

class DeleteCapture extends ConsumerWidget {
  const DeleteCapture({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DragTarget<PlacedWidget>(
      builder: (context, candidateData, rejectedData) {
        return const SizedBox.expand();
      },
      onAcceptWithDetails: (dragData) {
        deletePlacedWidget(ref, dragData.data);
      },
    );
  }
}
