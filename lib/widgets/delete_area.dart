import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/widgets/delete_helpers.dart';
import 'package:icarus/widgets/sidebar_widgets/delete_options.dart';

class DeleteArea extends ConsumerStatefulWidget {
  const DeleteArea({super.key});

  @override
  ConsumerState<DeleteArea> createState() => _DeleteAreaState();
}

class _DeleteAreaState extends ConsumerState<DeleteArea>
    with SingleTickerProviderStateMixin {
  static const Duration _hoverCloseDelay = Duration(milliseconds: 150);
  static const Duration _openDuration = Duration(milliseconds: 210);
  static const Duration _closeDuration = Duration(milliseconds: 140);

  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _layerLink = LayerLink();
  final FocusNode _focusNode = FocusNode(debugLabel: 'delete-area');
  final Object _tapRegionGroup = Object();

  late final AnimationController _menuAnimationController = AnimationController(
    vsync: this,
    duration: _openDuration,
    reverseDuration: _closeDuration,
  );

  Timer? _closeTimer;
  late final ProviderSubscription<DeleteMenuState> _deleteMenuSubscription;
  bool _isMenuOpen = false;
  bool _isPointerOverTarget = false;
  bool _isPointerOverMenu = false;
  bool _isDragHoveringTarget = false;
  bool _openedByExplicitAction = false;
  int _lastHandledRequestId = -1;
  bool _isTearingDown = false;

  @override
  void initState() {
    super.initState();
    _deleteMenuSubscription = ref.listenManual(
      deleteMenuProvider,
      _handleProviderRequest,
    );
  }

  @override
  void activate() {
    super.activate();
    _isTearingDown = false;
  }

  @override
  void deactivate() {
    _isTearingDown = true;
    _hideOverlayImmediate();
    super.deactivate();
  }

  @override
  void dispose() {
    _isTearingDown = true;
    _deleteMenuSubscription.close();
    _hideOverlayImmediate();
    _menuAnimationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleProviderRequest(DeleteMenuState? _, DeleteMenuState next) {
    if (_isTearingDown || !mounted) return;
    if (_lastHandledRequestId == next.requestId) return;
    _lastHandledRequestId = next.requestId;

    if (next.isOpenRequested && next.reason != null) {
      _openMenu(next.reason!);
    } else {
      _closeMenu();
    }
  }

  void _cancelCloseTimer() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  void _hideOverlayImmediate() {
    _cancelCloseTimer();
    _menuAnimationController.stop(canceled: true);
    _menuAnimationController.value = 0;
    if (_focusNode.hasFocus) {
      _focusNode.unfocus();
    }
    if (_overlayController.isShowing) {
      _overlayController.hide();
    }
    _isMenuOpen = false;
    _isPointerOverMenu = false;
    _isPointerOverTarget = false;
    _isDragHoveringTarget = false;
    _openedByExplicitAction = false;
  }

  Future<void> _openMenu(DeleteMenuOpenReason reason) async {
    if (_isTearingDown || !mounted || _isDragHoveringTarget) return;

    _cancelCloseTimer();
    _openedByExplicitAction = reason != DeleteMenuOpenReason.hover;

    if (!_isMenuOpen) {
      if (!_overlayController.isShowing) {
        _overlayController.show();
      }
      setState(() {
        _isMenuOpen = true;
      });
    }

    if (!_focusNode.hasFocus && !_isTearingDown && mounted) {
      _focusNode.requestFocus();
    }

    await _menuAnimationController.forward();
    if (_isTearingDown || !mounted) return;
  }

  Future<void> _closeMenu() async {
    if (_isTearingDown || !mounted) return;
    _cancelCloseTimer();
    _openedByExplicitAction = false;
    if (!_isMenuOpen) return;

    await _menuAnimationController.reverse();
    if (_isTearingDown || !mounted) return;

    if (_overlayController.isShowing) {
      _overlayController.hide();
    }
    setState(() {
      _isMenuOpen = false;
      _isPointerOverMenu = false;
    });
  }

  void _scheduleCloseIfNeeded() {
    if (_openedByExplicitAction || _isPointerOverTarget || _isPointerOverMenu) {
      return;
    }

    _cancelCloseTimer();
    _closeTimer = Timer(_hoverCloseDelay, () {
      if (_isTearingDown || !mounted) return;
      if (!_openedByExplicitAction &&
          !_isPointerOverTarget &&
          !_isPointerOverMenu) {
        _closeMenu();
      }
    });
  }

  void _handleTargetHover(bool isHovered) {
    if (_isTearingDown || !mounted) return;
    setState(() {
      _isPointerOverTarget = isHovered;
    });

    if (isHovered) {
      _openMenu(DeleteMenuOpenReason.hover);
    } else {
      _scheduleCloseIfNeeded();
    }
  }

  void _handleMenuHover(bool isHovered) {
    if (_isTearingDown || !mounted) return;
    _cancelCloseTimer();
    setState(() {
      _isPointerOverMenu = isHovered;
    });
    if (!isHovered) {
      _scheduleCloseIfNeeded();
    }
  }

  void _handleActionDismiss() {
    ref.read(deleteMenuProvider.notifier).requestClose();
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(screenshotProvider)) {
      return const SizedBox.shrink();
    }

    final bool isEmphasized =
        (_isPointerOverTarget || _isMenuOpen) && !_isDragHoveringTarget;
    final Color fillColor = _isDragHoveringTarget
        ? Settings.tacticalVioletTheme.destructive
        : isEmphasized
            ? Settings.tacticalVioletTheme.destructive.withValues(alpha: 0.2)
            : Settings.tacticalVioletTheme.destructive.withValues(alpha: 0.1);
    final Color borderColor = _isDragHoveringTarget
        ? Settings.tacticalVioletTheme.destructive
        : isEmphasized
            ? Settings.tacticalVioletTheme.destructive.withValues(alpha: 0.85)
            : Settings.tacticalVioletTheme.destructive.withValues(alpha: 0.2);
    final Color iconColor = _isDragHoveringTarget
        ? Settings.tacticalVioletTheme.foreground
        : Settings.tacticalVioletTheme.destructive;
    final Color shortcutColor = _isDragHoveringTarget
        ? Settings.tacticalVioletTheme.foreground.withValues(alpha: 0.9)
        : Settings.tacticalVioletTheme.mutedForeground;
    final Duration targetDuration = _isDragHoveringTarget
        ? const Duration(milliseconds: 100)
        : const Duration(milliseconds: 140);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: CompositedTransformTarget(
        link: _layerLink,
        child: OverlayPortal(
          controller: _overlayController,
          overlayChildBuilder: (context) {
            return CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.centerLeft,
              followerAnchor: Alignment.centerRight,
              offset: const Offset(-8, 0),
              child: Align(
                alignment: Alignment.centerRight,
                widthFactor: 1,
                heightFactor: 1,
                child: SizedBox(
                  width: 146,
                  height: 98,
                  child: Material(
                    color: Colors.transparent,
                    child: TapRegion(
                      groupId: _tapRegionGroup,
                      onTapOutside: (_) => _handleActionDismiss(),
                      child: DeleteOptions(
                        animation: _menuAnimationController,
                        onMenuEntered: () => _handleMenuHover(true),
                        onMenuExited: () => _handleMenuHover(false),
                        onCloseRequested: _handleActionDismiss,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
          child: TapRegion(
            groupId: _tapRegionGroup,
            onTapOutside: (_) => _handleActionDismiss(),
            child: Focus(
              focusNode: _focusNode,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) {
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  _handleActionDismiss();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: SizedBox(
                height: 70,
                width: 70,
                child: DragTarget<PlacedWidget>(
                  builder: (context, candidateData, rejectedData) {
                    final isDragHovering = candidateData.isNotEmpty;
                    if (_isDragHoveringTarget != isDragHovering) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        setState(() {
                          _isDragHoveringTarget = isDragHovering;
                        });
                        if (isDragHovering) {
                          _handleActionDismiss();
                        }
                      });
                    }

                    return MouseRegion(
                      onEnter: (_) => _handleTargetHover(true),
                      onExit: (_) => _handleTargetHover(false),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          ref.read(deleteMenuProvider.notifier).requestOpen(
                                reason: DeleteMenuOpenReason.click,
                              );
                        },
                        child: AnimatedScale(
                          scale: _isDragHoveringTarget
                              ? 1.0
                              : (isEmphasized ? 1.03 : 1.0),
                          duration: targetDuration,
                          curve: _isDragHoveringTarget
                              ? Curves.easeOutCubic
                              : Curves.easeOut,
                          child: AnimatedContainer(
                            duration: targetDuration,
                            curve: _isDragHoveringTarget
                                ? Curves.easeOutCubic
                                : Curves.easeOut,
                            decoration: BoxDecoration(
                              color: fillColor,
                              borderRadius: BorderRadius.zero,
                              border: Border.all(
                                color: borderColor,
                                width: 2,
                              ),
                            ),
                            child: Stack(
                              children: [
                                Center(
                                  child: Icon(
                                    Icons.delete_outline,
                                    size: 24,
                                    color: iconColor,
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Padding(
                                    padding: const EdgeInsets.all(4.0),
                                    child: Text(
                                      ShortcutInfo.openDeleteMenuKey.keyLabel
                                          .toUpperCase(),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            color: shortcutColor,
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  onAcceptWithDetails: (dragData) {
                    deletePlacedWidget(ref, dragData.data);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
