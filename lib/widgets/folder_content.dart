import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_tile.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/folder_tile.dart';
// ... your existing imports

class FolderContent extends ConsumerWidget {
  FolderContent({super.key, this.folder});

  final Folder? folder; // null for root
  final strategiesListenable =
      Provider<ValueListenable<Box<StrategyData>>>((ref) {
    return Hive.box<StrategyData>(HiveBoxNames.strategiesBox).listenable();
  });

  final foldersListenable = Provider<ValueListenable<Box<Folder>>>((ref) {
    return Hive.box<Folder>(HiveBoxNames.foldersBox).listenable();
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Move all your existing grid logic here from FolderView
    // Filter by folder?.id instead of folder.id
    final strategiesBoxListenable = ref.watch(strategiesListenable);

    return Stack(
      children: [
        const Positioned.fill(
          child: Padding(
            padding: EdgeInsets.all(4.0),
            child: DotGrid(),
          ),
        ),
        Positioned.fill(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      CustomButton(
                        height: 20,
                        label: "Filter",
                        backgroundColor: Settings.backgroundColor,
                        onPressed: () {},
                        icon: Icon(Icons.settings),
                      ),
                      CustomButton(
                        height: 20,
                        label: "Sort by",
                        backgroundColor: Settings.backgroundColor,
                        onPressed: () {},
                        icon: Icon(Icons.sort),
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: 40,
                    child: SearchTextField(
                      collapsedWidth: 40,
                      expandedWidth: 250,
                      compact: true,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: ValueListenableBuilder<Box<StrategyData>>(
                  valueListenable: strategiesBoxListenable,
                  builder: (context, strategyBox, _) {
                    final foldersBoxListenable = ref.watch(foldersListenable);
                    return ValueListenableBuilder<Box<Folder>>(
                      valueListenable: foldersBoxListenable,
                      builder: (context, folderBox, _) {
                        final folders = folderBox.values.toList();
                        folders.sort(
                            (a, b) => a.dateCreated.compareTo(b.dateCreated));

                        final strategies = strategyBox.values.toList();
                        strategies.sort(
                            (a, b) => b.lastEdited.compareTo(a.lastEdited));

                        // Filter strategies and folders by the current folder
                        strategies.removeWhere(
                            (strategy) => strategy.folderID != folder?.id);
                        folders.removeWhere(
                            (listFolder) => listFolder.parentID != folder?.id);

                        List<GridItem> gridItems = [
                          ...folders.map((folder) => FolderItem(folder)),
                          ...strategies
                              .map((strategy) => StrategyItem(strategy)),
                        ];

                        if (gridItems.isEmpty) {
                          return const IcaDropTarget(
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text('No strategies available'),
                                  Text(
                                      "Create a new strategy or drop an .ica file")
                                ],
                              ),
                            ),
                          );
                        }

                        return IcaDropTarget(
                          child: LayoutBuilder(builder: (context, constraints) {
                            // Calculate how many columns can fit with minimum width
                            const double minTileWidth =
                                250; // Your minimum width
                            const double spacing = 20;
                            const double padding = 32; // 16 * 2

                            int crossAxisCount =
                                ((constraints.maxWidth - padding + spacing) /
                                        (minTileWidth + spacing))
                                    .floor();
                            crossAxisCount = crossAxisCount
                                .clamp(1, double.infinity)
                                .toInt();
                            return GridView.builder(
                              itemCount: gridItems.length,
                              padding: const EdgeInsets.all(16),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                mainAxisExtent: 250,
                                crossAxisSpacing: 20,
                                mainAxisSpacing: 20,
                              ),
                              itemBuilder: (context, index) {
                                final item = gridItems[index];
                                if (item is FolderItem) {
                                  return FolderTile(folder: item.folder);
                                } else if (item is StrategyItem) {
                                  //Error causing line
                                  return StrategyTile(
                                      strategyData: item.strategy);
                                }
                                return const SizedBox.shrink();
                              },
                            );
                          }),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
