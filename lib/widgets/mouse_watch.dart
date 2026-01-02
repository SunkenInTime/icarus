import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/widgets/line_up_media_carousel.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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

  // ...existing code...
  @override
  Widget build(BuildContext context) {
    final lineUpState = ref.watch(lineUpProvider);

    LineUp? lineUp;
    String? lineUpNotes;
    if (widget.lineUpId != null) {
      final index = lineUpState.lineUps
          .indexWhere((lineUp) => lineUp.id == widget.lineUpId);
      if (index != -1) {
        lineUp = lineUpState.lineUps[index];
        lineUpNotes = lineUpState.lineUps[index].notes;
      }
    }
    final hasLineUpNote = (lineUpNotes?.trim().isNotEmpty ?? false);

    final content = MouseRegion(
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
        if (widget.lineUpId != null &&
            ref.read(hoveredLineUpIdProvider) == widget.lineUpId) {
          ref.read(hoveredLineUpIdProvider.notifier).setHoveredLineUpId(null);
        }
        setState(() {
          isMouseInRegion = false;
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
          ),
        },
        child: widget.child,
      ),
    );

    return RepaintBoundary(
      child: widget.lineUpId == null
          ? content
          : ShadPortal(
              visible: isMouseInRegion && hasLineUpNote,
              portalBuilder: (context) => Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Container(
                    padding: const EdgeInsets.all(8.0),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      textAlign: TextAlign.center,
                      "$lineUpNotes",
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),

              anchor: const ShadAnchor(
                childAlignment: Alignment.bottomCenter,
                overlayAlignment: Alignment.topCenter,
              ),

              // const Aligned(
              //   follower: Alignment.bottomCenter,
              //   target: Alignment.topCenter,
              // ),
              child: ShadContextMenuRegion(
                items: [
                  ShadContextMenuItem(
                    leading: Icon(
                      Icons.delete,
                      color: Settings.tacticalVioletTheme.destructive,
                    ),
                    child: const Text('Delete'),
                    onPressed: () {
                      ref
                          .read(lineUpProvider.notifier)
                          .deleteLineUpById(widget.lineUpId!);
                    },
                  ),
                ],
                child: GestureDetector(
                  child: content,
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => LineUpMediaCarousel(
                        lineUpId: widget.lineUpId!,
                        images: lineUp!.images,
                        youtubeLink: lineUp.youtubeLink,
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }
// ...existing code...
}
