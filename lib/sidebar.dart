import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
              left: 0, right: Settings.sideBarPanelPaddingRight, bottom: 8),
          child: Container(
            width: Settings.sideBarPanelWidth,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
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
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      "Agents",
                      style: TextStyle(fontSize: 20),
                    ),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.only(left: 16.0, right: 16.0, top: 8),
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
                                      ? "Show all agents"
                                      : "Show only favorite agents",
                                ),
                                child: SelectableIconButton(
                                  isSelected: filterState.favoritesOnly,
                                  hoverBackgroundColor:
                                      filterState.favoritesOnly
                                          ? Settings.favoriteOnColor
                                          : null,
                                  onPressed: () {
                                    ref
                                        .read(agentFilterProvider.notifier)
                                        .toggleFavoritesOnly();
                                  },
                                  icon: Icon(
                                    Icons.star_rounded,
                                    size: 24,
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
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: filterState.favoritesOnly
                              ? Padding(
                                  key: ValueKey("favorites-only-indicator"),
                                  padding: EdgeInsets.only(top: 6, left: 2),
                                  child: Row(
                                    spacing: 6,
                                    children: [
                                      Icon(
                                        LucideIcons.star,
                                        size: 12,
                                        color: Settings.favoriteOnColor,
                                      ),
                                      Text(
                                        "Filtering: Favorites only",
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Settings.favoriteOnColor,
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
                      ? const Center(
                          child: Text(
                            "No agent available",
                            style: TextStyle(fontWeight: FontWeight.w500),
                          ),
                        )
                      : RawScrollbar(
                          trackVisibility: true,
                          thumbVisibility: true,
                          thumbColor: Settings.scrollbarThumbColor,
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
                                  // shrinkWrap: true,
                                  padding:
                                      const EdgeInsets.only(top: 10, right: 10),
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 4,
                                    // mainAxisExtent: 100,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                  ),
                                  controller: gridScrollController,
                                  // padding: const EdgeInsets.only(right: 8),
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
        )
      ],
    );
  }
}

