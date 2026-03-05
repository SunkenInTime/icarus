import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';

class PagesBar extends ConsumerWidget {
  const PagesBar({super.key});

  Future<void> _addPage(WidgetRef ref) async {
    await ref.read(strategyProvider.notifier).addPage();
  }

  Future<void> _selectPage(WidgetRef ref, String pageId) async {
    await ref.read(strategyProvider.notifier).switchPage(pageId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCloud = ref.watch(isCloudCollabEnabledProvider);
    final activePageId =
        ref.watch(strategyProvider.select((state) => state.activePageId));

    if (isCloud) {
      final snapshot = ref.watch(remoteStrategySnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.pages.isEmpty) {
        return const SizedBox.shrink();
      }

      final pages = [...snapshot.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

      return _SimplePagesBar(
        pageIds: pages.map((p) => p.publicId).toList(growable: false),
        pageNames: pages.map((p) => p.name).toList(growable: false),
        activePageId: activePageId ?? pages.first.publicId,
        onAdd: () => _addPage(ref),
        onSelect: (id) => _selectPage(ref, id),
      );
    }

    final strategyId = ref.watch(strategyProvider).id;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    return ValueListenableBuilder<Box<StrategyData>>(
      valueListenable: box.listenable(keys: [strategyId]),
      builder: (context, strategyBox, _) {
        final strategy = strategyBox.get(strategyId);
        if (strategy == null || strategy.pages.isEmpty) {
          return const SizedBox.shrink();
        }

        final pages = [...strategy.pages]
          ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

        return _SimplePagesBar(
          pageIds: pages.map((p) => p.id).toList(growable: false),
          pageNames: pages.map((p) => p.name).toList(growable: false),
          activePageId: activePageId ?? pages.first.id,
          onAdd: () => _addPage(ref),
          onSelect: (id) => _selectPage(ref, id),
        );
      },
    );
  }
}

class _SimplePagesBar extends StatelessWidget {
  const _SimplePagesBar({
    required this.pageIds,
    required this.pageNames,
    required this.activePageId,
    required this.onAdd,
    required this.onSelect,
  });

  final List<String> pageIds;
  final List<String> pageNames;
  final String activePageId;
  final VoidCallback onAdd;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Settings.tacticalVioletTheme.border,
          width: 2,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            onPressed: onAdd,
            icon: const Icon(Icons.add, color: Colors.white),
            tooltip: 'Add page',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < pageIds.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(pageNames[i]),
                        selected: pageIds[i] == activePageId,
                        onSelected: (_) => onSelect(pageIds[i]),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

