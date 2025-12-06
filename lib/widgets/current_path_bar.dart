import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
        // ignore: prefer_const_constructors
        child: Row(
          children: [
            Expanded(
              child: ShadBreadcrumb(
                lastItemTextColor: Settings.tacticalVioletTheme.foreground,
                textStyle: ShadTheme.of(context).textTheme.lead,
                children: [
                  FolderTab(
                    folder: null, // Represents root
                    isActive: currentFolder == null,
                  ),

                  // Path folders
                  for (int i = 0; i < pathIds.length; i++) ...[
                    FolderTab(
                      folder: ref
                          .read(folderProvider.notifier)
                          .findFolderByID(pathIds[i]),
                      isActive: i == pathIds.length - 1,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ));
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
    final displayName = folder?.name ?? "Home";

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
      onPressed: () {
        ref.read(folderProvider.notifier).updateID(folder?.id);
      },
    );
  }
}
