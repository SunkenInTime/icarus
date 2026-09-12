import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/demo_tag.dart';
import 'package:icarus/widgets/window_chrome.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _controlHeight = 28;
// Tabs sit apart so a selected and a hovered background never touch.
const double _tabGap = 4;
// Action menus hug their labels.
const double _sortMenuWidth = 168;
const double _newMenuWidth = 140;
const double _menuItemHorizontalPadding = 8;
const double _menuIconWidth = 18;
const double _menuItemGap = 8;
const double _menuLabelLeftInset =
    _menuItemHorizontalPadding + _menuIconWidth + _menuItemGap;

/// The library's only chrome: tabs on the left, search / sort / New on the
/// right, all inside the window's title strip.
class LibraryTitleStrip extends ConsumerStatefulWidget {
  const LibraryTitleStrip({
    super.key,
    required this.onCreateStrategy,
    required this.onCreateFolder,
    required this.onImportIca,
    required this.onImportBackup,
    required this.onExportLibrary,
  });

  final VoidCallback onCreateStrategy;
  final VoidCallback onCreateFolder;
  final VoidCallback onImportIca;
  final VoidCallback onImportBackup;
  final VoidCallback onExportLibrary;

  @override
  ConsumerState<LibraryTitleStrip> createState() => _LibraryTitleStripState();
}

class _LibraryTitleStripState extends ConsumerState<LibraryTitleStrip> {
  final ShadPopoverController _sortController = ShadPopoverController();
  final ShadPopoverController _newController = ShadPopoverController();

  @override
  void dispose() {
    _sortController.dispose();
    _newController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppWindowStrip(
      child: Row(
        children: [
          const WindowsIcarusWordmark(),
          const SizedBox(width: 6),
          _TabButton(
            key: const ValueKey('library-tab-library'),
            icon: LucideIcons.folder,
            label: 'My Library',
            semanticsLabel: 'My Library',
            selected: true,
            onTap: () => ref.read(folderProvider.notifier).updateID(null),
          ),
          const SizedBox(width: _tabGap),
          // Shared and Community have nowhere to go yet; they hold their
          // place so the library's shape does not move when they land.
          const _TabButton(
            key: ValueKey('library-tab-shared'),
            icon: LucideIcons.users,
            label: 'Shared',
            semanticsLabel: 'Shared library',
            selected: false,
            dimmed: true,
          ),
          const SizedBox(width: _tabGap),
          const _TabButton(
            key: ValueKey('library-tab-community'),
            icon: LucideIcons.globe,
            label: 'Community',
            semanticsLabel: 'Community library',
            selected: false,
            dimmed: true,
          ),
          if (kIsWeb) ...[
            const SizedBox(width: 8),
            const DemoTag(),
          ],
          const Expanded(
            child: WindowDragArea(
              key: ValueKey('library-window-drag-area'),
              child: SizedBox.expand(),
            ),
          ),
          const SizedBox(
            height: _controlHeight,
            child: SearchTextField(
              key: ValueKey('library-search'),
              collapsedWidth: 34,
              expandedWidth: 220,
              compact: true,
              hintText: 'Search',
            ),
          ),
          const SizedBox(width: 4),
          _buildSortMenu(),
          const SizedBox(width: 8),
          _buildNewMenu(),
          const SizedBox(width: 10),
        ],
      ),
    );
  }

