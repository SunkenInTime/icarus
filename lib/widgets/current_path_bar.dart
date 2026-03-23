import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CurrentPathBar extends ConsumerWidget {
  const CurrentPathBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCloud = ref.watch(isCloudCollabEnabledProvider);
    final currentFolderId = ref.watch(folderProvider);
    final cloudFolders = isCloud
        ? (ref.watch(cloudAllFoldersProvider).valueOrNull ?? const [])
            .map(FolderProvider.cloudSummaryToFolder)
            .toList(growable: false)
        : null;
    final currentFolder = currentFolderId == null
        ? null
        : isCloud
            ? cloudFolders
                ?.where((folder) => folder.id == currentFolderId)
                .firstOrNull
            : ref.read(folderProvider.notifier).findFolderByID(currentFolderId);
    final pathFolders = isCloud
        ? _cloudPathFolders(currentFolder, cloudFolders)
        : ref
            .read(folderProvider.notifier)
            .getFullPathIDs(currentFolder)
            .map((id) => ref.read(folderProvider.notifier).findFolderByID(id))
            .whereType<Folder>()
            .toList(growable: false);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: ShadBreadcrumb(
              lastItemTextColor: Settings.tacticalVioletTheme.foreground,
              textStyle: ShadTheme.of(context).textTheme.lead,
              children: [
                FolderTab(
                  folder: null,
                  isActive: currentFolder == null,
                ),
                for (int i = 0; i < pathFolders.length; i++)
                  FolderTab(
                    folder: pathFolders[i],
                    isActive: i == pathFolders.length - 1,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Folder> _cloudPathFolders(Folder? folder, List<Folder>? cloudFolders) {
    final pathFolders = <Folder>[];
    var current = folder;
    while (current != null) {
      pathFolders.insert(0, current);
      final parentId = current.parentID;
      if (parentId == null) {
        current = null;
        continue;
      }
      current = cloudFolders?.where((item) => item.id == parentId).firstOrNull;
    }
    return pathFolders;
  }
}

class FolderTab extends ConsumerWidget {
  const FolderTab({
    super.key,
    required this.folder,
    this.isActive = false,
  });

  final Folder? folder;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayName = folder?.name ?? 'Home';

    return ShadBreadcrumbLink(
      textStyle: ShadTheme.of(context).textTheme.lead,
      normalColor: isActive ? Settings.tacticalVioletTheme.foreground : null,
      child: DragTarget(
        builder: (context, candidateData, rejectedData) {
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(displayName),
          );
        },
        onAcceptWithDetails: (details) {
          final item = details.data;
          if (item is StrategyItem) {
            ref.read(strategyProvider.notifier).moveToFolder(
                  strategyID: item.strategyId,
                  parentID: folder?.id,
                );
          } else if (item is FolderItem) {
            ref.read(folderProvider.notifier).moveToFolder(
                  folderID: item.folder.id,
                  parentID: folder?.id,
                );
          }
        },
      ),
      onPressed: () {
        ref.read(folderProvider.notifier).updateID(folder?.id);
      },
    );
  }
}

extension on Iterable<Folder> {
  Folder? get firstOrNull => isEmpty ? null : first;
}
