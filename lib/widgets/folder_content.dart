import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/folder_pill.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
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

  final TextEditingController searchController = TextEditingController();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Move all your existing grid logic here from FolderView
    // Filter by folder?.id instead of folder.id
    final strategiesBoxListenable = ref.watch(strategiesListenable);
    final isCloud = ref.watch(isCloudCollabEnabledProvider);

    if (isCloud) {
      final foldersAsync = ref.watch(cloudFoldersProvider);
      final strategiesAsync = ref.watch(cloudStrategiesProvider);
      final search =
          ref.watch(strategySearchQueryProvider).trim().toLowerCase();
      final filter = ref.watch(strategyFilterProvider);

      final folders = foldersAsync.valueOrNull ?? const [];
      var strategies = strategiesAsync.valueOrNull ?? const [];

      if (search.isNotEmpty) {
        strategies = strategies
            .where((strategy) => strategy.name.toLowerCase().contains(search))
            .toList(growable: false);
      }

      Comparator<CloudStrategySummary> sortByComparator =
          switch (filter.sortBy) {
        SortBy.alphabetical =>
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        SortBy.dateCreated => (a, b) => a.createdAt.compareTo(b.createdAt),
        SortBy.dateUpdated => (a, b) => a.updatedAt.compareTo(b.updatedAt),
      };
      final direction =
          filter.sortOrder == SortOrder.ascending ? 1 : -1;
      strategies = [...strategies]..sort((a, b) => direction * sortByComparator(a, b));

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
                Padding(
                  padding: const EdgeInsets.only(top: 4.0, left: 16, right: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        spacing: 8,
                        children: [
                          ShadSelect<SortBy>(
                            decoration: ShadDecoration(
                              color: Settings.tacticalVioletTheme.card,
                              shadows: const [Settings.cardForegroundBackdrop],
                            ),
                            initialValue: ref.watch(strategyFilterProvider).sortBy,
                            selectedOptionBuilder: (context, value) =>
                                Text(StrategyFilterProvider.sortByLabels[value]!),
                            options: [
                              for (final sb in SortBy.values)
                                ShadOption(
                                  value: sb,
                                  child: Text(StrategyFilterProvider.sortByLabels[sb]!),
                                ),
                            ],
                            onChanged: (value) {
                              ref.read(strategyFilterProvider.notifier).setSortBy(value!);
                            },
                          ),
                          ShadSelect<SortOrder>(
                            decoration: ShadDecoration(
                              color: Settings.tacticalVioletTheme.card,
                              shadows: const [Settings.cardForegroundBackdrop],
                            ),
                            initialValue: ref.watch(strategyFilterProvider).sortOrder,
                            selectedOptionBuilder: (context, value) =>
                                Text(StrategyFilterProvider.sortOrderLabels[value]!),
                            options: [
                              for (final so in SortOrder.values)
                                ShadOption(
                                  value: so,
                                  child: Text(StrategyFilterProvider.sortOrderLabels[so]!),
                                ),
                            ],
                            onChanged: (value) {
                              ref
                                  .read(strategyFilterProvider.notifier)
                                  .setSortOrder(value!);
                            },
                          ),
                        ],
                      ),
                      SizedBox(
                        height: 40,
                        child: SearchTextField(
                          controller: searchController,
                          collapsedWidth: 40,
                          expandedWidth: 250,
                          compact: true,
                          onChanged: (value) {},
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: IcaDropTarget(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (folders.isNotEmpty)
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (final cloudFolder in folders)
                                ActionChip(
                                  label: Text(cloudFolder.name),
                                  onPressed: () {
                                    ref
                                        .read(folderProvider.notifier)
                                        .updateID(cloudFolder.publicId);
                                  },
                                ),
                            ],
                          ),
                        if (folders.isNotEmpty) const SizedBox(height: 16),
                        if (strategies.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 24),
                            child: Center(
                              child: Text('No cloud strategies in this folder'),
                            ),
                          ),
                        for (final strategy in strategies)
                          Card(
                            color: Settings.tacticalVioletTheme.card,
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              title: Text(strategy.name),
                              subtitle: Text(
                                '${strategy.mapData} - Updated ${strategy.updatedAt.toLocal()}',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () async {
                                await ref
                                    .read(strategyProvider.notifier)
                                    .openStrategy(strategy.publicId);
                                if (!context.mounted) return;
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const StrategyView(),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

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
              Padding(
                padding: const EdgeInsets.only(top: 4.0, left: 16, right: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      spacing: 8,
                      children: [
                        ShadSelect<SortBy>(
                          decoration: ShadDecoration(
                            color: Settings.tacticalVioletTheme.card,
                            shadows: const [Settings.cardForegroundBackdrop],
                          ),
                          initialValue:
                              ref.watch(strategyFilterProvider).sortBy,
                          selectedOptionBuilder: (context, value) =>
                              Text(StrategyFilterProvider.sortByLabels[value]!),
                          options: [
                            for (final sb in SortBy.values)
                              ShadOption(
                                value: sb,
                                child: Text(
                                    StrategyFilterProvider.sortByLabels[sb]!),
                              ),
                          ],
                          onChanged: (value) {
                            ref
                                .read(strategyFilterProvider.notifier)
                                .setSortBy(value!);
                          },
                        ),
                        ShadSelect<SortOrder>(
                          decoration: ShadDecoration(
                            color: Settings.tacticalVioletTheme.card,
                            shadows: const [Settings.cardForegroundBackdrop],
                          ),
                          initialValue:
                              ref.watch(strategyFilterProvider).sortOrder,
                          selectedOptionBuilder: (context, value) => Text(
                              StrategyFilterProvider.sortOrderLabels[value]!),
                          options: [
                            for (final so in SortOrder.values)
                              ShadOption(
                                value: so,
                                child: Text(StrategyFilterProvider
                                    .sortOrderLabels[so]!),
                              ),
                          ],
                          onChanged: (value) {
                            ref
                                .read(strategyFilterProvider.notifier)
                                .setSortOrder(value!);
                          },
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 40,
                      child: SearchTextField(
                        controller: searchController,
                        collapsedWidth: 40,
                        expandedWidth: 250,
                        compact: true,
                        onChanged: (value) {},
                      ),
                    ),
                  ],
                ),
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

                        final strategies = strategyBox.values.toList();

                        final search = ref
                            .watch(strategySearchQueryProvider)
                            .trim()
                            .toLowerCase();
                        // Filter strategies and folders by the current folder
                        strategies.removeWhere(
                            (strategy) => strategy.folderID != folder?.id);
                        folders.removeWhere(
                            (listFolder) => listFolder.parentID != folder?.id);

                        if (search.isNotEmpty) {
                          strategies.retainWhere(
                            (strategy) =>
                                strategy.name.toLowerCase().contains(search),
                          );
                          folders.retainWhere(
                            (listFolder) =>
                                listFolder.name.toLowerCase().contains(search),
                          );
                        }
                        final filter = ref.watch(strategyFilterProvider);

                        // Pick the comparator once based on sortBy
                        Comparator<StrategyData> sortByComparator =
                            switch (filter.sortBy) {
                          SortBy.alphabetical => (a, b) => a.name
                              .toLowerCase()
                              .compareTo(b.name.toLowerCase()),
                          SortBy.dateCreated => (a, b) =>
                              a.createdAt.compareTo(b.createdAt),
                          SortBy.dateUpdated => (a, b) =>
                              a.lastEdited.compareTo(b.lastEdited),
                        };

                        final direction =
                            filter.sortOrder == SortOrder.ascending ? 1 : -1;

                        strategies.sort(
                          (a, b) => direction * sortByComparator(a, b),
                        );
                        folders.sort(
                            (a, b) => a.dateCreated.compareTo(b.dateCreated));

                        // Check if both folders and strategies are empty
                        if (folders.isEmpty && strategies.isEmpty) {
                          return const IcaDropTarget(
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text('No strategies available'),
                                  Text(
                                      "Create a new strategy or drop strategies, folders, or .zip archives")
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

                            return CustomScrollView(
                              slivers: [
                                // Folder pills section (wrap row)
                                if (folders.isNotEmpty)
                                  SliverToBoxAdapter(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16, 16, 16, 8),
                                      child: Wrap(
                                        spacing: 10,
                                        runSpacing: 10,
                                        children: folders
                                            .map((f) => FolderPill(folder: f))
                                            .toList(),
                                      ),
                                    ),
                                  ),

                                // Strategies grid
                                if (strategies.isNotEmpty)
                                  SliverPadding(
                                    padding: const EdgeInsets.all(16),
                                    sliver: SliverGrid(
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: crossAxisCount,
                                        mainAxisExtent: 250,
                                        crossAxisSpacing: 20,
                                        mainAxisSpacing: 20,
                                      ),
                                      delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                          return StrategyTile(
                                              strategyData: strategies[index]);
                                        },
                                        childCount: strategies.length,
                                      ),
                                    ),
                                  )
                                else if (folders.isNotEmpty)
                                  // Show placeholder when only folders exist
                                  const SliverFillRemaining(
                                    hasScrollBody: false,
                                    child: Center(
                                      child: Padding(
                                        padding: EdgeInsets.only(top: 48),
                                        child: Text(
                                          'No strategies in this folder',
                                          style: TextStyle(
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
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



