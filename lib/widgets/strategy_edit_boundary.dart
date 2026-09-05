import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';

/// Disables controls that mutate the open strategy when it is view-only.
class StrategyEditBoundary extends ConsumerWidget {
  const StrategyEditBoundary({
    super.key,
    required this.child,
    this.disabledOpacity = 1,
  });

  final Widget child;
  final double disabledOpacity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(
      currentStrategyCapabilitiesProvider.select(
        (capabilities) => capabilities.canEditPages,
      ),
    );

    return AbsorbPointer(
      absorbing: !canEdit,
      child: ExcludeFocus(
        excluding: !canEdit,
        child: Opacity(
          opacity: canEdit ? 1 : disabledOpacity,
          child: child,
        ),
      ),
    );
  }
}
