import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_visibility_context_menu.dart';
import 'package:icarus/widgets/draggable_widgets/ability/lineup_ability_stack_selector.dart';
import 'package:icarus/widgets/line_up_media_carousel.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class MouseWatch extends ConsumerStatefulWidget {
  const MouseWatch({
    required this.child,
    super.key,
    this.cursor = SystemMouseCursors.basic,
    this.deleteTarget,
    this.lineUpId,
    this.lineUpItemId,
    this.contextMenuItems,
    this.onTap,
  });

  final String? lineUpId;
  final String? lineUpItemId;
  final Widget child;
  final HoveredDeleteTarget? deleteTarget;
  final SystemMouseCursor cursor;
  final List<ShadContextMenuItem>? contextMenuItems;
  final VoidCallback? onTap;
  @override
  ConsumerState<MouseWatch> createState() => _MouseWatchState();
}

class _MouseWatchState extends ConsumerState<MouseWatch> {
  bool isMouseInRegion = false;
  final Object _ownerToken = Object();
  final GlobalKey _hitboxKey = GlobalKey();
  ProviderContainer? _container;
  bool _hoverCleanupScheduled = false;
  bool _hitboxMeasurementScheduled = false;
  bool _hitboxCleanupScheduled = false;
  Rect? _lastRegisteredHitbox;
  String? _registeredGroupId;
  String? _registeredItemId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  @override
  void didUpdateWidget(covariant MouseWatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    final didChangeLineUpTarget = oldWidget.lineUpId != widget.lineUpId ||
        oldWidget.lineUpItemId != widget.lineUpItemId;

    if (didChangeLineUpTarget) {
      _scheduleHitboxUnregister(
        groupId: oldWidget.lineUpId,
        itemId: oldWidget.lineUpItemId,
      );
      _lastRegisteredHitbox = null;
    }
  }

