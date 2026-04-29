import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class FolderNavigatorSidebar extends ConsumerWidget {
  const FolderNavigatorSidebar({
    super.key,
    required this.onCreateStrategy,
    required this.onAddFolder,
    required this.onImportIca,
    required this.onImportBackup,
    required this.onExportLibrary,
  });

  final VoidCallback onCreateStrategy;
  final Future<void> Function() onAddFolder;
  final Future<void> Function() onImportIca;
  final Future<void> Function() onImportBackup;
  final Future<void> Function() onExportLibrary;

  static final foldersListenable =
      Provider<ValueListenable<Box<Folder>>>((ref) {
    return Hive.box<Folder>(HiveBoxNames.foldersBox).listenable();
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(libraryWorkspaceProvider);
    final isCloud = workspace == LibraryWorkspace.cloud;

    if (isCloud) {
      final cloudFolders =
          (ref.watch(cloudAllFoldersProvider).valueOrNull ?? const [])
              .map(FolderProvider.cloudSummaryToFolder)
              .toList(growable: false);
      return _SidebarShell(
        folders: cloudFolders,
        isCloud: true,
        onCreateStrategy: onCreateStrategy,
        onAddFolder: onAddFolder,
        onImportIca: onImportIca,
        onImportBackup: onImportBackup,
        onExportLibrary: onExportLibrary,
      );
    }

    final localFoldersListenable = ref.watch(
      FolderNavigatorSidebar.foldersListenable,
    );
    return ValueListenableBuilder<Box<Folder>>(
      valueListenable: localFoldersListenable,
      builder: (context, folderBox, _) {
        return _SidebarShell(
          folders: folderBox.values.toList(growable: false),
          isCloud: false,
          onCreateStrategy: onCreateStrategy,
          onAddFolder: onAddFolder,
          onImportIca: onImportIca,
          onImportBackup: onImportBackup,
          onExportLibrary: onExportLibrary,
        );
      },
    );
  }
}

class _SidebarShell extends ConsumerWidget {
  const _SidebarShell({
    required this.folders,
    required this.isCloud,
    required this.onCreateStrategy,
    required this.onAddFolder,
    required this.onImportIca,
    required this.onImportBackup,
    required this.onExportLibrary,
  });

  final List<Folder> folders;
  final bool isCloud;
  final VoidCallback onCreateStrategy;
  final Future<void> Function() onAddFolder;
  final Future<void> Function() onImportIca;
  final Future<void> Function() onImportBackup;
  final Future<void> Function() onExportLibrary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFolderId = ref.watch(folderProvider);
    final cloudSection = ref.watch(cloudLibrarySectionProvider);
    final canMutateCloudLibrary =
        !isCloud || cloudSection == CloudLibrarySection.home;
    final filterState = ref.watch(strategyFilterProvider);
    final searchQuery =
        ref.watch(strategySearchQueryProvider).trim().toLowerCase();
    final visibleRoots = _buildVisibleTree(folders, searchQuery);

    return Container(
      width: 288,
      margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ShadButton(
                  onPressed: canMutateCloudLibrary ? onCreateStrategy : null,
                  leading: const Icon(Icons.add),
                  child: Text(
                    isCloud ? 'Create Cloud Strategy' : 'Create Strategy',
                  ),
                ),
                const SizedBox(height: 8),
                ShadButton.secondary(
                  onPressed: canMutateCloudLibrary ? onAddFolder : null,
                  leading: const Icon(LucideIcons.folderPlus),
                  child: const Text('Add Folder'),
                ),
                if (isCloud) ...[
                  const SizedBox(height: 8),
                  ShadButton.secondary(
                    onPressed: () async {
                      await showShadDialog<void>(
                        context: context,
                        builder: (_) => const JoinShareLinkDialog(),
                      );
                    },
                    leading: const Icon(LucideIcons.link),
                    child: const Text('Join Share Link'),
                  ),
                ],
                const SizedBox(height: 12),
                const SizedBox(
                  height: 40,
                  child: SearchTextField(
                    collapsedWidth: double.infinity,
                    expandedWidth: double.infinity,
                    compact: true,
                    hintText: 'Search strategies and folders',
                  ),
                ),
                const SizedBox(height: 12),
                _SidebarSelect<SortBy>(
                  currentValue: filterState.sortBy,
                  values: SortBy.values,
                  labels: StrategyFilterProvider.sortByLabels,
                  onChanged: (value) {
                    ref.read(strategyFilterProvider.notifier).setSortBy(value);
                  },
                ),
                const SizedBox(height: 8),
                _SidebarSelect<SortOrder>(
                  currentValue: filterState.sortOrder,
                  values: SortOrder.values,
                  labels: StrategyFilterProvider.sortOrderLabels,
                  onChanged: (value) {
                    ref
                        .read(strategyFilterProvider.notifier)
                        .setSortOrder(value);
                  },
                ),
                const SizedBox(height: 12),
                _SidebarSectionLabel(
                  label: isCloud ? 'Cloud Tools' : 'Library Tools',
                ),
                const SizedBox(height: 8),
                _SidebarActionButton(
                  icon: Icons.file_download_outlined,
                  label: 'Import .ica',
                  onPressed: isCloud ? null : onImportIca,
                ),
                const SizedBox(height: 6),
                _SidebarActionButton(
                  icon: Icons.archive_outlined,
                  label: 'Import Backup',
                  onPressed: isCloud ? null : onImportBackup,
                ),
                const SizedBox(height: 6),
                _SidebarActionButton(
                  icon: Icons.backup_outlined,
                  label: 'Export Library',
                  onPressed: isCloud ? null : onExportLibrary,
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: Settings.tacticalVioletTheme.border,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isCloud) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: _SidebarSectionLabel(label: 'Views'),
                    ),
                    const SizedBox(height: 8),
                    _SidebarSpecialItem(
                      icon: Icons.home_outlined,
                      label: 'Home',
                      isSelected: cloudSection == CloudLibrarySection.home &&
                          currentFolderId == null,
                      onTap: () {
                        ref
                            .read(cloudLibrarySectionProvider.notifier)
                            .select(CloudLibrarySection.home);
                        ref.read(folderProvider.notifier).updateID(null);
                      },
                    ),
                    const SizedBox(height: 4),
                    _SidebarSpecialItem(
                      icon: Icons.people_outline,
                      label: 'Shared with Me',
                      isSelected:
                          cloudSection == CloudLibrarySection.sharedWithMe,
                      onTap: () {
                        ref
                            .read(cloudLibrarySectionProvider.notifier)
                            .select(CloudLibrarySection.sharedWithMe);
                        ref.read(folderProvider.notifier).updateID(null);
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: _SidebarSectionLabel(label: 'Folders'),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        _SidebarRootItem(
                          isSelected: currentFolderId == null &&
                              (!isCloud ||
                                  cloudSection == CloudLibrarySection.home),
                        ),
                        const SizedBox(height: 4),
                        if (visibleRoots.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 12,
                            ),
                            child: Text(
                              searchQuery.isEmpty
                                  ? 'No folders yet'
                                  : 'No folders match your search',
                              style: TextStyle(
                                color: Settings
                                    .tacticalVioletTheme.mutedForeground,
                                fontSize: 13,
                              ),
                            ),
                          )
                        else
                          ...visibleRoots.map(
                            (node) => _FolderSidebarItem(
                              node: node,
                              depth: 0,
                              selectedFolderId: currentFolderId,
                              folderLookup: {
                                for (final folder in folders) folder.id: folder,
                              },
                            ),
                          ),
                      ],
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

class _SidebarRootItem extends ConsumerWidget {
  const _SidebarRootItem({required this.isSelected});

  final bool isSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DragTarget<GridItem>(
      onAcceptWithDetails: (details) {
        final item = details.data;
        if (item is StrategyItem) {
          ref.read(strategyProvider.notifier).moveToFolder(
                strategyID: item.strategyId,
                parentID: null,
                source: item.strategy == null
                    ? StrategySource.cloud
                    : StrategySource.local,
              );
        } else if (item is FolderItem) {
          ref.read(folderProvider.notifier).moveToFolder(
                folderID: item.folder.id,
                parentID: null,
                workspace: ref.read(libraryWorkspaceProvider),
              );
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isDropTarget = candidateData.isNotEmpty;
        return _SidebarRowShell(
          selected: isSelected,
          isDropTarget: isDropTarget,
          onTap: () {
            if (ref.read(libraryWorkspaceProvider) == LibraryWorkspace.cloud) {
              ref
                  .read(cloudLibrarySectionProvider.notifier)
                  .select(CloudLibrarySection.home);
            }
            ref.read(folderProvider.notifier).updateID(null);
          },
          child: const Row(
            children: [
              Icon(Icons.home_outlined, size: 18),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Home',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SidebarSpecialItem extends StatelessWidget {
  const _SidebarSpecialItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _SidebarRowShell(
      selected: isSelected,
      isDropTarget: false,
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderSidebarItem extends ConsumerStatefulWidget {
  const _FolderSidebarItem({
    required this.node,
    required this.depth,
    required this.selectedFolderId,
    required this.folderLookup,
  });

  final _FolderTreeNode node;
  final int depth;
  final String? selectedFolderId;
  final Map<String, Folder> folderLookup;

  @override
  ConsumerState<_FolderSidebarItem> createState() => _FolderSidebarItemState();
}

class _FolderSidebarItemState extends ConsumerState<_FolderSidebarItem> {
  static const _hoverExitDelay = Duration(milliseconds: 500);

  final ShadContextMenuController _menuButtonController =
      ShadContextMenuController();
  final ShadContextMenuController _rightClickMenuController =
      ShadContextMenuController();
  bool _hovered = false;
  Timer? _hoverExitTimer;

  Folder get folder => widget.node.folder;

  @override
  void dispose() {
    _hoverExitTimer?.cancel();
    _menuButtonController.dispose();
    _rightClickMenuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = folder.customColor ??
        Folder.folderColorMap[folder.color] ??
        Colors.white;
    final selected = widget.selectedFolderId == folder.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DragTarget<GridItem>(
          onWillAcceptWithDetails: (details) {
            final item = details.data;
            if (item is FolderItem) {
              return item.folder.id != folder.id &&
                  !_isAncestor(
                      targetFolder: folder, draggedFolderId: item.folder.id);
            }
            return true;
          },
          onAcceptWithDetails: (details) {
            final item = details.data;
            if (item is StrategyItem) {
              ref.read(strategyProvider.notifier).moveToFolder(
                    strategyID: item.strategyId,
                    parentID: folder.id,
                    source: item.strategy == null
                        ? StrategySource.cloud
                        : StrategySource.local,
                  );
            } else if (item is FolderItem) {
              ref.read(folderProvider.notifier).moveToFolder(
                    folderID: item.folder.id,
                    parentID: folder.id,
                    workspace: ref.read(libraryWorkspaceProvider),
                  );
            }
          },
          builder: (context, candidateData, rejectedData) {
            return Padding(
              padding: EdgeInsets.only(left: widget.depth * 16.0),
              child: MouseRegion(
                onEnter: (_) {
                  _hoverExitTimer?.cancel();
                  setState(() => _hovered = true);
                },
                onExit: (_) {
                  _hoverExitTimer?.cancel();
                  _hoverExitTimer = Timer(_hoverExitDelay, () {
                    if (!mounted) {
                      return;
                    }
                    setState(() => _hovered = false);
                  });
                },
                child: ShadContextMenuRegion(
                  controller: _rightClickMenuController,
                  items: _buildMenuItems(),
                  child: Draggable<GridItem>(
                    data: FolderItem(folder),
                    feedback: _FolderDragPreview(folder: folder),
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    child: _SidebarRowShell(
                      selected: selected,
                      isDropTarget: candidateData.isNotEmpty,
                      onTap: () {
                        if (ref.read(libraryWorkspaceProvider) ==
                            LibraryWorkspace.cloud) {
                          ref
                              .read(cloudLibrarySectionProvider.notifier)
                              .select(CloudLibrarySection.home);
                        }
                        ref.read(folderProvider.notifier).updateID(folder.id);
                      },
                      child: Row(
                        children: [
                          Icon(folder.icon, size: 18, color: color),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              folder.name,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w500),
                            ),
                          ),
                          if (_hovered || selected)
                            ShadContextMenuRegion(
                              controller: _menuButtonController,
                              items: _buildMenuItems(),
                              child: ShadIconButton.ghost(
                                width: 26,
                                height: 26,
                                onPressed: _menuButtonController.toggle,
                                icon: const Icon(Icons.more_horiz, size: 16),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (widget.node.children.isNotEmpty)
          ...widget.node.children.map(
            (child) => _FolderSidebarItem(
              node: child,
              depth: widget.depth + 1,
              selectedFolderId: widget.selectedFolderId,
              folderLookup: widget.folderLookup,
            ),
          ),
      ],
    );
  }

  List<ShadContextMenuItem> _buildMenuItems() {
    final isCloud =
        ref.read(libraryWorkspaceProvider) == LibraryWorkspace.cloud;
    final allFolders =
        ref.read(cloudAllFoldersProvider).valueOrNull ?? const [];
    final cloudRole = allFolders
        .where((item) => item.publicId == folder.id)
        .map((item) => item.role)
        .firstOrNull;
    final canManage = !isCloud || cloudRole == 'owner';

    return [
      ShadContextMenuItem(
        leading: const Icon(Icons.text_fields),
        child: const Text('Edit'),
        onPressed: !canManage
            ? null
            : () async {
                await showDialog<String>(
                  context: context,
                  builder: (context) => FolderEditDialog(folder: folder),
                );
              },
      ),
      if (isCloud && cloudRole == 'owner')
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.link2),
          child: const Text('Share'),
          onPressed: () async {
            await showShadDialog<void>(
              context: context,
              builder: (_) => ShareLinksDialog(
                targetType: 'folder',
                targetPublicId: folder.id,
                title: folder.name,
              ),
            );
          },
        ),
      ShadContextMenuItem(
        leading: const Icon(Icons.file_upload_outlined),
        child: const Text('Export'),
        onPressed: () async {
          await StrategyImportExportService(ref).exportFolder(folder.id);
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
        child: const Text(
          'Delete',
          style: TextStyle(color: Colors.redAccent),
        ),
        onPressed: !canManage
            ? null
            : () async {
                final confirmed = await ConfirmAlertDialog.show(
                  context: context,
                  title: "Delete '${folder.name}'?",
                  content:
                      'This also removes every strategy and subfolder inside it.',
                  confirmText: 'Delete',
                  isDestructive: true,
                );
                if (!confirmed) {
                  return;
                }
                ref.read(folderProvider.notifier).deleteFolder(
                      folder.id,
                      workspace: ref.read(libraryWorkspaceProvider),
                    );
              },
      ),
    ];
  }

  bool _isAncestor({
    required Folder targetFolder,
    required String draggedFolderId,
  }) {
    String? currentParentId = targetFolder.parentID;
    while (currentParentId != null) {
      if (currentParentId == draggedFolderId) {
        return true;
      }
      currentParentId = widget.folderLookup[currentParentId]?.parentID;
    }
    return false;
  }
}

class _SidebarRowShell extends StatelessWidget {
  const _SidebarRowShell({
    required this.child,
    required this.onTap,
    required this.selected,
    required this.isDropTarget,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;
  final bool isDropTarget;

  @override
  Widget build(BuildContext context) {
    final borderColor = isDropTarget
        ? Settings.tacticalVioletTheme.ring
        : (selected
            ? Settings.tacticalVioletTheme.primary
            : Colors.transparent);
    final backgroundColor = selected
        ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.18)
        : (isDropTarget
            ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.10)
            : Colors.transparent);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

extension on Iterable<String?> {
  String? get firstOrNull => isEmpty ? null : first;
}

class _SidebarSectionLabel extends StatelessWidget {
  const _SidebarSectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        color: Settings.tacticalVioletTheme.mutedForeground,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
    );
  }
}

class _SidebarActionButton extends StatelessWidget {
  const _SidebarActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    return ShadButton.ghost(
      onPressed: onPressed,
      mainAxisAlignment: MainAxisAlignment.start,
      leading: Icon(icon, size: 18),
      child: Text(label),
    );
  }
}

class _SidebarSelect<T> extends StatelessWidget {
  const _SidebarSelect({
    required this.currentValue,
    required this.values,
    required this.labels,
    required this.onChanged,
  });

  final T currentValue;
  final Iterable<T> values;
  final Map<T, String> labels;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ShadSelect<T>(
      initialValue: currentValue,
      selectedOptionBuilder: (context, value) => Text(labels[value]!),
      options: [
        for (final value in values)
          ShadOption(
            value: value,
            child: Text(labels[value]!),
          ),
      ],
      onChanged: (value) {
        if (value != null) {
          onChanged(value);
        }
      },
    );
  }
}

class _FolderDragPreview extends StatelessWidget {
  const _FolderDragPreview({required this.folder});

  final Folder folder;

  @override
  Widget build(BuildContext context) {
    final color = folder.customColor ??
        Folder.folderColorMap[folder.color] ??
        Colors.white;
    return Material(
      color: Colors.transparent,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Settings.tacticalVioletTheme.ring),
          boxShadow: const [Settings.cardForegroundBackdrop],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(folder.icon, size: 18, color: color),
            const SizedBox(width: 10),
            Text(
              folder.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderTreeNode {
  const _FolderTreeNode({
    required this.folder,
    required this.children,
  });

  final Folder folder;
  final List<_FolderTreeNode> children;
}

List<_FolderTreeNode> _buildVisibleTree(
  List<Folder> folders,
  String searchQuery,
) {
  final byParent = <String?, List<Folder>>{};
  for (final folder in folders) {
    byParent.putIfAbsent(folder.parentID, () => []).add(folder);
  }

  for (final entry in byParent.entries) {
    entry.value.sort((a, b) => a.dateCreated.compareTo(b.dateCreated));
  }

  List<_FolderTreeNode> walk(String? parentId) {
    final children = byParent[parentId] ?? const <Folder>[];
    final nodes = <_FolderTreeNode>[];
    for (final folder in children) {
      final nested = walk(folder.id);
      final matchesSearch = searchQuery.isEmpty ||
          folder.name.toLowerCase().contains(searchQuery);
      if (matchesSearch || nested.isNotEmpty) {
        nodes.add(_FolderTreeNode(folder: folder, children: nested));
      }
    }
    return nodes;
  }

  return walk(null);
}
