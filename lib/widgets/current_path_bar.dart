import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/folder_navigator.dart';

class CurrentPathBar extends ConsumerWidget {
  const CurrentPathBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFolderId = ref.watch(folderProvider);
    final currentFolder = currentFolderId != null
        ? ref.read(folderProvider.notifier).findFolderByID(currentFolderId)
        : null;

    final pathIds =
        ref.read(folderProvider.notifier).getFullPathIDs(currentFolder);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      child: Row(
        children: [
          // Root folder button
          FolderTab(
            folder: null, // Represents root
            isActive: currentFolderId == null,
          ),
          // Path folders
          for (int i = 0; i < pathIds.length; i++) ...[
            const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
            FolderTab(
              folder:
                  ref.read(folderProvider.notifier).findFolderByID(pathIds[i]),
              isActive: i == pathIds.length - 1,
            ),
          ],
        ],
      ),
    );
  }
}

class FolderTab extends ConsumerWidget {
  const FolderTab({
    super.key,
    required this.folder,
    this.isActive = false,
  });

  final Folder? folder; // null for root
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayName = folder?.name ?? "Strategies";

    return InkWell(
      onTap: isActive
          ? null
          : () {
              // Navigate to this folder
              ref.read(folderProvider.notifier).updateID(folder?.id);
            },
      borderRadius: BorderRadius.circular(16),
      child: DragTarget<GridItem>(
        builder: (context, candidateData, rejectedData) {
          final bool isHovering = candidateData.isNotEmpty;

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color:
                  isHovering ? Colors.deepPurpleAccent.withOpacity(0.2) : null,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color:
                    isHovering ? Colors.deepPurpleAccent : Colors.transparent,
                width: 2,
              ),
            ),
            child: Text(
              displayName,
              style: TextStyle(
                color: isActive || isHovering ? Colors.white : Colors.grey[700],
                fontWeight: isActive ? FontWeight.normal : FontWeight.normal,
                fontSize: 22,
              ),
            ),
          );
        },
        onAcceptWithDetails: (details) {
          final item = details.data;
          if (item is StrategyItem) {
            // Move strategy to this folder
            ref.read(strategyProvider.notifier).moveToFolder(
                strategyID: item.strategy.id, parentID: folder?.id);
          } else if (item is FolderItem) {
            // Move folder to this folder

            ref
                .read(folderProvider.notifier)
                .moveToFolder(folderID: item.folder.id, parentID: folder?.id);
          }
        },
      ),
    );
  }
}
