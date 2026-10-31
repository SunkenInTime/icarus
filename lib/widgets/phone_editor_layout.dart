import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/cloud_sync_button.dart';
import 'package:icarus/widgets/delete_capture.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:icarus/widgets/pages_bar.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:icarus/widgets/sidebar_widgets/ability_bar.dart';
import 'package:icarus/widgets/sidebar_widgets/agent_dragable.dart';
import 'package:icarus/widgets/sidebar_widgets/agent_filter.dart';
import 'package:icarus/widgets/sidebar_widgets/role_picker.dart';
import 'package:icarus/widgets/sidebar_widgets/team_picker.dart';
import 'package:icarus/widgets/sidebar_widgets/tool_grid.dart';
import 'package:icarus/widgets/strategy_edit_boundary.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _railWidth = 52;
const double _railButton = 38;
const double _panelWidth = 352;
const double _panelCollapsedWidth = 44;

const EditorToolbarButtonStyle _railStyle =
    EditorToolbarButtonStyle(size: _railButton, iconSize: 20);

/// The editor on a phone held sideways. The map is bound by height, so the
/// sides are free: a rail of document actions on the left, the desktop's
/// panel down the right, and every pixel of height for the map.
class PhoneEditorLayout extends ConsumerStatefulWidget {
  const PhoneEditorLayout({
    super.key,
    required this.onLeave,
    required this.showPanel,
    this.toolsInColumn = false,
  });

  final VoidCallback onLeave;

  /// False under the turn-your-phone notice, where there's no room for it.
  final bool showPanel;

  /// Layout F of the design: tools in a column beside the agents, not a row
  /// above them.
  final bool toolsInColumn;

  @override
  ConsumerState<PhoneEditorLayout> createState() => _PhoneEditorLayoutState();
}