  Widget _buildSortMenu() {
    final filter = ref.watch(strategyFilterProvider);
    final isAscending = filter.sortOrder == SortOrder.ascending;
    return ShadPopover(
      controller: _sortController,
      padding: const EdgeInsets.all(6),
      anchor: const ShadAnchor(
        offset: Offset(0, 6),
        childAlignment: Alignment.topRight,
        overlayAlignment: Alignment.bottomRight,
      ),
      popover: (context) => SizedBox(
        width: _sortMenuWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _MenuLabel('Sort by'),
            for (final value in SortBy.values)
              _MenuItem(
                menu: _sortController,
                icon: value == filter.sortBy ? LucideIcons.check : null,
                label: StrategyFilterProvider.sortByLabels[value]!,
                onPressed: () {
                  ref.read(strategyFilterProvider.notifier).setSortBy(value);
                },
              ),
            const _MenuDivider(),
            _MenuItem(
              menu: _sortController,
              icon: isAscending
                  ? LucideIcons.arrowUpNarrowWide
                  : LucideIcons.arrowDownWideNarrow,
              label: StrategyFilterProvider.sortOrderLabels[filter.sortOrder]!,
              onPressed: () {
                ref.read(strategyFilterProvider.notifier).setSortOrder(
                      isAscending ? SortOrder.descending : SortOrder.ascending,
                    );
              },
            ),
          ],
        ),
      ),
      child: Tooltip(
        message: 'Sort',
        child: ShadIconButton.ghost(
          key: const ValueKey('library-sort-menu'),
          width: _controlHeight,
          height: _controlHeight,
          foregroundColor: Settings.tacticalVioletTheme.mutedForeground,
          onPressed: _sortController.toggle,
          icon: Icon(
            isAscending
                ? LucideIcons.arrowUpNarrowWide
                : LucideIcons.arrowDownWideNarrow,
            size: 16,
          ),
        ),
      ),
    );
  }

  Widget _buildNewMenu() {
    const showLibraryTools = !kIsWeb;
    return ShadPopover(
      controller: _newController,
      padding: const EdgeInsets.all(6),
      anchor: const ShadAnchor(
        offset: Offset(0, 6),
        childAlignment: Alignment.topRight,
        overlayAlignment: Alignment.bottomRight,
      ),
      popover: (context) => SizedBox(
        width: _newMenuWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MenuItem(
              menu: _newController,
              key: const ValueKey('library-new-strategy'),
              icon: LucideIcons.filePlus,
              label: 'New Strategy',
              onPressed: widget.onCreateStrategy,
            ),
            _MenuItem(
              menu: _newController,
              key: const ValueKey('library-new-folder'),
              icon: LucideIcons.folderPlus,
              label: 'New Folder',
              onPressed: widget.onCreateFolder,
            ),
            if (showLibraryTools) ...[
              const _MenuDivider(),
              _MenuItem(
                menu: _newController,
                icon: LucideIcons.fileDown,
                label: 'Import .ica',
                onPressed: widget.onImportIca,
              ),
              _MenuItem(
                menu: _newController,
                icon: LucideIcons.archiveRestore,
                label: 'Import Backup',
                onPressed: widget.onImportBackup,
              ),
              _MenuItem(
                menu: _newController,
                icon: LucideIcons.archive,
                label: 'Export Library',
                onPressed: widget.onExportLibrary,
              ),
            ],
          ],
        ),
      ),
      child: ShadButton(
        key: const ValueKey('library-new-menu'),
        height: _controlHeight,
        padding: const EdgeInsets.only(left: 8, right: 6),
        onPressed: _newController.toggle,
        leading: const Icon(LucideIcons.plus, size: 16),
        trailing: const Icon(LucideIcons.chevronDown, size: 14),
        child: const Text('New'),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    this.onTap,
    this.dimmed = false,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final bool selected;
  final bool dimmed;

  /// Null while the tab has nowhere to go; the button reads as disabled.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final foreground = selected ? theme.foreground : theme.mutedForeground;
    final button = Semantics(
      label: semanticsLabel,
      button: true,
      selected: selected,
      enabled: onTap != null,
      onTap: onTap,
      child: Opacity(
        opacity: dimmed ? 0.45 : 1,
        child: ShadButton.ghost(
          height: _controlHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          gap: 6,
          cursor: onTap == null ? SystemMouseCursors.basic : null,
          backgroundColor: selected ? theme.secondary : null,
          foregroundColor: foreground,
          hoverForegroundColor: theme.foreground,
          onPressed: onTap,
          leading: Icon(icon, size: 15),
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
    if (onTap != null) return button;
    return ShadTooltip(
      builder: (context) => const Text('Coming soon'),
      child: button,
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    super.key,
    required this.menu,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  /// The popover holding this item; closed before [onPressed] runs.
  final ShadPopoverController menu;
  final IconData? icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ShadButton.ghost(
      height: 32,
      mainAxisAlignment: MainAxisAlignment.start,
      padding: const EdgeInsets.symmetric(
        horizontal: _menuItemHorizontalPadding,
      ),
      gap: _menuItemGap,
      onPressed: () {
        menu.hide();
        onPressed();
      },
      leading: SizedBox(
        width: _menuIconWidth,
        child: icon == null
            ? null
            : Icon(
                icon,
                size: 16,
                color: icon == LucideIcons.check
                    ? Settings.tacticalVioletTheme.primary
                    : Settings.tacticalVioletTheme.mutedForeground,
              ),
      ),
      child: Flexible(
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Settings.tacticalVioletTheme.foreground),
        ),
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_menuLabelLeftInset, 6, 8, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: Settings.tacticalVioletTheme.mutedForeground,
          ),
        ),
      ),
    );
  }
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Divider(height: 1, color: Settings.tacticalVioletTheme.border),
    );
  }
}
