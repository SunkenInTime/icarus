import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_visibility_context_menu.dart';
import 'package:icarus/widgets/draggable_widgets/ability/lineup_ability_stack_selector.dart';
import 'package:icarus/widgets/dialogs/lineup_panel_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class MouseWatch extends ConsumerStatefulWidget {
  const MouseWatch({
    required this.child,
    super.key,
    this.cursor = SystemMouseCursors.basic,
    this.deleteTarget,
    this.lineUpOriginId,
    this.lineUpLandingId,
    this.contextMenuItems,
    this.onTap,
  }) : assert(lineUpOriginId == null || lineUpLandingId == null);

  /// Set when the child is a lineup origin (a placed agent).
  final String? lineUpOriginId;

  /// Set when the child is a lineup landing spot (a placed ability).
  final String? lineUpLandingId;
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
  bool _allowCleanupAfterUnmount = false;
  Rect? _lastRegisteredHitbox;
  String? _registeredLandingId;

  bool get _isLineUpEnd =>
      widget.lineUpOriginId != null || widget.lineUpLandingId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  @override
  void didUpdateWidget(covariant MouseWatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lineUpLandingId != widget.lineUpLandingId) {
      _scheduleHitboxUnregister(landingId: oldWidget.lineUpLandingId);
      _lastRegisteredHitbox = null;
    }
  }

  @override
  void dispose() {
    // The scoped provider distinguishes the offscreen capture tree from the
    // live tree; the global CoordinateSystem flag cannot, so gating on it
    // would also skip cleanup for live instances disposed during an export.
    final isOffscreenCapture = _container?.read(screenshotProvider) ?? false;
    if (!isOffscreenCapture) {
      _allowCleanupAfterUnmount = true;
      _scheduleHitboxUnregister(
        landingId: _registeredLandingId,
        container: _container,
      );
      _scheduleHoverCleanup(container: _container);
    }
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
    if (activeContainer == null || !_isLineUpEnd) return;
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
      if (!mounted && !_allowCleanupAfterUnmount) return;
      _clearHoveredLineUpIfOwned(container: activeContainer);
      _clearHoveredDeleteTargetIfOwned(container: activeContainer);
    });
  }

  bool get _isLanding => widget.lineUpLandingId != null;

  bool get _hasResolvedLanding =>
      _isLanding &&
      ref.read(lineUpProvider.notifier).landingById(widget.lineUpLandingId!) !=
          null;

  void _performHitboxUnregister({
    String? landingId,
    ProviderContainer? container,
  }) {
    if (landingId == null) {
      return;
    }

    final activeContainer = container ?? _container;
    activeContainer
        ?.read(lineUpAbilityHitboxRegistryProvider.notifier)
        .unregister(landingId: landingId);

    if (_registeredLandingId == landingId) {
      _registeredLandingId = null;
    }
  }

  void _scheduleHitboxUnregister({
    String? landingId,
    ProviderContainer? container,
  }) {
    final activeContainer = container ?? _container;
    if (landingId == null || activeContainer == null || _hitboxCleanupScheduled) {
      return;
    }

    _hitboxCleanupScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hitboxCleanupScheduled = false;
      if (!mounted && !_allowCleanupAfterUnmount) return;
      _performHitboxUnregister(
        landingId: landingId,
        container: activeContainer,
      );
    });
  }

  void _scheduleHitboxMeasurement() {
    if (!_hasResolvedLanding) {
      _scheduleHitboxUnregister(landingId: widget.lineUpLandingId);
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
      _registeredLandingId = widget.lineUpLandingId;
      ref.read(lineUpAbilityHitboxRegistryProvider.notifier).register(
            landingId: widget.lineUpLandingId!,
            globalRect: rect,
          );
    });
  }

  List<LineUpAbilityStackCandidate> _resolveStackCandidates(
      Offset globalPosition) {
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

  Future<void> _handleStackAwarePrimaryTap(TapUpDetails details) async {
    final candidate =
        await _selectLineUpAbilityCandidate(details.globalPosition);
    if (candidate == null || !mounted) {
      return;
    }

    await openLandingLineUps(context, ref, candidate.landingId);
  }

  Future<void> _handleStackAwareSecondaryTap(TapUpDetails details) async {
    final candidate =
        await _selectLineUpAbilityCandidate(details.globalPosition);
    if (candidate == null || !mounted) {
      return;
    }

    final menuItems = buildAbilityContextMenuItems(
      ref,
      candidate.ability,
      landingId: candidate.landingId,
      context: context,
    );
    if (menuItems == null || menuItems.isEmpty) {
      return;
    }

    await showLineUpAbilityContextMenu(
      context: context,
      globalPosition: details.globalPosition,
      items: menuItems,
    );
  }

  void _updateLineUpHoverState(bool isHovered) {
    // Only lineup widgets use this local state to control their notes portal.
    // Regular map widgets still publish their hovered delete target, but do
    // not need to rebuild just because a drag crossed their hitbox.
    if (!_isLineUpEnd || isMouseInRegion == isHovered) return;
    setState(() => isMouseInRegion = isHovered);
  }

  @override
  Widget build(BuildContext context) {
    if (CoordinateSystem.instance.isScreenshot) {
      return RepaintBoundary(child: widget.child);
    }

    final landingLinks = ref.watch(
      lineUpProvider.select((state) {
        final landingId = widget.lineUpLandingId;
        if (landingId == null) return const <LineUpLink>[];
        return state.linksToLanding(landingId);
      }),
    );
    final lineUpNotes =
        landingLinks.length == 1 ? landingLinks.single.notes : null;
    final hasLineUpNote = (lineUpNotes?.trim().isNotEmpty ?? false);
    _scheduleHitboxMeasurement();
    final menuItems = widget.contextMenuItems ??
        (widget.lineUpOriginId == null
            ? null
            : [
                ShadContextMenuItem(
                  leading: Icon(
                    Icons.delete,
                    color: Settings.tacticalVioletTheme.destructive,
                  ),
                  child: const Text('Delete origin and its lineups'),
                  onPressed: () {
                    ref
                        .read(lineUpProvider.notifier)
                        .deleteOrigin(widget.lineUpOriginId!);
                  },
                ),
              ]);

    final content = MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) {
        final hoverNotifier = ref.read(hoveredLineUpTargetProvider.notifier);
        if (widget.lineUpLandingId != null) {
          hoverNotifier.setHoveredLanding(
            landingId: widget.lineUpLandingId!,
            ownerToken: _ownerToken,
          );
        } else if (widget.lineUpOriginId != null) {
          hoverNotifier.setHoveredOrigin(
            originId: widget.lineUpOriginId!,
            ownerToken: _ownerToken,
          );
        }
        _publishHoveredDeleteTarget();
        _updateLineUpHoverState(true);
      },
      onExit: (_) {
        _scheduleHoverCleanup();
        _updateLineUpHoverState(false);
      },
      child: KeyedSubtree(
        key: _hitboxKey,
        child: widget.child,
      ),
    );

    final effectiveOnTap = widget.onTap ??
        (widget.lineUpOriginId == null
            ? null
            : () => showLineUpPanel(context, originId: widget.lineUpOriginId));

    Widget interactiveChild = content;
    if (_isLanding) {
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
    if (!_isLanding && menuItems != null && menuItems.isNotEmpty) {
      interactiveChild = ShadContextMenuRegion(
        items: menuItems,
        child: interactiveChild,
      );
    }

    return RepaintBoundary(
      child: !_isLineUpEnd
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
