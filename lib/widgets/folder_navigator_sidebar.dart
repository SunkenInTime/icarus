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

const _rowHoverDuration = Duration(milliseconds: 120);
const _treeRevealDuration = Duration(milliseconds: 180);
const _rowHeight = 34.0;
const _rowIconSize = 16.0;
const _chevronSlotWidth = 18.0;
const _depthIndent = 14.0;

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
    final isSharedWithMe =
        isCloud && cloudSection == CloudLibrarySection.sharedWithMe;
    final filterState = ref.watch(strategyFilterProvider);
    final searchQuery =
        ref.watch(strategySearchQueryProvider).trim().toLowerCase();
    final visibleRoots = _buildVisibleTree(folders, searchQuery);
    final folderLookup = {for (final folder in folders) folder.id: folder};

    return Container(
      width: 240,
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
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (isSharedWithMe)
                  ShadButton(
                    onPressed: () => showAddSharedItemDialog(context),
                    leading: const Icon(LucideIcons.link, size: 16),
                    child: const Text('Add by Link or Code'),
                  )
                else ...[
                  ShadButton(
                    onPressed: onCreateStrategy,
                    leading: const Icon(Icons.add, size: 16),
                    child: Text(
                      isCloud ? 'Create Cloud Strategy' : 'Create Strategy',
                    ),
                  ),
                  const SizedBox(height: 6),
                  ShadButton.secondary(
                    onPressed: onAddFolder,
                    leading: const Icon(LucideIcons.folderPlus, size: 16),
                    child: const Text('Add Folder'),
                  ),
                ],
                const SizedBox(height: 10),
                const SizedBox(
                  height: 36,
                  child: SearchTextField(
                    collapsedWidth: double.infinity,
                    expandedWidth: double.infinity,
                    compact: true,
                    hintText: 'Search strategies and folders',
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ShadSelect<SortBy>(
                        initialValue: filterState.sortBy,
                        selectedOptionBuilder: (context, value) => Text(
                          StrategyFilterProvider.sortByLabels[value]!,
                        ),
                        options: [
                          for (final value in SortBy.values)
                            ShadOption(
                              value: value,
                              child: Text(
                                StrategyFilterProvider.sortByLabels[value]!,
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(strategyFilterProvider.notifier)
                                .setSortBy(value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    _SortOrderToggle(sortOrder: filterState.sortOrder),
                  ],
                ),
                if (!isCloud) ...[
                  const SizedBox(height: 12),
                  const _SidebarSectionLabel(label: 'Library Tools'),
                  const SizedBox(height: 6),
                  _SidebarActionButton(
                    icon: Icons.file_download_outlined,
                    label: 'Import .ica',
                    onPressed: onImportIca,
                  ),
                  const SizedBox(height: 4),
                  _SidebarActionButton(
                    icon: Icons.archive_outlined,
                    label: 'Import Backup',
                    onPressed: onImportBackup,
                  ),
                  const SizedBox(height: 4),
                  _SidebarActionButton(
                    icon: Icons.backup_outlined,
                    label: 'Export Library',
                    onPressed: onExportLibrary,
                  ),
                ],
              ],
            ),
          ),
          Divider(
            height: 1,
            color: Settings.tacticalVioletTheme.border,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isCloud) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: _SidebarSectionLabel(label: 'Views'),
                    ),
                    const SizedBox(height: 6),
                    _SidebarRootItem(
                      isSelected: cloudSection == CloudLibrarySection.home &&
                          currentFolderId == null,
                    ),
                    const SizedBox(height: 2),
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
                    const SizedBox(height: 10),
                  ],
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: _SidebarSectionLabel(label: 'Folders'),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ListView(
                      children: [
                        if (!isCloud) ...[
                          _SidebarRootItem(isSelected: currentFolderId == null),
                          const SizedBox(height: 2),
                        ],
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
                              key: ValueKey(node.folder.id),
                              node: node,
                              depth: 0,
                              selectedFolderId: currentFolderId,
                              folderLookup: folderLookup,
                              forceExpanded: searchQuery.isNotEmpty,
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

class _SortOrderToggle extends ConsumerWidget {
  const _SortOrderToggle({required this.sortOrder});

  final SortOrder sortOrder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAscending = sortOrder == SortOrder.ascending;
    return Tooltip(
      message: StrategyFilterProvider.sortOrderLabels[sortOrder]!,
      child: ShadButton.outline(
        width: 36,
        height: 36,
        padding: EdgeInsets.zero,
        onPressed: () {
          ref.read(strategyFilterProvider.notifier).setSortOrder(
                isAscending ? SortOrder.descending : SortOrder.ascending,
              );
        },
        child: AnimatedSwitcher(
          duration: _rowHoverDuration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: Icon(
            isAscending
                ? LucideIcons.arrowUpNarrowWide
                : LucideIcons.arrowDownWideNarrow,
            key: ValueKey(isAscending),
            size: 16,
          ),
        ),
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
              SizedBox(width: _chevronSlotWidth),
              Icon(Icons.home_outlined, size: _rowIconSize),
              SizedBox(width: 10),
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
          const SizedBox(width: _chevronSlotWidth),
          Icon(icon, size: _rowIconSize),
          const SizedBox(width: 10),
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
    super.key,
    required this.node,
    required this.depth,
    required this.selectedFolderId,
    required this.folderLookup,
    required this.forceExpanded,
  });

  final _FolderTreeNode node;
  final int depth;
  final String? selectedFolderId;
  final Map<String, Folder> folderLookup;
  final bool forceExpanded;

  @override
  ConsumerState<_FolderSidebarItem> createState() => _FolderSidebarItemState();
}

class _FolderSidebarItemState extends ConsumerState<_FolderSidebarItem> {
  final ShadContextMenuController _menuButtonController =
      ShadContextMenuController();
  final ShadContextMenuController _rightClickMenuController =
      ShadContextMenuController();
  bool _hovered = false;
  bool _expanded = false;

  Folder get folder => widget.node.folder;

  @override
  void initState() {
    super.initState();
    _expanded = _containsSelected(widget.node);
    _menuButtonController.addListener(_onMenuStateChanged);
  }

  @override
  void didUpdateWidget(covariant _FolderSidebarItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedFolderId != oldWidget.selectedFolderId &&
        !_expanded &&
        _containsSelected(widget.node)) {
      _expanded = true;
    }
  }

  bool _containsSelected(_FolderTreeNode node) {
    final selectedId = widget.selectedFolderId;
    if (selectedId == null) {
      return false;
    }
    for (final child in node.children) {
      if (child.folder.id == selectedId || _containsSelected(child)) {
        return true;
      }
    }
    return false;
  }

  void _onMenuStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _menuButtonController.removeListener(_onMenuStateChanged);
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
    final hasChildren = widget.node.children.isNotEmpty;
    final showChildren = hasChildren && (_expanded || widget.forceExpanded);
    final showMenuButton =
        _hovered || selected || _menuButtonController.isOpen;

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
              padding: EdgeInsets.only(left: widget.depth * _depthIndent),
              child: MouseRegion(
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
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
                          _ChevronSlot(
                            hasChildren: hasChildren,
                            expanded: showChildren,
                            onTap: hasChildren
                                ? () => setState(() => _expanded = !_expanded)
                                : null,
                          ),
                          Icon(folder.icon, size: _rowIconSize, color: color),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              folder.name,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w500),
                            ),
                          ),
                          if (showMenuButton)
                            ShadContextMenuRegion(
                              controller: _menuButtonController,
                              items: _buildMenuItems(),
                              child: ShadIconButton.ghost(
                                width: 24,
                                height: 24,
                                onPressed: _menuButtonController.toggle,
                                icon: const Icon(Icons.more_horiz, size: 14),
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
        ClipRect(
          child: AnimatedSize(
            duration: _treeRevealDuration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: showChildren
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final child in widget.node.children)
                        _FolderSidebarItem(
                          key: ValueKey(child.folder.id),
                          node: child,
                          depth: widget.depth + 1,
                          selectedFolderId: widget.selectedFolderId,
                          folderLookup: widget.folderLookup,
                          forceExpanded: widget.forceExpanded,
                        ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
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
        onPressed: !canManage
            ? null
            : () async {
                await showDialog<String>(
                  context: context,
                  builder: (context) => FolderEditDialog(folder: folder),
                );
              },
        child: const Text('Edit'),
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
        onPressed: () async {
          await StrategyImportExportService(ref).exportFolder(folder.id);
        },
        child: const Text('Export'),
      ),
      ShadContextMenuItem(
        leading: Icon(
          Icons.delete_outline,
          color: Settings.tacticalVioletTheme.destructive,
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
        child: Text(
          'Delete',
          style: TextStyle(color: Settings.tacticalVioletTheme.destructive),
        ),
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

class _ChevronSlot extends StatelessWidget {
  const _ChevronSlot({
    required this.hasChildren,
    required this.expanded,
    required this.onTap,
  });

  final bool hasChildren;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (!hasChildren) {
      return const SizedBox(width: _chevronSlotWidth);
    }
    return SizedBox(
      width: _chevronSlotWidth,
      height: _rowHeight,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: AnimatedRotation(
          duration: _treeRevealDuration,
          curve: Curves.easeOutCubic,
          turns: expanded ? 0.25 : 0,
          child: Icon(
            Icons.chevron_right,
            size: 15,
            color: Settings.tacticalVioletTheme.mutedForeground,
          ),
        ),
      ),
    );
  }
}

class _SidebarRowShell extends StatefulWidget {
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
  State<_SidebarRowShell> createState() => _SidebarRowShellState();
}

class _SidebarRowShellState extends State<_SidebarRowShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final borderColor = widget.isDropTarget
        ? Settings.tacticalVioletTheme.ring
        : (widget.selected
            ? Settings.tacticalVioletTheme.primary
            : Colors.transparent);
    final backgroundColor = widget.selected
        ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.18)
        : (widget.isDropTarget
            ? Settings.tacticalVioletTheme.primary.withValues(alpha: 0.10)
            : (_hovered
                ? Settings.tacticalVioletTheme.muted.withValues(alpha: 0.5)
                : Colors.transparent));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: _rowHoverDuration,
              height: _rowHeight,
              padding: const EdgeInsets.only(left: 4, right: 6),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: borderColor),
              ),
              child: widget.child,
            ),
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
      size: ShadButtonSize.sm,
      onPressed: onPressed,
      mainAxisAlignment: MainAxisAlignment.start,
      leading: Icon(icon, size: 16),
      child: Text(label),
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
