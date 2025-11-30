import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/shortcut_info.dart';

class MouseWatch extends ConsumerStatefulWidget {
  const MouseWatch({
    this.onDeleteKeyPressed,
    required this.child,
    super.key,
    this.cursor = SystemMouseCursors.basic,
    this.lineUpId,
  });

  final String? lineUpId;
  final Widget child;
  final VoidCallback? onDeleteKeyPressed;
  final SystemMouseCursor cursor;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _MouseWatchState();
}

class _MouseWatchState extends ConsumerState<MouseWatch> {
  bool isMouseInRegion = false;
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // return widget.child;
    return RepaintBoundary(
      child: MouseRegion(
        cursor: widget.cursor,
        onEnter: (_) {
          if (widget.lineUpId != null) {
            ref
                .read(hoveredLineUpIdProvider.notifier)
                .setHoveredLineUpId(widget.lineUpId);
          }

          setState(() {
            isMouseInRegion = true;
            _focusNode.requestFocus();
          });
        },
        onExit: (_) {
          if (widget.lineUpId != null) {
            if (ref.read(hoveredLineUpIdProvider) == widget.lineUpId) {
              ref
                  .read(hoveredLineUpIdProvider.notifier)
                  .setHoveredLineUpId(null);
            }
          }
          setState(() {
            isMouseInRegion = false;
            // _focusNode.unfocus();
          });
        },
        child: FocusableActionDetector(
          focusNode: _focusNode,
          shortcuts: ShortcutInfo.widgetShortcuts,
          actions: {
            WidgetDeleteIntent: CallbackAction<WidgetDeleteIntent>(
              onInvoke: (intent) {
                if (!isMouseInRegion) return;

                return widget.onDeleteKeyPressed?.call();
              },
            )
          },
          child: widget.child,
        ),
      ),
    );
  }
}
