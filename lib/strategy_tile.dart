import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/dialogs/strategy/delete_strategy_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/rename_strategy_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';

class StrategyTile extends ConsumerStatefulWidget {
  const StrategyTile({super.key, required this.strategyData});

  final StrategyData strategyData;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _StrategyTileState();
}

class _StrategyTileState extends ConsumerState<StrategyTile> {
  Color _highlightColor = Settings.highlightColor;
  bool _isLoading = false;

  String getAttack() {
    bool isAttack = widget.strategyData.pages.first.isAttack;
    bool isMixed = false;
    if (widget.strategyData.pages.any((page) => page.isAttack != isAttack)) {
      isMixed = true;
    }
    if (isMixed) {
      return "Mixed";
    }
    return isAttack ? "Attack" : "Defend";
  }

  Set<AgentType> get _agentsOnMap {
    final Set<AgentType> agents = {};
    for (final agent in widget.strategyData.agentData) {
      agents.add(agent.type);
    }
    return agents;
  }

  Future<void> _navigateToStrategy() async {
    if (_isLoading) {
      log("Is loading");
      return;
    }
    log("Navigating");

    setState(() => _isLoading = true);
    _showLoadingOverlay();

    try {
      await ref
          .read(strategyProvider.notifier)
          .loadFromHive(widget.strategyData.id);
      log("Right after load from hive");
      if (!mounted) return;
      Navigator.pop(context); // Remove loading overlay
      log("About to push");
      await Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (context, animation, _) => const StrategyView(),
          transitionsBuilder: (context, animation, _, child) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.9, end: 1.0)
                    .chain(CurveTween(curve: Curves.easeOut))
                    .animate(animation),
                child: child,
              ),
            );
          },
        ),
      );
    } catch (e) {
      if (mounted) Navigator.pop(context); // Remove loading overlay
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showLoadingOverlay() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Draggable<GridItem>(
      data: StrategyItem(widget.strategyData),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Opacity(
        opacity: 0.95,
        child: Material(
          color: Colors.transparent,
          child: _buildTileContentForFeedback(),
        ),
      ),
      child: _buildTileContent(),
    );
  }

  Widget _buildTileContent() {
    return MouseRegion(
      // Remove Positioned.fill
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _highlightColor = Colors.deepPurpleAccent),
      onExit: (_) => setState(() => _highlightColor = Settings.highlightColor),
      child: AbsorbPointer(
        absorbing: _isLoading,
        child: GestureDetector(
          onTap: _navigateToStrategy,
          child: Stack(
            // Add Stack here for the context menu
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                decoration: BoxDecoration(
                  color: Settings.sideBarColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _highlightColor, width: 2),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      Expanded(child: _buildMapThumbnail()),
                      const SizedBox(height: 10),
                      _buildInfoSection(),
                    ],
                  ),
                ),
              ),
              _buildContextMenu(),
            ],
          ),
        ),
      ),
    );
  }

