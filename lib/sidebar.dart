import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/widgets/selectable_icon_button.dart';
import 'package:icarus/widgets/sidebar_widgets/agent_dragable.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/widgets/sidebar_widgets/ability_bar.dart';
import 'package:icarus/widgets/sidebar_widgets/agent_filter.dart';
import 'package:icarus/widgets/sidebar_widgets/role_picker.dart';
import 'package:icarus/widgets/sidebar_widgets/team_picker.dart';
import 'package:icarus/widgets/sidebar_widgets/tool_grid.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SideBarUI extends ConsumerStatefulWidget {
  const SideBarUI({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SideBarUIState();
}

class _SideBarUIState extends ConsumerState<SideBarUI> {
  static const BorderRadius _panelBorderRadius = BorderRadius.all(
    Radius.circular(12),
  );

  ScrollController gridScrollController = ScrollController();

  @override
  void dispose() {
    gridScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filterState = ref.watch(agentFilterProvider);
    final agentList = filterState.agentList;
    return Row(
      // mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        const AbiilityBar(),
        Padding(
          padding: const EdgeInsets.only(
            left: 0,
            top: 8,
            right: Settings.sideBarPanelPaddingRight,
            bottom: 8,
          ),
          child: ClipRRect(
            borderRadius: _panelBorderRadius,
            child: Container(
              width: Settings.sideBarPanelWidth,
              decoration: BoxDecoration(
                borderRadius: _panelBorderRadius,
                color: Settings.tacticalVioletTheme.card,
                border: Border.all(
                  color: const Color.fromRGBO(210, 214, 219, 0.1),
                  width: 2,
                ),
              ),
              child: Column(
                children: [
                  const ToolGrid(),
                  const SizedBox(
                    height: 16,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        context.l10n.sidebarAgentsTitle,
                        style: const TextStyle(fontSize: 20),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(
                        left: 16.0, right: 16.0, top: 8, bottom: 10),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              spacing: 8,
                              children: [
                                const AgentFilter(),
                                ShadTooltip(
                                  builder: (context) => Text(
                                    filterState.favoritesOnly
                                        ? context
                                            .l10n.sidebarShowAllAgentsTooltip
                                        : context.l10n
                                            .sidebarShowFavoriteAgentsTooltip,
                                  ),
                                  child: SelectableIconButton(
                                    isSelected: filterState.favoritesOnly,
                                    hoverBackgroundColor:
                                        filterState.favoritesOnly
                                            ? const Color(0xFFFF9800)
                                            : null,
                                    onPressed: () {
                                      ref
                                          .read(agentFilterProvider.notifier)
                                          .toggleFavoritesOnly();
                                    },
                                    icon: Icon(
                                      LucideIcons.star,
                                      size: 20,
                                      color: filterState.favoritesOnly
                                          ? Colors.white
                                          : Settings.tacticalVioletTheme
                                              .mutedForeground,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 8),
                            const TeamPicker(),
                          ],
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            switchInCurve: Settings.easeOut,
                            switchOutCurve: Settings.easeOut.flipped,
                            child: filterState.favoritesOnly
                                ? Padding(
                                    key: const ValueKey(
                                        "favorites-only-indicator"),
                                    padding:
                                        const EdgeInsets.only(top: 6, left: 2),
                                    child: Row(
                                      spacing: 6,
                                      children: [
                                        const Icon(
                                          LucideIcons.star,
                                          size: 12,
                                          color: Color(0xFFFF9800),
                                        ),
                                        Text(
                                          context.l10n
                                              .sidebarFavoritesOnlyIndicator,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFFFF9800),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : const SizedBox.shrink(
                                    key: ValueKey(
                                        "favorites-only-indicator-empty"),
                                  ),
                          ),
                        ),
                        const RolePicker()
                      ],
                    ),
                  ),
                  Expanded(
                    child: agentList.isEmpty
                        ? Center(
                            child: Text(
                              context.l10n.sidebarNoAgentAvailable,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w500),
                            ),
                          )
                        : RawScrollbar(
                            trackVisibility: true,
                            thumbVisibility: true,
                            thumbColor: const Color(0xFF353435),
                            scrollbarOrientation: ScrollbarOrientation.left,
                            thickness: 5,
                            radius: const Radius.circular(10),
                            controller: gridScrollController,
                            crossAxisMargin: 3,
                            mainAxisMargin: 5,
                            child: Align(
                              alignment: Alignment.topRight,
                              child: SizedBox(
                                width: Settings.sideBarContentWidth,
                                child: ScrollConfiguration(
                                  behavior: ScrollConfiguration.of(context)
                                      .copyWith(scrollbars: false),
                                  child: GridView.builder(
                                    scrollDirection: Axis.vertical,
                                    padding: const EdgeInsets.only(
                                        bottom: 10, right: 10),
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 4,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                    ),
                                    controller: gridScrollController,
                                    physics: const BouncingScrollPhysics(),
                                    itemCount: agentList.length,
                                    itemBuilder: (context, index) {
                                      final agent =
                                          AgentData.agents[agentList[index]]!;
                                      return AgentDragable(
                                        agent: agent,
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                  )
                ],
              ),
            ),
          ),
        )
      ],
    );
  }
}
