import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Where the user is inside a folder tree. Shown only inside a folder; at the
/// library's root the tab itself says where you are.
class LibraryBreadcrumb extends ConsumerWidget {
  const LibraryBreadcrumb({super.key, required this.folder});

  final Folder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.read(folderProvider.notifier);
    final pathFolders = folders
        .getFullPathIDs(folder)
        .map(folders.findFolderByID)
        .whereType<Folder>()
        .toList(growable: false);
    final parent =
        pathFolders.length >= 2 ? pathFolders[pathFolders.length - 2] : null;

    void goToRoot() => ref.read(folderProvider.notifier).updateID(null);

    // Same card as the editor toolbar, so the path reads as hardware on the
    // bench instead of text floating on the dot grid.
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const ValueKey('library-breadcrumb'),
        height: 36,
        padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Settings.tacticalVioletTheme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShadIconButton.ghost(
              width: 28,
              height: 28,
              foregroundColor: Settings.tacticalVioletTheme.mutedForeground,
              hoverForegroundColor: Settings.tacticalVioletTheme.foreground,
              onPressed: () {
                if (parent == null) {
                  goToRoot();
                } else {
                  ref.read(folderProvider.notifier).updateID(parent.id);
                }
              },
              icon: const Icon(LucideIcons.chevronLeft300, size: 18),
            ),
            const SizedBox(width: 4),
            ShadBreadcrumb(
              lastItemTextColor: Settings.tacticalVioletTheme.foreground,
              textStyle: ShadTheme.of(context).textTheme.small,
              children: [
                FolderTab(
                  folder: null,
                  label: 'My Library',
                  onOpen: goToRoot,
                ),
                for (int i = 0; i < pathFolders.length; i++)
                  FolderTab(
                    folder: pathFolders[i],
                    isActive: i == pathFolders.length - 1,
                    onOpen: () => ref
                        .read(folderProvider.notifier)
                        .updateID(pathFolders[i].id),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One crumb. Also a drop target: dragging a strategy or folder onto it moves
/// the item there.
class FolderTab extends ConsumerWidget {
  const FolderTab({
    super.key,
    required this.folder,
    required this.onOpen,
    this.label,
    this.isActive = false,
  });

  /// Null for the root crumb.
  final Folder? folder;
  final VoidCallback onOpen;
  final String? label;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadBreadcrumbLink(
      textStyle: ShadTheme.of(context).textTheme.small,
      normalColor: isActive ? Settings.tacticalVioletTheme.foreground : null,
      onPressed: onOpen,
      child: DragTarget<GridItem>(
        onAcceptWithDetails: (details) {
          final item = details.data;
          if (item is StrategyItem) {
            ref.read(strategyProvider.notifier).moveToFolder(
                  strategyID: item.strategy.id,
                  parentID: folder?.id,
                );
          } else if (item is FolderItem) {
            ref.read(folderProvider.notifier).moveToFolder(
                  folderID: item.folder.id,
                  parentID: folder?.id,
                );
          }
        },
        builder: (context, candidateData, rejectedData) {
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(label ?? folder?.name ?? 'My Library'),
          );
        },
      ),
    );
  }
}
