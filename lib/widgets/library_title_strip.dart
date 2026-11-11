import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/widgets/asset_svg.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/form_factor.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/services/cloud_needs_connection.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/services/guarded_sign_out.dart';
import 'package:icarus/widgets/account_avatar.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:icarus/widgets/replay/replay_library_content.dart';
import 'package:icarus/widgets/strip_status_icons.dart';
import 'package:icarus/widgets/web_beta_tag.dart';
import 'package:icarus/widgets/window_chrome.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:icarus/widgets/loading_spinner.dart';

const double _controlHeight = 28;
// A fingertip's worth: the strip's 28px controls are for a mouse.
const double _phoneControlHeight = 36;
// Wide enough for tabs and actions on one row, as on a phone held sideways.
const double _phoneOneRowWidth = 660;
// Tabs sit apart so a selected and a hovered background never touch.
const double _tabGap = 4;
// Matches the ghost button's own radius so the rim hugs its hover shape.
const double _tabRadius = 6;
// Action menus hug their labels; the account menu keeps room for email text.
const double _sortMenuWidth = 168;
const double _newMenuWidth = 140;
const double _accountMenuWidth = 200;
const double _menuItemHorizontalPadding = 8;
const double _menuIconWidth = 18;
const double _menuItemGap = 8;
const double _menuLabelLeftInset =
    _menuItemHorizontalPadding + _menuIconWidth + _menuItemGap;

