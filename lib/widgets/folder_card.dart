import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_context_menu_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/drag_tilt_feedback.dart';
import 'package:icarus/widgets/drop_insertion_indicator.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/overflow_tooltip_text.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _cardWidth = 232;
const double _cardHeight = 124;

/// Half the gutter between cards in the library Wrap. Baked into each
/// card's drop hit area so hovering the gap itself targets a card and the
/// insertion caret never has a dead zone between neighbors. FolderContent
/// lays cards out with zero Wrap spacing to compensate.
const double folderCardGutterOutset = 7;
const double _pocketTop = 52;
const double _peekWidth = 208;
const double _peekHeight = 82;
const double _agentIconSize = 22;
const double _agentRowSpacing = 4;

const List<AgentRole> _roleOrder = [
  AgentRole.duelist,
  AgentRole.initiator,
  AgentRole.controller,
  AgentRole.sentinel,
];

/// Derived, render-time summary of a folder's contents.
class FolderCardViewData {
  FolderCardViewData({
    required this.folder,
    required List<StrategyData> strategies,
    required this.folderCount,
  })  : strategyCount = strategies.length,
        mapPeeks = _collectMapPeeks(strategies),
        agentTypes = _collectAgents(strategies);

  final Folder folder;
  final int strategyCount;
  final int folderCount;

  /// Distinct map thumbnail assets, most used first, capped at 2.
  final List<String> mapPeeks;

  /// Agents across all strategies, most frequent first (role breaks ties).
  final List<AgentType> agentTypes;

  static List<String> _collectMapPeeks(List<StrategyData> strategies) {
    final counts = <MapValue, int>{};
    for (final strategy in strategies) {
      counts[strategy.mapData] = (counts[strategy.mapData] ?? 0) + 1;
    }
    final ordered = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return [
      for (final map in ordered.take(2))
        'assets/maps/thumbnails/${Maps.mapNames[map]}_thumbnail.webp',
    ];
  }

  static List<AgentType> _collectAgents(List<StrategyData> strategies) {
    final counts = <AgentType, int>{};
    for (final strategy in strategies) {
      final seenInStrategy = <AgentType>{};
      for (final page in strategy.pages) {
        for (final agent in page.agentData) {
          seenInStrategy.add(agent.type);
        }
      }
      for (final type in seenInStrategy) {
        counts[type] = (counts[type] ?? 0) + 1;
      }
    }

    int roleRank(AgentType type) {
      final role = AgentData.agents[type]?.role;
      final index = role == null ? _roleOrder.length : _roleOrder.indexOf(role);
      return index < 0 ? _roleOrder.length : index;
    }

    final ordered = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        if (byCount != 0) return byCount;
        return roleRank(a).compareTo(roleRank(b));
      });
    return ordered;
  }
}

class FolderCard extends ConsumerStatefulWidget {
  const FolderCard({
    super.key,
    required this.data,
    this.isDemo = false,
  });

  final FolderCardViewData data;
  final bool isDemo;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _FolderCardState();
}

