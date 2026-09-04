import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/widgets/account_avatar.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/demo_tag.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:icarus/widgets/window_chrome.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _controlHeight = 28;
const double _menuWidth = 200;

/// The library's only chrome: tabs on the left, search / sort / New / account
/// on the right, all inside the window's title strip.
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
  final ShadPopoverController _accountController = ShadPopoverController();

  @override
  void dispose() {
    _sortController.dispose();
    _newController.dispose();
    _accountController.dispose();
    super.dispose();
  }

  void _showAuthDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => const AuthDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(libraryTabProvider);
    final cloudAvailable = ref.watch(isCloudWorkspaceAvailableProvider);
    final navigation = ref.read(libraryNavigationProvider);

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
            selected: tab == LibraryTab.library,
            onTap: navigation.showLibrary,
          ),
          _TabButton(
            key: const ValueKey('library-tab-shared'),
            icon: LucideIcons.users,
            label: 'Shared',
            semanticsLabel: 'Shared library',
            selected: tab == LibraryTab.shared,
            dimmed: !cloudAvailable,
            onTap: () {
              if (!navigation.showShared()) {
                _showAuthDialog();
              }
            },
          ),
          _TabButton(
            key: const ValueKey('library-tab-community'),
            icon: LucideIcons.globe,
            label: 'Community',
            semanticsLabel: 'Community library',
            selected: tab == LibraryTab.community,
            onTap: navigation.showCommunity,
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
          if (tab != LibraryTab.community) ...[
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
            if (tab == LibraryTab.shared)
              ShadButton.secondary(
                key: const ValueKey('cloud-add-shared-item'),
                height: _controlHeight,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                onPressed: () => showAddSharedItemDialog(context),
                leading: const Icon(LucideIcons.link, size: 14),
                child: const Text('Add by Link or Code'),
              )
            else
              _buildNewMenu(),
            const SizedBox(width: 8),
          ],
          _buildAccount(),
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
        width: _menuWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _MenuLabel('Sort by'),
            for (final value in SortBy.values)
              _MenuItem(
                menu: _sortController,
                icon: value == filter.sortBy ? Icons.check : null,
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
        width: _menuWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MenuItem(
              menu: _newController,
              key: const ValueKey('library-new-strategy'),
              icon: Icons.note_add_outlined,
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
                icon: Icons.file_download_outlined,
                label: 'Import .ica',
                onPressed: widget.onImportIca,
              ),
              _MenuItem(
                menu: _newController,
                icon: Icons.archive_outlined,
                label: 'Import Backup',
                onPressed: widget.onImportBackup,
              ),
              _MenuItem(
                menu: _newController,
                icon: Icons.backup_outlined,
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
        leading: const Icon(Icons.add, size: 16),
        trailing: const Icon(Icons.keyboard_arrow_down, size: 16),
        child: const Text('New'),
      ),
    );
  }

  Widget _buildAccount() {
    final auth = ref.watch(authProvider);
    if (auth.isLoading) {
      return const SizedBox(
        key: ValueKey('library-account-action'),
        width: _controlHeight,
        height: _controlHeight,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!auth.isAuthenticated) {
      return Semantics(
        label: 'Log in to Icarus',
        button: true,
        onTap: _showAuthDialog,
        child: ShadButton.secondary(
          key: const ValueKey('library-account-action'),
          height: _controlHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          onPressed: _showAuthDialog,
          child: const Text('Log In'),
        ),
      );
    }
    return ShadPopover(
      controller: _accountController,
      padding: const EdgeInsets.all(6),
      anchor: const ShadAnchor(
        offset: Offset(0, 6),
        childAlignment: Alignment.topRight,
        overlayAlignment: Alignment.bottomRight,
      ),
      popover: (context) => SizedBox(
        width: _menuWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    auth.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (auth.user?.email case final email?)
                    Text(
                      email,
                      style: TextStyle(
                        fontSize: 12,
                        color: Settings.tacticalVioletTheme.mutedForeground,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const _MenuDivider(),
            _MenuItem(
              menu: _accountController,
              icon: LucideIcons.logOut,
              label: 'Sign Out',
              onPressed: _confirmSignOut,
            ),
          ],
        ),
      ),
      child: Semantics(
        label: 'Account for ${auth.displayName}',
        button: true,
        onTap: _accountController.toggle,
        child: ShadButton.ghost(
          key: const ValueKey('library-account-action'),
          width: _controlHeight,
          height: _controlHeight,
          padding: EdgeInsets.zero,
          onPressed: _accountController.toggle,
          child: AccountAvatar(
            radius: 12,
            backgroundColor: Settings.tacticalVioletTheme.secondary,
            avatarUrl: auth.avatarUrl,
            fallback: const Icon(Icons.person, size: 14),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmSignOut() async {
    // One accidental click on the avatar used to sign out instantly.
    final confirmed = await ConfirmAlertDialog.show(
      context: context,
      title: 'Sign out?',
      content: 'Cloud strategies stay online; your local strategies stay on '
          'this device.',
      confirmText: 'Sign Out',
    );
    if (!confirmed || !mounted) return;
    unawaited(ref.read(authProvider.notifier).signOut());
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.onTap,
    this.dimmed = false,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final foreground = selected ? theme.foreground : theme.mutedForeground;
    return Semantics(
      label: semanticsLabel,
      button: true,
      selected: selected,
      onTap: onTap,
      child: Opacity(
        opacity: dimmed ? 0.45 : 1,
        child: ShadButton.ghost(
          height: _controlHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
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
      padding: const EdgeInsets.symmetric(horizontal: 8),
      onPressed: () {
        menu.hide();
        onPressed();
      },
      leading: SizedBox(
        width: 18,
        child: icon == null ? null : Icon(icon, size: 16),
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
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: Settings.tacticalVioletTheme.mutedForeground,
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