// Fix the feedback widget to not use Expanded
  Widget _buildTileContentForFeedback() {
    return Container(
      height: 50,
      width: 220,
      decoration: BoxDecoration(
        color: Settings.sideBarColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.deepPurpleAccent, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            SizedBox(width: 80, child: _buildMapThumbnail(8)),
            const SizedBox(width: 20),
            Text(
              widget.strategyData.name,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapThumbnail([double? borderRadius]) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius ?? 16),
      child: SizedBox(
        height: 116,
        width: double.infinity,
        child: Image.asset(
          "assets/maps/thumbnails/${Maps.mapNames[widget.strategyData.mapData]}_thumbnail.webp",
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  Widget _buildInfoSection() {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A161A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Settings.highlightColor),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildLeftInfo()),
            _buildRightInfo(),
          ],
        ),
      ),
    );
  }

  Widget _buildLeftInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 130),
          child: Text(
            widget.strategyData.name,
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(_capitalizeFirstLetter(
            Maps.mapNames[widget.strategyData.mapData]!)),
        const SizedBox(height: 5),
        _buildAgentIcons(),
      ],
    );
  }

  Widget _buildRightInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          getAttack(),
          style: TextStyle(
            color: (getAttack() == "Mixed")
                ? Colors.orangeAccent
                : (getAttack() == "Attack")
                    ? Colors.redAccent
                    : Colors.lightBlueAccent,
          ),
        ),
        const SizedBox(height: 5),
        Text(_timeAgo(widget.strategyData.lastEdited)),
      ],
    );
  }

  Widget _buildAgentIcons() {
    final agents = _agentsOnMap.toList();
    const maxVisible = 3;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 123),
      child: Row(
        spacing: 5,
        children: [
          ...agents.take(maxVisible).map(_buildAgentIcon),
          if (agents.length > maxVisible) _buildMoreAgentsIndicator(),
        ],
      ),
    );
  }

  Widget _buildAgentIcon(AgentType agentType) {
    return Container(
      height: 27,
      width: 27,
      decoration: BoxDecoration(
        color: Settings.sideBarColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Settings.highlightColor),
      ),
      child: Image.asset(AgentData.agents[agentType]!.iconPath),
    );
  }

  Widget _buildMoreAgentsIndicator() {
    return Container(
      height: 27,
      width: 27,
      decoration: BoxDecoration(
        color: Settings.sideBarColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Settings.highlightColor),
      ),
      child: const Icon(
        Icons.more_horiz,
        color: Color.fromARGB(190, 210, 214, 219),
        size: 18,
      ),
    );
  }

  Widget _buildContextMenu() {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: MenuAnchor(
          menuChildren: [
            _buildMenuItem(
              icon: Icons.text_fields,
              label: "Rename",
              onPressed: () => _showRenameDialog(),
            ),
            _buildMenuItem(
              icon: Icons.copy,
              label: "Duplicate",
              onPressed: () async {
                await ref
                    .read(strategyProvider.notifier)
                    .duplicateStrategy(widget.strategyData.id);
              },
            ),
            _buildMenuItem(
              icon: Icons.upload,
              label: "Export",
              onPressed: () => _exportStrategy(),
            ),
            _buildMenuItem(
              icon: Icons.delete,
              label: "Delete",
              color: Colors.redAccent,
              onPressed: () => _showDeleteDialog(),
            ),
          ],
          builder: (context, controller, _) {
            return IconButton(
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(
                Icons.more_vert_outlined,
                shadows: [Shadow(blurRadius: 8)],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return MenuItemButton(
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }

  Future<void> _showRenameDialog() async {
    await showDialog(
      context: context,
      builder: (_) => RenameStrategyDialog(
        strategyId: widget.strategyData.id,
        currentName: widget.strategyData.name,
      ),
    );
  }

  Future<void> _exportStrategy() async {
    await ref
        .read(strategyProvider.notifier)
        .loadFromHive(widget.strategyData.id);
    await ref
        .read(strategyProvider.notifier)
        .exportFile(widget.strategyData.id);
  }

  void _showDeleteDialog() {
    showDialog(
      context: context,
      builder: (_) => DeleteStrategyAlertDialog(
        strategyID: widget.strategyData.id,
        name: widget.strategyData.name,
      ),
    );
  }

  String _capitalizeFirstLetter(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  String _timeAgo(DateTime date) {
    final difference = DateTime.now().difference(date);

    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60)
      return '${difference.inMinutes} min${difference.inMinutes == 1 ? '' : 's'} ago';
    if (difference.inHours < 24)
      return '${difference.inHours} hour${difference.inHours == 1 ? '' : 's'} ago';
    if (difference.inDays < 30)
      return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';

    final months = (difference.inDays / 30).floor();
    return '$months month${months == 1 ? '' : 's'} ago';
  }
}