class _FolderCardState extends ConsumerState<FolderCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _openController;
  late final Animation<double> _open;
  bool _isHovered = false;
  bool _isMenuButtonHovered = false;
  bool _menuButtonWasOpenOnPointerDown = false;
  DropInsertionSide? _pinnedDropSide;
  final ShadContextMenuController _contextMenuController =
      ShadContextMenuController();
  final ShadContextMenuController _rightClickMenuController =
      ShadContextMenuController();
  final DragTiltController _dragTiltController = DragTiltController();

  Folder get _folder => widget.data.folder;

  @override
  void initState() {
    super.initState();
    _openController = AnimationController(
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
      vsync: this,
    );
    _open = CurvedAnimation(
      parent: _openController,
      curve: Curves.easeOutQuart,
      reverseCurve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _openController.dispose();
    _contextMenuController.dispose();
    _rightClickMenuController.dispose();
    super.dispose();
  }

  void _closeMenus() {
    _contextMenuController.hide();
    _rightClickMenuController.hide();
  }

  void _handleMenuButtonPressed() {
    if (_menuButtonWasOpenOnPointerDown) {
      _menuButtonWasOpenOnPointerDown = false;
      _closeMenus();
      return;
    }

    dismissLibraryContextMenus(ref);
    _contextMenuController.show();
  }

  Color get _baseColor =>
      _folder.customColor ??
      Folder.folderColorMap[_folder.color] ??
      Colors.grey;

  // Folder body tones: the raw preset colors are too loud for a large
  // surface, so they are pulled toward the workbench darks. The front
  // panel stays one step lighter than the back so the pocket reads.
  Color get _backTone => Color.lerp(_baseColor, const Color(0xff0c0c0e), 0.72)!;
  Color get _frontTone =>
      Color.lerp(_baseColor, const Color(0xff141416), 0.55)!;
  Color get _edgeTone => Color.lerp(_baseColor, Colors.white, 0.25)!;

  bool _isPinnedFolderReorderCandidate(
    GridItem item,
    Map<String, int> pinned,
    String id,
    bool isPinned,
  ) {
    return item is FolderItem &&
        item.folder.id != id &&
        isPinned &&
        pinned.containsKey(item.folder.id);
  }

  bool _isParentFolder(String folderId) {
    String? currentParentId = _folder.parentID;
    while (currentParentId != null) {
      if (currentParentId == folderId) return true;
      final parentFolder =
          ref.read(folderProvider.notifier).findFolderByID(currentParentId);
      currentParentId = parentFolder?.parentID;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      libraryContextMenuDismissalProvider,
      (_, __) => _closeMenus(),
    );

    final pinned = ref.watch(pinnedItemsProvider);
    final id = _folder.id;
    final isPinned = pinned.containsKey(id);

    // The DragTarget wraps the gutter padding (not just the card) so drops
    // register while hovering the gap between cards; the Draggable sits
    // inside so drags can only start from the card itself.
    return DragTarget<GridItem>(onWillAcceptWithDetails: (details) {
      final item = details.data;
      if (widget.isDemo) return false;
      if (item is FolderItem) {
        return item.folder.id != id && !_isParentFolder(item.folder.id);
      }
      return true;
    }, onMove: (details) {
      final item = details.data;
      final nextSide =
          _isPinnedFolderReorderCandidate(item, pinned, id, isPinned)
              ? resolveDropInsertionSide(
                  context: context,
                  globalOffset: details.offset,
                  current: _pinnedDropSide,
                )
              : null;
      if (nextSide != _pinnedDropSide) {
        setState(() => _pinnedDropSide = nextSide);
      }
    }, onLeave: (_) {
      if (_pinnedDropSide != null) {
        setState(() => _pinnedDropSide = null);
      }
      _syncOpenState(isDropTarget: false);
    }, onAcceptWithDetails: (details) async {
      if (widget.isDemo) return;
      final item = details.data;
      if (item is FolderItem &&
          item.folder.id != id &&
          isPinned &&
          pinned.containsKey(item.folder.id)) {
        // Commit whatever the indicator was showing so the drop always
        // matches what the user saw.
        final insertionSide = _pinnedDropSide ??
            resolveDropInsertionSide(
              context: context,
              globalOffset: details.offset,
            );
        if (mounted) {
          setState(() => _pinnedDropSide = null);
        }
        if (insertionSide == null) return;

        await ref.read(pinnedItemsProvider.notifier).movePin(
              id: item.folder.id,
              targetId: id,
              insertAfterTarget: insertionSide == DropInsertionSide.after,
            );
        return;
      }

      if (item is StrategyItem) {
        ref
            .read(strategyProvider.notifier)
            .moveToFolder(strategyID: item.strategy.id, parentID: _folder.id);
      } else if (item is FolderItem) {
        ref
            .read(folderProvider.notifier)
            .moveToFolder(folderID: item.folder.id, parentID: _folder.id);
      }
    }, builder: (context, candidateData, rejectedData) {
      final isPinnedDropTarget = candidateData.any(
        (item) =>
            item is FolderItem &&
            item.folder.id != id &&
            isPinned &&
            pinned.containsKey(item.folder.id),
      );
      final isDropTarget = candidateData.isNotEmpty;
      final isMoveIntoFolderTarget = isDropTarget && !isPinnedDropTarget;
      _syncOpenState(isDropTarget: isMoveIntoFolderTarget);

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: folderCardGutterOutset),
        child: Draggable<GridItem>(
          feedback: TiltDragFeedback(
            controller: _dragTiltController,
            opacity: 0.9,
            child: _buildDragFeedback(),
          ),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          onDragUpdate: (details) =>
              _dragTiltController.addDelta(details.delta.dx),
          data: FolderItem(_folder),
          child: MouseRegion(
            onEnter: (_) {
              _isHovered = true;
              _openController.forward();
            },
            onExit: (_) {
              _isHovered = false;
              if (candidateData.isEmpty) _openController.reverse();
            },
            cursor: SystemMouseCursors.click,
            child: ShadContextMenuRegion(
              controller: _rightClickMenuController,
              items: _buildMenuItems(isPinned: isPinned),
              child: GestureDetector(
                onTap: () {
                  if (widget.isDemo) return;
                  ref.read(folderProvider.notifier).updateID(_folder.id);
                },
                child: AnimatedBuilder(
                  animation: _open,
                  builder: (context, _) {
                    final dropSide = _pinnedDropSide;
                    final slotKey = dropSide == null
                        ? null
                        : dropInsertionSlotKey(
                            itemId: id,
                            side: dropSide,
                            pinnedOrder: pinnedIdsInManualOrder(pinned),
                          );
                    return Transform.scale(
                      scale: isPinnedDropTarget ? 1 : 1 + 0.015 * _open.value,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _buildFolderBody(
                            isMoveIntoFolderTarget: isMoveIntoFolderTarget,
                            isPinned: isPinned,
                          ),
                          if (dropSide != null && slotKey != null)
                            Positioned.fill(
                              child: DropInsertionIndicator(
                                key: ValueKey(slotKey),
                                slotKey: slotKey,
                                side: dropSide,
                                // Matches the Wrap spacing in FolderContent
                                // so the caret sits centered in the gutter.
                                gap: 14,
                                // Aligns with the folder body below the tab.
                                topInset: 14,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  /// The folder opens on hover and when it is an active drop target.
  void _syncOpenState({required bool isDropTarget}) {
    final shouldOpen = _isHovered || isDropTarget;
    if (shouldOpen &&
        _openController.status != AnimationStatus.forward &&
        _openController.status != AnimationStatus.completed) {
      _openController.forward();
    } else if (!shouldOpen &&
        _openController.status != AnimationStatus.reverse &&
        _openController.status != AnimationStatus.dismissed) {
      _openController.reverse();
    }
  }

  Widget _buildFolderBody({
    required bool isMoveIntoFolderTarget,
    required bool isPinned,
  }) {
    final t = _open.value;
    final borderColor = isMoveIntoFolderTarget
        ? Colors.white
        : Colors.white.withValues(alpha: 0.10 + 0.15 * t);

    return SizedBox(
      width: _cardWidth,
      height: _cardHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Back panel with tab: the folder itself.
          Positioned(
            left: 0,
            right: 0,
            top: 14,
            bottom: 0,
            child: CustomPaint(
              painter: _FolderBackPainter(
                color: _backTone,
                borderColor: borderColor,
              ),
            ),
          ),

          // Map photos peeking out of the pocket.
          ..._buildMapPeeks(t),

          // Front panel: name + agent comp.
          Positioned(
            left: 0,
            right: 0,
            top: _pocketTop,
            bottom: 0,
            child: Transform(
              alignment: Alignment.bottomCenter,
              // Squash slightly on open so the pocket appears to gape.
              transform: Matrix4.diagonal3Values(1.0, 1.0 - 0.045 * t, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: _frontTone,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 10,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildNameRow(isPinned),
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _buildFooterRow(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildMapPeeks(double t) {
    final peeks = widget.data.mapPeeks;
    if (peeks.isEmpty) return const [];

    const centerLeft = (_cardWidth - _peekWidth) / 2;

    Widget photo(String asset) {
      return Container(
        width: _peekWidth,
        height: _peekHeight,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.asset(asset, fit: BoxFit.cover),
      );
    }

    if (peeks.length == 1) {
      return [
        Positioned(
          left: centerLeft,
          top: 22 - 14 * t,
          child: Transform.rotate(
            angle: -0.02 - 0.03 * t,
            child: photo(peeks[0]),
          ),
        ),
      ];
    }

    // Depth 0 is the front (most used) sheet. It stays anchored in the
    // pocket; only the sheets behind it rise on hover, so the contents
    // appear to slide up from behind the cover map.
    const tops = [22.0, 15.0, 9.0];
    const lifts = [0.0, 13.0, 17.0];
    const lefts = [-7.0, 7.0, 0.0];
    const restAngles = [-0.022, 0.022, -0.012];
    const openAngles = [0.0, 0.03, -0.022];

    return [
      for (var depth = peeks.length - 1; depth >= 0; depth--)
        Positioned(
          left: centerLeft + lefts[depth],
          top: tops[depth] - lifts[depth] * t,
          child: Transform.rotate(
            angle: restAngles[depth] + openAngles[depth] * t,
            child: photo(peeks[depth]),
          ),
        ),
    ];
  }

  Widget _buildNameRow(bool isPinned) {
    return Row(
      children: [
        FolderIconView(
          iconId: _folder.iconId,
          color: _edgeTone,
          size: 16,
        ),
        const SizedBox(width: 7),
        Expanded(
          child: OverflowTooltipText(
            _folder.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (isPinned) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.push_pin,
            color: Colors.white.withValues(alpha: 0.78),
            size: 13,
          ),
        ],
        _buildMenuButton(isPinned: isPinned),
      ],
    );
  }

  Widget _buildFooterRow() {
    final agents = widget.data.agentTypes;

    return Row(
      children: [
        Expanded(
          child: agents.isEmpty
              ? Text(
                  widget.data.strategyCount == 0
                      ? 'Empty'
                      : '${widget.data.strategyCount} '
                          'strateg${widget.data.strategyCount == 1 ? 'y' : 'ies'}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                )
              : _AgentComposition(agents: agents),
        ),
        if (widget.data.strategyCount > 0 || widget.data.folderCount > 0) ...[
          const SizedBox(width: 6),
          _CountBadge(
            strategyCount: widget.data.strategyCount,
            folderCount: widget.data.folderCount,
          ),
        ],
      ],
    );
  }

  Widget _buildMenuButton({required bool isPinned}) {
    final backgroundAlpha = _isMenuButtonHovered ? 0.16 : 0.04;
    final iconAlpha = _isMenuButtonHovered ? 0.96 : 0.74;

    return ShadContextMenuRegion(
      controller: _contextMenuController,
      items: _buildMenuItems(isPinned: isPinned),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isMenuButtonHovered = true),
        onExit: (_) => setState(() => _isMenuButtonHovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: backgroundAlpha),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Listener(
            onPointerDown: (_) {
              _menuButtonWasOpenOnPointerDown = _contextMenuController.isOpen;
            },
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              mouseCursor: SystemMouseCursors.click,
              hoverColor: Colors.transparent,
              splashColor: Colors.white.withValues(alpha: 0.12),
              highlightColor: Colors.white.withValues(alpha: 0.08),
              onTap: _handleMenuButtonPressed,
              child: Icon(
                Icons.more_vert,
                color: Colors.white.withValues(alpha: iconAlpha),
                size: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<ShadContextMenuItem> _buildMenuItems({required bool isPinned}) {
    final id = _folder.id;
    return [
      ShadContextMenuItem(
        leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined),
        child: Text(isPinned ? 'Unpin' : 'Pin'),
        onPressed: () {
          _closeMenus();
          if (widget.isDemo) return;
          ref.read(pinnedItemsProvider.notifier).togglePin(id);
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(Icons.text_fields),
        child: const Text('Edit'),
        onPressed: () async {
          _closeMenus();
          if (widget.isDemo) return;
          await showDialog<String>(
            context: context,
            builder: (context) {
              return FolderEditDialog(folder: _folder);
            },
          );
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(Icons.file_upload),
        child: const Text('Export'),
        onPressed: () async {
          _closeMenus();
          await ref.read(strategyProvider.notifier).exportFolder(_folder.id);
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(Icons.delete, color: Colors.redAccent),
        child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        onPressed: () async {
          _closeMenus();
          ConfirmAlertDialog.show(
            context: context,
            title: "Are you sure you want to delete '${_folder.name}' folder?",
            content:
                "This will also delete all strategies and subfolders within it.",
            confirmText: "Delete",
            isDestructive: true,
          ).then((confirmed) {
            if (confirmed) {
              if (widget.isDemo) return;
              ref.read(folderProvider.notifier).deleteFolder(_folder.id);
            }
          });
        },
      ),
    ];
  }

  Widget _buildDragFeedback() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _frontTone,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FolderIconView(
            iconId: _folder.iconId,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 10),
          Text(
            _folder.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws the folder back: a rounded rect with a classic tab on the left.
class _FolderBackPainter extends CustomPainter {
  _FolderBackPainter({required this.color, required this.borderColor});

  final Color color;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    const tabWidth = 78.0;
    const tabHeight = 14.0;
    const r = 10.0;

    final path = Path()
      ..moveTo(0, size.height - r)
      ..lineTo(0, tabHeight + r)
      // Up the left edge into the tab.
      ..lineTo(0, r)
      ..quadraticBezierTo(0, 0, r, 0)
      ..lineTo(tabWidth - 12, 0)
      // Tab slope down to the main top edge.
      ..quadraticBezierTo(tabWidth - 4, 0, tabWidth, tabHeight * 0.55)
      ..quadraticBezierTo(tabWidth + 4, tabHeight, tabWidth + 14, tabHeight)
      ..lineTo(size.width - r, tabHeight)
      ..quadraticBezierTo(size.width, tabHeight, size.width, tabHeight + r)
      ..lineTo(size.width, size.height - r)
      ..quadraticBezierTo(size.width, size.height, size.width - r, size.height)
      ..lineTo(r, size.height)
      ..quadraticBezierTo(0, size.height, 0, size.height - r)
      ..close();

    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_FolderBackPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.borderColor != borderColor;
}

/// Agent icons sized to the folder footer, frequency-ordered, with +N
/// overflow when the row runs out of room.
class _AgentComposition extends StatelessWidget {
  const _AgentComposition({required this.agents});

  final List<AgentType> agents;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxSlots = ((constraints.maxWidth + _agentRowSpacing) /
                (_agentIconSize + _agentRowSpacing))
            .floor();
        if (maxSlots <= 0) return const SizedBox.shrink();

        final hasOverflow = agents.length > maxSlots;
        final visibleCount = hasOverflow ? maxSlots - 1 : agents.length;

        return Row(
          spacing: _agentRowSpacing,
          children: [
            ...agents.take(visibleCount).map(
                  (agent) => Container(
                    height: _agentIconSize,
                    width: _agentIconSize,
                    decoration: BoxDecoration(
                      color: Settings.tacticalVioletTheme.card,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: Settings.tacticalVioletTheme.border),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.asset(AgentData.agents[agent]!.iconPath),
                  ),
                ),
            if (hasOverflow)
              Container(
                height: _agentIconSize,
                width: _agentIconSize,
                decoration: BoxDecoration(
                  color: Settings.tacticalVioletTheme.card,
                  borderRadius: BorderRadius.circular(4),
                  border:
                      Border.all(color: Settings.tacticalVioletTheme.border),
                ),
                alignment: Alignment.center,
                child: Text(
                  '+${agents.length - visibleCount}',
                  style: const TextStyle(
                    color: Color.fromARGB(190, 210, 214, 219),
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.strategyCount, required this.folderCount});

  final int strategyCount;
  final int folderCount;

  @override
  Widget build(BuildContext context) {
    final muted = Colors.white.withValues(alpha: 0.55);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (folderCount > 0) ...[
          Icon(Icons.folder_outlined, size: 12, color: muted),
          const SizedBox(width: 2),
          Text(
            '$folderCount',
            style: TextStyle(
                color: muted, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
        if (folderCount > 0 && strategyCount > 0) const SizedBox(width: 6),
        if (strategyCount > 0) ...[
          Icon(Icons.description_outlined, size: 12, color: muted),
          const SizedBox(width: 2),
          Text(
            '$strategyCount',
            style: TextStyle(
                color: muted, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}