/// The library's only chrome: tabs on the left, What's new / search / sort /
/// New / account on the right, all inside the window's title strip.
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
  bool _phoneSearchOpen = false;

  void _closePhoneSearch() {
    ref.read(strategySearchQueryProvider.notifier).update('');
    setState(() => _phoneSearchOpen = false);
  }

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
    if (FormFactor.of(context) == FormFactor.phone) return _buildPhone(context);
    final tab = ref.watch(libraryTabProvider);
    final cloudBrowsable = ref.watch(isCloudLibraryBrowsableProvider);
    final isWebBeta = ref.watch(platformPolicyProvider).isWebBeta;
    // Signed out on the web beta, My Library holds only the sign-in action,
    // so there is nothing to search, sort, or create.
    final signInRequired = ref.watch(librarySignInRequiredProvider);
    final navigation = ref.read(libraryNavigationProvider);
    final l10n = context.l10n;

    return AppWindowStrip(
      child: Row(
        children: [
          const IcarusWordmark(),
          const SizedBox(width: 6),
          _TabButton(
            key: const ValueKey('library-tab-library'),
            icon: LucideIcons.folder,
            label: l10n.libraryTabMyLibrary,
            semanticsLabel: l10n.libraryTabMyLibrary,
            selected: tab == LibraryTab.library,
            onTap: navigation.showLibrary,
          ),
          const SizedBox(width: _tabGap),
          if (ref
              .watch(platformPolicyProvider)
              .supports(PlatformFeature.replays)) ...[
            _TabButton(
              key: const ValueKey('library-tab-replays'),
              icon: LucideIcons.film,
              label: l10n.libraryTabReplays,
              semanticsLabel: l10n.libraryTabReplays,
              selected: tab == LibraryTab.replays,
              onTap: navigation.showReplays,
            ),
            const SizedBox(width: _tabGap),
          ],
          _TabButton(
            key: const ValueKey('library-tab-shared'),
            icon: LucideIcons.users,
            label: l10n.libraryTabShared,
            semanticsLabel: l10n.libraryTabSharedSemantics,
            selected: tab == LibraryTab.shared,
            dimmed: !cloudBrowsable,
            onTap: _showSharedTab,
          ),
          const SizedBox(width: _tabGap),
          _TabButton(
            key: const ValueKey('library-tab-community'),
            icon: LucideIcons.globe,
            label: l10n.libraryTabCommunity,
            semanticsLabel: l10n.libraryTabCommunitySemantics,
            selected: tab == LibraryTab.community,
            onTap: navigation.showCommunity,
          ),
          if (isWebBeta) ...[
            const SizedBox(width: 8),
            const WebBetaTag(),
          ],
          const Expanded(
            child: WindowDragArea(
              key: ValueKey('library-window-drag-area'),
              child: SizedBox.expand(),
            ),
          ),
          const WhatsNewIcon(),
          const SizedBox(width: 4),
          if (tab == LibraryTab.replays) ...[
            _buildAddReplayButton(),
            const SizedBox(width: 8),
          ] else if (tab != LibraryTab.community && !signInRequired) ...[
            const SizedBox(
              height: _controlHeight,
              child: SearchTextField(
                key: ValueKey('library-search'),
                collapsedWidth: _controlHeight,
                expandedWidth: 220,
                compact: true,
              ),
            ),
            const SizedBox(width: 4),
            _buildSortMenu(),
            const SizedBox(width: 8),
            // Nothing is created in Shared; its New is adding what someone
            // shared with you.
            if (tab == LibraryTab.shared)
              ShadButton.secondary(
                key: const ValueKey('cloud-add-shared-item'),
                height: _controlHeight,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                onPressed: () {
                  if (refuseCloudChangeWhileOffline(
                    ref.read(l10nProvider),
                    ref.read(cloudLibraryShowsCopyProvider),
                  )) {
                    return;
                  }
                  showAddSharedItemDialog(context);
                },
                leading: const Icon(LucideIcons.link, size: 14),
                child: Text(l10n.libraryAddByLinkOrCode),
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

  void _showSharedTab() {
    final navigation = ref.read(libraryNavigationProvider);
    if (navigation.showShared()) return;
    // Signed in but the cloud is unreachable: My Library carries the retry.
    // Never ask for a login over an existing session.
    if (ref.read(authProvider).isAuthenticated) {
      navigation.showLibrary();
    } else {
      _showAuthDialog();
    }
  }

  /// The strip's contents for a phone, with bigger targets: a row of actions
  /// over a row of tabs, or the two side by side when the phone is held
  /// sideways. Search takes the actions' row while it's open, since there's
  /// no room for it to slide out beside them.
  Widget _buildPhone(BuildContext context) {
    final tab = ref.watch(libraryTabProvider);
    final navigation = ref.read(libraryNavigationProvider);
    final cloudBrowsable = ref.watch(isCloudLibraryBrowsableProvider);
    final signInRequired = ref.watch(librarySignInRequiredProvider);
    final isWebBeta = ref.watch(platformPolicyProvider).isWebBeta;
    final canSearch = tab != LibraryTab.replays &&
        tab != LibraryTab.community &&
        !signInRequired;
    final searching = _phoneSearchOpen && canSearch;
    final l10n = context.l10n;

    final tabs = Row(
      children: [
        Expanded(
          child: _TabButton(
            key: const ValueKey('library-tab-library'),
            label: l10n.libraryTabMyLibrary,
            semanticsLabel: l10n.libraryTabMyLibrary,
            selected: tab == LibraryTab.library,
            height: _phoneControlHeight,
            onTap: navigation.showLibrary,
          ),
        ),
        const SizedBox(width: _tabGap),
        Expanded(
          child: _TabButton(
            key: const ValueKey('library-tab-shared'),
            label: l10n.libraryTabShared,
            semanticsLabel: l10n.libraryTabSharedSemantics,
            selected: tab == LibraryTab.shared,
            dimmed: !cloudBrowsable,
            height: _phoneControlHeight,
            onTap: _showSharedTab,
          ),
        ),
        const SizedBox(width: _tabGap),
        Expanded(
          child: _TabButton(
            key: const ValueKey('library-tab-community'),
            label: l10n.libraryTabCommunity,
            semanticsLabel: l10n.libraryTabCommunitySemantics,
            selected: tab == LibraryTab.community,
            height: _phoneControlHeight,
            onTap: navigation.showCommunity,
          ),
        ),
      ],
    );

    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AssetSvg(
          'assets/brand/icarus-wordmark.svg',
          height: 14,
          semanticsLabel: 'Icarus',
        ),
        if (isWebBeta) ...[
          const SizedBox(width: 8),
          const WebBetaTag(),
        ],
      ],
    );

    final Widget actions = searching
        ? Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => SizedBox(
                    height: _phoneControlHeight,
                    child: SearchTextField(
                      key: const ValueKey('library-search'),
                      collapsedWidth: constraints.maxWidth,
                      expandedWidth: constraints.maxWidth,
                      compact: true,
                      autofocus: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ShadIconButton.ghost(
                key: const ValueKey('library-search-close'),
                width: _phoneControlHeight,
                height: _phoneControlHeight,
                foregroundColor: Settings.tacticalVioletTheme.mutedForeground,
                onPressed: _closePhoneSearch,
                icon: const Icon(LucideIcons.x, size: 18),
              ),
            ],
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (canSearch) ...[
                ShadIconButton.ghost(
                  key: const ValueKey('library-search-open'),
                  width: _phoneControlHeight,
                  height: _phoneControlHeight,
                  foregroundColor: Settings.tacticalVioletTheme.mutedForeground,
                  onPressed: () => setState(() => _phoneSearchOpen = true),
                  icon: const Icon(LucideIcons.search, size: 18),
                ),
                _buildSortMenu(size: _phoneControlHeight),
                const SizedBox(width: 4),
                if (tab == LibraryTab.shared)
                  ShadIconButton.secondary(
                    key: const ValueKey('cloud-add-shared-item'),
                    width: _phoneControlHeight,
                    height: _phoneControlHeight,
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      if (refuseCloudChangeWhileOffline(
                        ref.read(l10nProvider),
                        ref.read(cloudLibraryShowsCopyProvider),
                      )) {
                        return;
                      }
                      showAddSharedItemDialog(context);
                    },
                    icon: const Icon(LucideIcons.link, size: 16),
                  )
                else
                  _buildPhoneNewMenu(),
                const SizedBox(width: 8),
              ],
              _buildAccount(size: _phoneControlHeight),
            ],
          );

    return DecoratedBox(
      key: const ValueKey('app-window-strip'),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        border: Border(
          bottom: BorderSide(color: Settings.tacticalVioletTheme.border),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= _phoneOneRowWidth) {
              return SizedBox(
                height: _phoneControlHeight,
                child: Row(
                  children: [
                    brand,
                    const SizedBox(width: 16),
                    SizedBox(width: 280, child: tabs),
                    const SizedBox(width: 16),
                    Expanded(child: actions),
                  ],
                ),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: _phoneControlHeight,
                  child: Row(
                    children: [
                      if (!searching) ...[brand, const SizedBox(width: 8)],
                      Expanded(child: actions),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(height: _phoneControlHeight, child: tabs),
              ],
            );
          },
        ),
      ),
    );
  }

  /// New is one button on a phone: the strategy goes in the menu with the
  /// folder, since there's no room for its label.
  Widget _buildPhoneNewMenu() {
    final l10n = context.l10n;
    return ShadPopover(
      controller: _newController,
      padding: const EdgeInsets.all(6),
      anchor: const ShadAnchor(
        offset: Offset(0, 6),
        childAlignment: Alignment.topRight,
        overlayAlignment: Alignment.bottomRight,
      ),
      popover: (context) => SizedBox(
        width: _newMenuWidth + 24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MenuItem(
              menu: _newController,
              key: const ValueKey('library-new-strategy'),
              icon: LucideIcons.filePlus,
              label: l10n.libraryNewStrategy,
              onPressed: widget.onCreateStrategy,
            ),
            _MenuItem(
              menu: _newController,
              key: const ValueKey('library-new-folder'),
              icon: LucideIcons.folderPlus,
              label: l10n.libraryNewFolder,
              onPressed: widget.onCreateFolder,
            ),
          ],
        ),
      ),
      child: Semantics(
        label: l10n.libraryNewMenuSemantics,
        button: true,
        child: ShadIconButton(
          key: const ValueKey('library-new-menu'),
          width: _phoneControlHeight,
          height: _phoneControlHeight,
          padding: EdgeInsets.zero,
          onPressed: _newController.toggle,
          icon: const Icon(LucideIcons.plus, size: 18),
        ),
      ),
    );
  }

  /// Replays Valorant downloads list themselves; this brings in one saved
  /// anywhere else.
  Widget _buildAddReplayButton() {
    return ShadButton(
      key: const ValueKey('library-add-replay'),
      height: _controlHeight,
      padding: const EdgeInsets.only(left: 8, right: 10),
      leading: const Icon(LucideIcons.plus, size: 16),
      onPressed: () async {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['vrf'],
          allowMultiple: true,
        );
        if (result == null || !mounted) return;
        await addReplays(ref, [
          for (final file in result.files)
            if (file.path != null) file.path!,
        ]);
      },
      child: Text(context.l10n.libraryAddReplay),
    );
  }

  Widget _buildSortMenu({double size = _controlHeight}) {
    final filter = ref.watch(strategyFilterProvider);
    final isAscending = filter.sortOrder == SortOrder.ascending;
    final l10n = context.l10n;
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
            _MenuLabel(l10n.librarySortBy),
            for (final value in SortBy.values)
              _MenuItem(
                menu: _sortController,
                icon: value == filter.sortBy ? LucideIcons.check : null,
                label: StrategyFilterProvider.sortByLabel(value, l10n),
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
              label: StrategyFilterProvider.sortOrderLabel(
                filter.sortOrder,
                l10n,
              ),
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
        message: l10n.librarySortTooltip,
        child: ShadIconButton.ghost(
          key: const ValueKey('library-sort-menu'),
          width: size,
          height: size,
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

  /// The primary button's raised look with one side's corners squared off.
  /// Spelled out in full because merging a partial decoration drops the
  /// theme's gradient and shadow.
  static ShadDecoration _halfDecoration(BorderRadius radius) => ShadDecoration(
        gradient: Settings.raisedPrimaryFill,
        shadows: const [Settings.raisedDropShadow],
        border: ShadBorder(
          radius: radius,
          top: const ShadBorderSide(color: Settings.raisedTopLight, width: 1),
        ),
      );

  Widget _buildNewMenu() {
    final policy = ref.watch(platformPolicyProvider);
    final canImport = policy.supports(PlatformFeature.importFiles);
    final canExport = policy.supports(PlatformFeature.exportFiles);
    final l10n = context.l10n;
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
              key: const ValueKey('library-new-folder'),
              icon: LucideIcons.folderPlus,
              label: l10n.libraryNewFolder,
              onPressed: widget.onCreateFolder,
            ),
            if (canImport || canExport) const _MenuDivider(),
            if (canImport) ...[
              _MenuItem(
                menu: _newController,
                icon: LucideIcons.fileDown,
                label: l10n.libraryImportIca,
                onPressed: widget.onImportIca,
              ),
              _MenuItem(
                menu: _newController,
                icon: LucideIcons.archiveRestore,
                label: l10n.libraryImportBackup,
                onPressed: widget.onImportBackup,
              ),
            ],
            if (canExport)
              _MenuItem(
                menu: _newController,
                icon: LucideIcons.archive,
                label: l10n.libraryExportLibrary,
                onPressed: widget.onExportLibrary,
              ),
          ],
        ),
      ),
      // A split button: the body goes straight to the map picker, the
      // chevron opens everything else. Each half keeps only its outer corners.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShadButton(
            key: const ValueKey('library-new-strategy'),
            height: _controlHeight,
            padding: const EdgeInsets.only(left: 8, right: 10),
            decoration: _halfDecoration(
              const BorderRadius.horizontal(left: Radius.circular(6)),
            ),
            onPressed: widget.onCreateStrategy,
            leading: const Icon(LucideIcons.plus, size: 16),
            child: Text(l10n.libraryNewStrategy),
          ),
          // A rounded border must be one colour, so the seam is its own strip.
          const SizedBox(
            width: 1,
            height: _controlHeight,
            child: ColoredBox(color: Settings.raisedBottomShade),
          ),
          ShadIconButton(
            key: const ValueKey('library-new-menu'),
            width: 24,
            height: _controlHeight,
            padding: EdgeInsets.zero,
            decoration: _halfDecoration(
              const BorderRadius.horizontal(right: Radius.circular(6)),
            ),
            onPressed: _newController.toggle,
            icon: const Icon(LucideIcons.chevronDown, size: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildAccount({double size = _controlHeight}) {
    final auth = ref.watch(authProvider);
    final l10n = context.l10n;
    if (auth.isLoading) {
      return SizedBox(
        key: const ValueKey('library-account-action'),
        width: size,
        height: size,
        child: const Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: LoadingSpinner(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!auth.isAuthenticated) {
      return Semantics(
        label: l10n.libraryLogInSemantics,
        button: true,
        onTap: _showAuthDialog,
        child: ShadButton.secondary(
          key: const ValueKey('library-account-action'),
          height: size,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          onPressed: _showAuthDialog,
          child: Text(l10n.commonLogIn),
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
        width: _accountMenuWidth,
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
                    auth.displayName(l10n),
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
              label: l10n.commonSignOut,
              onPressed: _confirmSignOut,
            ),
          ],
        ),
      ),
      child: Semantics(
        label: l10n.libraryAccountSemantics(auth.displayName(l10n)),
        button: true,
        onTap: _accountController.toggle,
        child: ShadButton.ghost(
          key: const ValueKey('library-account-action'),
          width: size,
          height: size,
          padding: EdgeInsets.zero,
          onPressed: _accountController.toggle,
          child: AccountAvatar(
            radius: 12,
            backgroundColor: Settings.tacticalVioletTheme.secondary,
            avatarUrl: auth.avatarUrl,
            fallback: const Icon(LucideIcons.user, size: 14),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmSignOut() async {
    await ref.read(guardedSignOutRequestProvider)(context);
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.onTap,
    this.dimmed = false,
    this.height = _controlHeight,
  });

  /// Left out on a phone, where three labels only just fit.
  final IconData? icon;
  final double height;
  final String label;
  final String semanticsLabel;
  final bool selected;

  /// Signed out, Shared still answers a tap (with the sign-in dialog) but
  /// reads as unavailable.
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
        child: DecoratedBox(
          decoration: selected
              ? Settings.raisedSurface(_tabRadius)
              : const BoxDecoration(),
          child: ShadButton.ghost(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            gap: 6,
            backgroundColor: selected ? Colors.transparent : null,
            hoverBackgroundColor: selected ? Colors.transparent : null,
            foregroundColor: foreground,
            hoverForegroundColor: theme.foreground,
            onPressed: onTap,
            leading: icon == null ? null : Icon(icon, size: 15),
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
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
      height: FormFactor.of(context).isTouch ? 40 : 32,
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
                    ? Settings.accentInk
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
