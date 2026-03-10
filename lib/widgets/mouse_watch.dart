import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/widgets/line_up_media_carousel.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class MouseWatch extends ConsumerStatefulWidget {
  const MouseWatch({
    required this.child,
    super.key,
    this.cursor = SystemMouseCursors.basic,
    this.deleteTarget,
    this.lineUpId,
  });

  final String? lineUpId;
  final Widget child;
  final HoveredDeleteTarget? deleteTarget;
  final SystemMouseCursor cursor;
  @override
  ConsumerState<MouseWatch> createState() => _MouseWatchState();
}

class _MouseWatchState extends ConsumerState<MouseWatch> {
  bool isMouseInRegion = false;
  final Object _ownerToken = Object();
  ProviderContainer? _container;
  bool _hoverCleanupScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    _scheduleHoverCleanup(container: _container);
    super.dispose();
  }

  void _publishHoveredDeleteTarget() {
    final target = widget.deleteTarget;
    if (target == null) return;

    ref.read(hoveredDeleteTargetProvider.notifier).state =
        target.copyWith(ownerToken: _ownerToken);
  }

  void _clearHoveredDeleteTargetIfOwned({ProviderContainer? container}) {
    final activeContainer = container ?? _container;
    if (activeContainer == null) return;
    final hoveredTarget = activeContainer.read(hoveredDeleteTargetProvider);
    if (hoveredTarget?.ownerToken != _ownerToken) return;

    activeContainer.read(hoveredDeleteTargetProvider.notifier).state = null;
  }

  void _clearHoveredLineUpIfOwned({ProviderContainer? container}) {
    final activeContainer = container ?? _container;
    if (activeContainer == null || widget.lineUpId == null) return;
    if (activeContainer.read(hoveredLineUpIdProvider) != widget.lineUpId) {
      return;
    }

    activeContainer.read(hoveredLineUpIdProvider.notifier).setHoveredLineUpId(
          null,
        );
  }

  void _scheduleHoverCleanup({ProviderContainer? container}) {
    final activeContainer = container ?? _container;
    if (activeContainer == null || _hoverCleanupScheduled) return;

    _hoverCleanupScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hoverCleanupScheduled = false;
      _clearHoveredLineUpIfOwned(container: activeContainer);
      _clearHoveredDeleteTargetIfOwned(container: activeContainer);
    });
  }

  @override
  Widget build(BuildContext context) {
    final LineUp? lineUp = widget.lineUpId == null
        ? null
        : ref.watch(
            lineUpProvider.select((state) {
              for (final lineUp in state.lineUps) {
                if (lineUp.id == widget.lineUpId) {
                  return lineUp;
                }
              }
              return null;
            }),
          );
    final lineUpNotes = lineUp?.notes;
    final hasLineUpNote = (lineUpNotes?.trim().isNotEmpty ?? false);

    final content = MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) {
        if (widget.lineUpId != null) {
          ref
              .read(hoveredLineUpIdProvider.notifier)
              .setHoveredLineUpId(widget.lineUpId);
        }
        _publishHoveredDeleteTarget();
        setState(() {
          isMouseInRegion = true;
        });
      },
      onExit: (_) {
        _scheduleHoverCleanup();
        setState(() {
          isMouseInRegion = false;
        });
      },
      child: widget.child,
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
}
