import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/widgets/draggable_widgets/shared/framed_icon_shell.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class RoleIconUtilityWidget extends ConsumerWidget {
  const RoleIconUtilityWidget({
    super.key,
    required this.imagePath,
    required this.isAlly,
    required this.size,
    required this.id,
  });

  final String imagePath;
  final bool isAlly;
  final double size;
  final String? id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MouseWatch(
      cursor: SystemMouseCursors.click,
      deleteTarget: (id?.isNotEmpty ?? false)
          ? HoveredDeleteTarget.utility(id: id!, ownerToken: Object())
          : null,
      child: FramedIconShell(
        size: size,
        isAlly: isAlly,
        child: Image.asset(
          imagePath,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