  @override
  void dispose() {
    _scheduleHitboxUnregister(
      groupId: _registeredGroupId,
      itemId: _registeredItemId,
      container: _container,
    );
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
    activeContainer
        .read(hoveredLineUpTargetProvider.notifier)
        .clearIfOwned(_ownerToken);
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

  bool get _isStackAwareLineUpItem =>
      widget.lineUpId != null && widget.lineUpItemId != null;

  bool get _hasResolvedLineUpItem =>
      widget.lineUpId != null &&
      widget.lineUpItemId != null &&
      ref.read(lineUpProvider.notifier).getItemById(
            groupId: widget.lineUpId!,
            itemId: widget.lineUpItemId!,
          ) != null;

  void _performHitboxUnregister({
    String? groupId,
    String? itemId,
    ProviderContainer? container,
  }) {
    final activeGroupId = groupId;
    final activeItemId = itemId;
    if (activeGroupId == null || activeItemId == null) {
      return;
    }

    final activeContainer = container ?? _container;
    activeContainer
        ?.read(lineUpAbilityHitboxRegistryProvider.notifier)
        .unregister(groupId: activeGroupId, itemId: activeItemId);

    if (_registeredGroupId == activeGroupId && _registeredItemId == activeItemId) {
      _registeredGroupId = null;
      _registeredItemId = null;
    }
  }

  void _scheduleHitboxUnregister({
    String? groupId,
    String? itemId,
    ProviderContainer? container,
  }) {
    final activeGroupId = groupId;
    final activeItemId = itemId;
    final activeContainer = container ?? _container;
    if (activeGroupId == null ||
        activeItemId == null ||
        activeContainer == null ||
        _hitboxCleanupScheduled) {
      return;
    }

    _hitboxCleanupScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hitboxCleanupScheduled = false;
      _performHitboxUnregister(
        groupId: activeGroupId,
        itemId: activeItemId,
        container: activeContainer,
      );
    });
  }

  void _scheduleHitboxMeasurement() {
    if (!_isStackAwareLineUpItem || !_hasResolvedLineUpItem) {
      _scheduleHitboxUnregister(
        groupId: widget.lineUpId,
        itemId: widget.lineUpItemId,
      );
      _lastRegisteredHitbox = null;
      return;
    }

    if (_hitboxMeasurementScheduled) {
      return;
    }

    _hitboxMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hitboxMeasurementScheduled = false;
      if (!mounted) {
        return;
      }

      final renderObject = _hitboxKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) {
        return;
      }

      final rect = MatrixUtils.transformRect(
        renderObject.getTransformTo(null),
        Offset.zero & renderObject.size,
      );
      if (_lastRegisteredHitbox == rect) {
        return;
      }

      _lastRegisteredHitbox = rect;
      _registeredGroupId = widget.lineUpId;
      _registeredItemId = widget.lineUpItemId;
      ref.read(lineUpAbilityHitboxRegistryProvider.notifier).register(
            groupId: widget.lineUpId!,
            itemId: widget.lineUpItemId!,
            globalRect: rect,
          );
    });
  }

  List<LineUpAbilityStackCandidate> _resolveStackCandidates(Offset globalPosition) {
    return resolveLineUpAbilityStackCandidates(
      lineUpState: ref.read(lineUpProvider),
      hitboxes: ref.read(lineUpAbilityHitboxRegistryProvider),
      globalPosition: globalPosition,
    );
  }

  Future<LineUpAbilityStackCandidate?> _selectLineUpAbilityCandidate(
    Offset globalPosition,
  ) async {
    final candidates = _resolveStackCandidates(globalPosition);
    if (candidates.length <= 1) {
      return candidates.isEmpty ? null : candidates.single;
    }

    return showLineUpAbilityStackSelector(
      context: context,
      globalPosition: globalPosition,
      candidates: candidates,
    );
  }

  Future<void> _openLineUpMediaFor({
    required String groupId,
    required String itemId,
  }) async {
    final item = ref.read(lineUpProvider.notifier).getItemById(
          groupId: groupId,
          itemId: itemId,
        );
    if (item == null || !mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => LineUpMediaCarousel(
        lineUpGroupId: groupId,
        lineUpItemId: itemId,
        images: item.images,
        youtubeLink: item.youtubeLink,
      ),
    );
  }

  List<ShadContextMenuItem>? _buildLineUpItemMenuItems(
    LineUpAbilityStackCandidate candidate,
  ) {
    return buildAbilityContextMenuItems(
      ref,
      candidate.ability,
      lineUpGroupId: candidate.groupId,
      lineUpItemId: candidate.itemId,
      includeDelete: true,
    );
  }

  Future<void> _handleStackAwarePrimaryTap(TapUpDetails details) async {
    final candidate = await _selectLineUpAbilityCandidate(details.globalPosition);
    if (candidate == null) {
      return;
    }

    await _openLineUpMediaFor(
      groupId: candidate.groupId,
      itemId: candidate.itemId,
    );
  }

  Future<void> _handleStackAwareSecondaryTap(TapUpDetails details) async {
    final candidate = await _selectLineUpAbilityCandidate(details.globalPosition);
    if (candidate == null || !mounted) {
      return;
    }

    final menuItems = _buildLineUpItemMenuItems(candidate);
    if (menuItems == null || menuItems.isEmpty) {
      return;
    }

    await showLineUpAbilityContextMenu(
      context: context,
      globalPosition: details.globalPosition,
      items: menuItems,
    );
  }

  @override
  Widget build(BuildContext context) {
    final LineUpItem? lineUpItem = ref.watch(
      lineUpProvider.select((state) {
        final groupId = widget.lineUpId;
        final itemId = widget.lineUpItemId;
        if (groupId == null || itemId == null) {
          return null;
        }
        for (final group in state.groups) {
          if (group.id != groupId) {
            continue;
          }
          for (final item in group.items) {
            if (item.id == itemId) {
              return item;
            }
          }
          return null;
        }
        return null;
      }),
    );
    final lineUpNotes = lineUpItem?.notes;
    final hasLineUpNote = (lineUpNotes?.trim().isNotEmpty ?? false);
    _scheduleHitboxMeasurement();
    final menuItems = widget.contextMenuItems ??
        (widget.lineUpId == null
            ? null
            : [
                ShadContextMenuItem(
                  leading: Icon(
                    Icons.delete,
                    color: Settings.tacticalVioletTheme.destructive,
                  ),
                  child: const Text('Delete'),
                  onPressed: () {
                    ref.read(lineUpProvider.notifier).deleteGroupById(
                          widget.lineUpId!,
                        );
                  },
                ),
              ]);

    final content = MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) {
        if (widget.lineUpId != null) {
          final hoverNotifier = ref.read(hoveredLineUpTargetProvider.notifier);
          if (widget.lineUpItemId != null) {
            hoverNotifier.setHoveredItem(
              groupId: widget.lineUpId!,
              itemId: widget.lineUpItemId!,
              ownerToken: _ownerToken,
            );
          } else {
            hoverNotifier.setHoveredGroup(
              groupId: widget.lineUpId!,
              ownerToken: _ownerToken,
            );
          }
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
      child: KeyedSubtree(
        key: _hitboxKey,
        child: widget.child,
      ),
    );

    final effectiveOnTap = widget.onTap ??
        (widget.lineUpId == null || lineUpItem == null
            ? null
            : () {
                showDialog(
                  context: context,
                  builder: (context) => LineUpMediaCarousel(
                    lineUpGroupId: widget.lineUpId!,
                    lineUpItemId: widget.lineUpItemId!,
                    images: lineUpItem.images,
                    youtubeLink: lineUpItem.youtubeLink,
                  ),
                );
              });

    Widget interactiveChild = content;
    if (_isStackAwareLineUpItem) {
      interactiveChild = GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTapUp: _handleStackAwarePrimaryTap,
        onSecondaryTapUp: _handleStackAwareSecondaryTap,
        child: interactiveChild,
      );
    } else if (effectiveOnTap != null) {
      interactiveChild = GestureDetector(
        onTap: effectiveOnTap,
        child: interactiveChild,
      );
    }
    if (!_isStackAwareLineUpItem && menuItems != null && menuItems.isNotEmpty) {
      interactiveChild = ShadContextMenuRegion(
        items: menuItems,
        child: interactiveChild,
      );
    }

    return RepaintBoundary(
      child: widget.lineUpId == null
          ? interactiveChild
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
              child: interactiveChild,
            ),
    );
  }
}
