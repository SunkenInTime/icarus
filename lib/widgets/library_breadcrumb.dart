import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Where the user is inside a folder tree. Shown only inside a folder; at a
/// tab's root the tab itself says where you are.
class LibraryBreadcrumb extends ConsumerWidget {
  const LibraryBreadcrumb({super.key, required this.folder});

  final Folder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(libraryTabProvider);
    final store = ref.watch(libraryWorkspaceProvider);
    final pathFolders = _pathFolders(ref, store);
    final parent =
        pathFolders.length >= 2 ? pathFolders[pathFolders.length - 2] : null;

    void goToRoot() {
      final navigation = ref.read(libraryNavigationProvider);
      if (tab == LibraryTab.shared) {
        navigation.showShared();
      } else {
        navigation.showLibrary();
      }
    }

    return Row(
      children: [
        ShadIconButton.ghost(
          width: 30,
          height: 30,
          foregroundColor: Settings.tacticalVioletTheme.mutedForeground,
          onPressed: () {
            if (parent == null) {
              goToRoot();
            } else {
              ref.read(folderProvider.notifier).updateID(parent.id);
            }
          },
          icon: const Icon(Icons.chevron_left, size: 20),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: ShadBreadcrumb(
            lastItemTextColor: Settings.tacticalVioletTheme.foreground,
            textStyle: ShadTheme.of(context).textTheme.lead,
            children: [
              FolderTab(
                folder: null,
                label: tab == LibraryTab.shared ? 'Shared with Me' : 'My Library',
                store: store,
                onOpen: goToRoot,
              ),
              for (int i = 0; i < pathFolders.length; i++)
                FolderTab(
                  folder: pathFolders[i],
                  store: store,
                  isActive: i == pathFolders.length - 1,
                  onOpen: () => ref
                      .read(folderProvider.notifier)
                      .updateID(pathFolders[i].id),
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Folder> _pathFolders(WidgetRef ref, LibraryWorkspace store) {
    if (store == LibraryWorkspace.cloud) {
      final cloudFolders = (ref.watch(cloudAllFoldersProvider).valueOrNull ??
              const [])
          .map((entry) => entry.folder)
          .toList(growable: false);
      final path = <Folder>[];
      Folder? current = folder;
      while (current != null) {
        path.insert(0, current);
        final parentId = current.parentID;
        current = parentId == null
            ? null
            : cloudFolders.where((item) => item.id == parentId).firstOrNull;
      }
      return path;
    }
    final folders = ref.read(folderProvider.notifier);
    return folders
        .getFullPathIDs(folder)
        .map(folders.findLocalFolderByID)
        .whereType<Folder>()
        .toList(growable: false);
  }
}

/// One crumb. Also a drop target: dragging a strategy or folder onto it moves
/// the item there, within the same store.
class FolderTab extends ConsumerWidget {
  const FolderTab({
    super.key,
    required this.folder,
    required this.store,
    required this.onOpen,
    this.label,
    this.isActive = false,
  });

  /// Null for the root crumb.
  final Folder? folder;
  final LibraryWorkspace store;
  final VoidCallback onOpen;
  final String? label;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadBreadcrumbLink(
      textStyle: ShadTheme.of(context).textTheme.lead,
      normalColor: isActive ? Settings.tacticalVioletTheme.foreground : null,
      onPressed: onOpen,
      child: DragTarget<GridItem>(
        onWillAcceptWithDetails: (details) => details.data.store == store,
        onAcceptWithDetails: (details) {
          final item = details.data;
          if (item is StrategyItem) {
            ref.read(strategyProvider.notifier).moveToFolder(
                  strategyID: item.strategyId,
                  parentID: folder?.id,
                  source: item.strategy == null
                      ? StrategySource.cloud
                      : StrategySource.local,
                );
          } else if (item is FolderItem) {
            ref.read(folderProvider.notifier).moveToFolder(
                  folderID: item.folder.id,
                  parentID: folder?.id,
                  workspace: store,
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