class _PhoneEditorLayoutState extends ConsumerState<PhoneEditorLayout> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final panelWidth = !widget.showPanel
        ? 0.0
        : _collapsed
            ? _panelCollapsedWidth
            : _panelWidth;
    return Scaffold(
      body: Row(
        children: [
          _Rail(onLeave: widget.onLeave),
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const Positioned.fill(
                  child: StrategyEditBoundary(child: DeleteCapture()),
                ),
                const Positioned.fill(
                  child: RepaintBoundary(
                    child: InteractiveMap(sideBarWidth: 0),
                  ),
                ),
                const Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.all(6),
                    child: PagesBar(),
                  ),
                ),
                const Align(
                  alignment: Alignment.centerRight,
                  child: StrategyEditBoundary(
                    disabledOpacity: 0.55,
                    child: AbiilityBar(),
                  ),
                ),
              ],
            ),
          ),
          if (widget.showPanel)
            SizedBox(
              width: panelWidth,
              child: StrategyEditBoundary(
                disabledOpacity: 0.55,
                child: _collapsed
                    ? _CollapsedPanel(
                        onExpand: () => setState(() => _collapsed = false),
                      )
                    : _Panel(
                        toolsInColumn: widget.toolsInColumn,
                        onCollapse: () => setState(() => _collapsed = true),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Rail extends ConsumerWidget {
  const _Rail({required this.onLeave});

  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      width: _railWidth,
      decoration: BoxDecoration(
        color: theme.card,
        border: Border(right: BorderSide(color: theme.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 6),
          EditorToolbarButton(
            style: _railStyle,
            tooltip: 'Library',
            onPressed: onLeave,
            icon: const Icon(LucideIcons.house200),
          ),
          const CloudSyncButton(style: _railStyle),
          EditorToolbarButton(
            style: _railStyle,
            tooltip: 'Settings',
            onPressed: () => showShadDialog<void>(
              context: context,
              builder: (context) => const SettingsTab(),
            ),
            icon: const Icon(LucideIcons.settings200),
          ),
          const Spacer(),
          EditorToolbarButton(
            key: const ValueKey('phone-undo'),
            style: _railStyle,
            tooltip: 'Undo',
            onPressed: () => ref.read(actionProvider.notifier).undoAction(),
            icon: const Icon(LucideIcons.undo2200),
          ),
          EditorToolbarButton(
            key: const ValueKey('phone-redo'),
            style: _railStyle,
            tooltip: 'Redo',
            onPressed: () => ref.read(actionProvider.notifier).redoAction(),
            icon: const Icon(LucideIcons.redo2200),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _CollapsedPanel extends StatelessWidget {
  const _CollapsedPanel({required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      decoration: BoxDecoration(
        color: theme.card,
        border: Border(left: BorderSide(color: theme.border)),
      ),
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.only(top: 6),
      child: EditorToolbarButton(
        key: const ValueKey('phone-panel-expand'),
        style: _railStyle,
        tooltip: 'Show agents and tools',
        onPressed: onExpand,
        icon: const Icon(LucideIcons.panelRightOpen200),
      ),
    );
  }
}

class _Panel extends ConsumerStatefulWidget {
  const _Panel({required this.toolsInColumn, required this.onCollapse});

  final bool toolsInColumn;
  final VoidCallback onCollapse;

  @override
  ConsumerState<_Panel> createState() => _PanelState();
}

class _PanelState extends ConsumerState<_Panel> {
  final _gridController = ScrollController();

  @override
  void dispose() {
    _gridController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final filterState = ref.watch(agentFilterProvider);
    final agentList = filterState.agentList;

    final header = Row(
      children: [
        Expanded(child: _StrategyHeader()),
        EditorToolbarButton(
          key: const ValueKey('phone-panel-collapse'),
          style: const EditorToolbarButtonStyle(size: 34, iconSize: 18),
          tooltip: 'Hide agents and tools',
          onPressed: widget.onCollapse,
          icon: const Icon(LucideIcons.panelRightClose200),
        ),
      ],
    );

    final filters = Row(
      children: [
        const AgentFilter(),
        const SizedBox(width: 6),
        const Spacer(),
        const TeamPicker(),
      ],
    );

    final grid = agentList.isEmpty
        ? const Center(child: Text('No agent available'))
        : GridView.builder(
            controller: _gridController,
            padding: const EdgeInsets.only(bottom: 8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: widget.toolsInColumn ? 4 : 5,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: agentList.length,
            itemBuilder: (context, index) =>
                AgentDragable(agent: AgentData.agents[agentList[index]]!),
          );

    final body = widget.toolsInColumn
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                  width: 34, child: ToolGrid(dense: true, columns: 1)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  children: [
                    header,
                    const SizedBox(height: 6),
                    filters,
                    const RolePicker(),
                    const SizedBox(height: 6),
                    Expanded(child: grid),
                  ],
                ),
              ),
            ],
          )
        : Column(
            children: [
              header,
              const SizedBox(height: 6),
              const ToolGrid(dense: true, columns: 9),
              const SizedBox(height: 6),
              filters,
              const RolePicker(),
              const SizedBox(height: 6),
              Expanded(child: grid),
            ],
          );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      decoration: BoxDecoration(
        color: theme.card,
        border: Border(left: BorderSide(color: theme.border)),
      ),
      child: body,
    );
  }
}

class _StrategyHeader extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = Settings.tacticalVioletTheme;
    final name = ref.watch(
      strategyProvider.select((value) => value.strategyName),
    );
    final map = ref.watch(mapProvider);
    final mapName = Maps.mapNames[map.currentMap]!;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.asset(
            'assets/maps/thumbnails/${mapName}_thumbnail.webp',
            width: 34,
            height: 34,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.foreground,
                ),
              ),
              Text(
                '${mapName[0].toUpperCase()}${mapName.substring(1)} · '
                '${map.isAttack ? 'Attack' : 'Defense'}',
                maxLines: 1,
                style: TextStyle(fontSize: 11, color: theme.mutedForeground),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
