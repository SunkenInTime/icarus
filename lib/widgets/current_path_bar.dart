import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/library_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CurrentPathBar extends ConsumerWidget {
  const CurrentPathBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCloud = ref.watch(isCloudCollabEnabledProvider);
    final currentFolderId = ref.watch(folderProvider);

    final pathItems = <LibraryPathItemData>[
      const LibraryPathItemData(id: null, name: 'Home'),
    ];

    if (isCloud) {
      final cloudPath =
          ref.watch(cloudFolderPathProvider).valueOrNull ?? const [];
      pathItems.addAll(
        cloudPath.map(
          (folder) => LibraryPathItemData(
            id: folder.publicId,
            name: folder.name,
          ),
        ),
      );
    } else {
      final currentFolder = currentFolderId != null
          ? ref.read(folderProvider.notifier).findFolderByID(currentFolderId)
          : null;
      final pathIds =
          ref.read(folderProvider.notifier).getFullPathIDs(currentFolder);

      for (final pathId in pathIds) {
        final folder = ref.read(folderProvider.notifier).findFolderByID(pathId);
        if (folder == null) {
          continue;
        }
        pathItems.add(
          LibraryPathItemData(
            id: folder.id,
            name: folder.name,
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: ShadBreadcrumb(
              lastItemTextColor: Settings.tacticalVioletTheme.foreground,
              textStyle: ShadTheme.of(context).textTheme.lead,
              children: [
                for (var i = 0; i < pathItems.length; i++)
                  FolderTab(
                    item: pathItems[i],
                    isActive: i == pathItems.length - 1,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class FolderTab extends ConsumerWidget {
  const FolderTab({
    super.key,
    required this.item,
    this.isActive = false,
  });

  final LibraryPathItemData item;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadBreadcrumbLink(
      textStyle: ShadTheme.of(context).textTheme.lead,
      normalColor: isActive ? Settings.tacticalVioletTheme.foreground : null,
      child: DragTarget<LibraryDragItem>(
        builder: (context, candidateData, rejectedData) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(item.name),
          );
        },
        onAcceptWithDetails: (details) {
          final dragItem = details.data;
          if (dragItem is StrategyDragItem) {
            ref.read(strategyProvider.notifier).moveToFolder(
                  strategyID: dragItem.id,
                  parentID: item.id,
                );
          } else if (dragItem is FolderDragItem) {
            ref.read(folderProvider.notifier).moveToFolder(
                  folderID: dragItem.id,
                  parentID: item.id,
                );
          }
        },
      ),
      onPressed: () {
        ref.read(folderProvider.notifier).updateID(item.id);
      },
    );
  }
}
