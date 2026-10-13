import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/share/current_share_origin.dart';
import 'package:icarus/share/share_link_copy.dart';
import 'package:icarus/share/share_link_format.dart';
import 'package:icarus/widgets/account_avatar.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Headline like: Share "My Strategy Name" (`"` in [name] become `'`).
String _shareDialogHeadline(String name) {
  final safe = name.replaceAll('"', "'");
  return 'Share "$safe"';
}

const _stateSwitchDuration = Duration(milliseconds: 180);
const _hoverDuration = Duration(milliseconds: 120);
const _copiedFlashDuration = Duration(milliseconds: 1200);

String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return '${time.year}-${time.month.toString().padLeft(2, '0')}'
      '-${time.day.toString().padLeft(2, '0')}';
}

String _memberName(ShareMember member) => member.displayName ?? 'Teammate';

/// The owner's view of who can open a strategy or folder and the links that
/// let people in. People come first: what the owner usually checks is who
/// is in, and the links are how more people get there.
class ShareLinksDialog extends ConsumerStatefulWidget {
  const ShareLinksDialog({
    super.key,
    required this.targetType,
    required this.targetPublicId,
    required this.title,
  });

  final String targetType;
  final String targetPublicId;
  final String title;

  @override
  ConsumerState<ShareLinksDialog> createState() => _ShareLinksDialogState();
}

Future<void> showAddSharedItemDialog(BuildContext context) {
  return showShadDialog<void>(
    context: context,
    builder: (_) => const AddSharedItemDialog(),
  );
}

enum _LoadStatus { loading, error, ready }

class _ShareLinksDialogState extends ConsumerState<ShareLinksDialog> {
  List<ShareLinkSummary> _links = const [];
  List<ShareMember> _members = const [];
  _LoadStatus _status = _LoadStatus.loading;
  bool _isCreating = false;
  String? _disablingToken;
  final Set<String> _busyMemberIds = {};
  String _selectedRole = 'viewer';

  int get _activeLinkCount => _links.where((link) => !link.isRevoked).length;

  ConvexStrategyRepository get _repository =>
      ref.read(convexStrategyRepositoryProvider);

  /// The people a link let in directly; folder members came another way.
  List<ShareMember> _joinedThrough(String token) => _members
      .where((member) => !member.isInherited && member.shareLinkToken == token)
      .toList(growable: false);

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading) {
      setState(() => _status = _LoadStatus.loading);
    }
    try {
      final results = await Future.wait([
        _repository.listShareLinks(
          targetType: widget.targetType,
          targetPublicId: widget.targetPublicId,
        ),
        _repository.listShareMembers(
          targetType: widget.targetType,
          targetPublicId: widget.targetPublicId,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _links = results[0] as List<ShareLinkSummary>;
        _members = results[1] as List<ShareMember>;
        _status = _LoadStatus.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = _LoadStatus.error);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _createLink() async {
    setState(() => _isCreating = true);
    final token = generateIcarusShareCode();
    try {
      await _repository.createShareLink(
        targetType: widget.targetType,
        targetPublicId: widget.targetPublicId,
        token: token,
        role: _selectedRole,
      );
      await Clipboard.setData(ClipboardData(
          text: buildIcarusShareLink(token, origin: currentShareOrigin())));
      Settings.showToast(
        message: 'Share link copied to clipboard.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
      await _load(showLoading: false);
    } catch (_) {
      Settings.showToast(
        message: 'Failed to create share link.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } finally {
      if (mounted) {
        setState(() => _isCreating = false);
      }
    }
  }

  Future<void> _disableLink(String token) async {
    final joined = _joinedThrough(token);
    final removeMembers = await showShadDialog<bool>(
      context: context,
      builder: (_) => _DisableLinkDialog(joined: joined),
    );
    if (removeMembers == null || !mounted) {
      return;
    }
    setState(() => _disablingToken = token);
    try {
      await _repository.revokeShareLink(
        targetType: widget.targetType,
        targetPublicId: widget.targetPublicId,
        token: token,
        removeMembers: removeMembers,
      );
      await _load(showLoading: false);
    } catch (_) {
      Settings.showToast(
        message: ShareLinkCopy.disableFailure,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } finally {
      if (mounted) {
        setState(() => _disablingToken = null);
      }
    }
  }

  Future<void> _setRole(ShareMember member, String role) async {
    if (role == member.role) return;
    setState(() => _busyMemberIds.add(member.memberId));
    try {
      await _repository.setShareMemberRole(
        targetType: widget.targetType,
        targetPublicId: widget.targetPublicId,
        memberId: member.memberId,
        role: role,
      );
    } catch (_) {
      Settings.showToast(
        message: ShareLinkCopy.roleChangeFailure,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
    // Reload either way, so the switch shows what the server holds.
    await _load(showLoading: false);
    if (mounted) {
      setState(() => _busyMemberIds.remove(member.memberId));
    }
  }

  Future<void> _remove(ShareMember member) async {
    final confirmed = await ConfirmAlertDialog.show(
      context: context,
      title: ShareLinkCopy.removeMemberTitle(_memberName(member)),
      content: ShareLinkCopy.removeMemberDescription,
      confirmText: ShareLinkCopy.removeMemberAction,
      isDestructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _busyMemberIds.add(member.memberId));
    try {
      await _repository.removeShareMember(
        targetType: widget.targetType,
        targetPublicId: widget.targetPublicId,
        memberId: member.memberId,
      );
      await _load(showLoading: false);
    } catch (_) {
      Settings.showToast(
        message: ShareLinkCopy.removeMemberFailure,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } finally {
      if (mounted) {
        setState(() => _busyMemberIds.remove(member.memberId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final maxBodyHeight = MediaQuery.sizeOf(context).height - 280;

    return ShadDialog(
      title: Text(
        _shareDialogHeadline(widget.title),
        softWrap: true,
      ),
      description: Text(
        ShareLinkCopy.dialogDescription(
          widget.targetType,
          // Links made on web point at the web app (see currentShareOrigin).
          opensInBrowser: kIsWeb,
        ),
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
      child: SizedBox(
        width: double.infinity,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: maxBodyHeight < 240 ? 240 : maxBodyHeight,
          ),
          child: SingleChildScrollView(
            child: AnimatedSize(
              duration: _stateSwitchDuration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: _stateSwitchDuration,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                child: _buildBody(theme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ShadThemeData theme) {
    switch (_status) {
      case _LoadStatus.loading:
        return const _LinkListPlaceholder(key: ValueKey('loading'));
      case _LoadStatus.error:
        return _LinkListMessage(
          key: const ValueKey('error'),
          icon: LucideIcons.circleAlert,
          message: "Couldn't load who has access.",
          action: ShadButton.ghost(
            size: ShadButtonSize.sm,
            onPressed: _load,
            leading: const Icon(LucideIcons.refreshCw, size: 14),
            child: const Text('Retry'),
          ),
        );
      case _LoadStatus.ready:
        return Column(
          key: const ValueKey('ready'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildPeople(),
            const SizedBox(height: 16),
            Container(height: 1, color: theme.colorScheme.border),
            const SizedBox(height: 16),
            _buildNewLink(theme),
            const SizedBox(height: 20),
            _buildLinks(),
          ],
        );
    }
  }

  Widget _buildPeople() {
    final auth = ref.watch(authProvider);
    final direct = _members.where((member) => !member.isInherited);
    final inherited = _members.where((member) => member.isInherited);
    return Column(
      key: const ValueKey('share-people'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(
          label: 'People with access',
          count: _members.length + 1,
        ),
        const SizedBox(height: 6),
        _PersonRow(
          name: auth.displayName,
          isYou: true,
          avatarUrl: auth.avatarUrl,
          subtitle: null,
          trailing: const _OwnerLabel(),
        ),
        for (final member in direct)
          _PersonRow(
            key: ValueKey('share-member-${member.memberId}'),
            name: _memberName(member),
            avatarUrl: member.avatarUrl,
            subtitle: _joinedSubtitle(member),
            trailing: _MemberControls(
              member: member,
              busy: _busyMemberIds.contains(member.memberId),
              onRoleChanged: (role) => _setRole(member, role),
              onRemove: () => _remove(member),
            ),
          ),
        for (final member in inherited)
          _PersonRow(
            key: ValueKey('share-member-${member.memberId}'),
            name: _memberName(member),
            avatarUrl: member.avatarUrl,
            subtitle: 'Through the folder "${member.inheritedFromFolderName}"',
            trailing: _InheritedRoleLabel(role: member.role),
          ),
      ],
    );
  }

  String _joinedSubtitle(ShareMember member) {
    final when = _relativeTime(member.joinedAt);
    final token = member.shareLinkToken;
    if (token == null) {
      return 'Joined $when';
    }
    final link = _links.where((link) => link.token == token).firstOrNull;
    final through = switch (link?.role) {
      'editor' => 'an edit link',
      'viewer' => 'a view link',
      _ => 'a link',
    };
    return 'Joined through $through · $when';
  }

  Widget _buildNewLink(ShadThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel(label: 'New link'),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ShadSelect<String>(
                key: const ValueKey('share-link-role-select'),
                initialValue: _selectedRole,
                selectedOptionBuilder: (context, value) => Text(
                  value == 'editor' ? 'Can edit' : 'View only',
                ),
                options: const [
                  ShadOption(
                    value: 'viewer',
                    child: _RoleOptionLabel(
                      label: 'View only',
                      description: 'Anyone with the link can open every page',
                    ),
                  ),
                  ShadOption(
                    value: 'editor',
                    child: _RoleOptionLabel(
                      label: 'Can edit',
                      description:
                          'Anyone with the link can change pages, drawings, '
                          'and media',
                    ),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedRole = value);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            ShadButton(
              key: const ValueKey('share-link-create-and-copy'),
              onPressed: _isCreating ? null : _createLink,
              leading: _isCreating
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primaryForeground,
                      ),
                    )
                  : const Icon(LucideIcons.link, size: 16),
              child: Text(_isCreating ? 'Creating…' : 'Create & copy'),
            ),
          ],
        ),
        AnimatedSize(
          duration: _stateSwitchDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: _selectedRole == 'editor'
              ? Padding(
                  key: const ValueKey('share-link-edit-warning'),
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(
                          LucideIcons.circleAlert,
                          size: 14,
                          color: theme.colorScheme.mutedForeground,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          ShareLinkCopy.editLinkWarning,
                          style: theme.textTheme.small.copyWith(
                            color: theme.colorScheme.mutedForeground,
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _buildLinks() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(
          label: 'Active links',
          count: _activeLinkCount > 0 ? _activeLinkCount : null,
        ),
        const SizedBox(height: 10),
        if (_links.isEmpty)
          const _LinkListMessage(
            key: ValueKey('empty'),
            icon: LucideIcons.link2,
            message: 'No links yet. Create one above to share it.',
          )
        else
          for (final (index, link) in _links.indexed) ...[
            if (index > 0) const SizedBox(height: 8),
            _ShareLinkTile(
              link: link,
              joinedCount: _joinedThrough(link.token).length,
              isDisabling: _disablingToken == link.token,
              onDisable: () => _disableLink(link.token),
            ),
          ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.count});

  final String label;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Row(
      children: [
        Text(
          label,
          style: theme.textTheme.small.copyWith(
            color: theme.colorScheme.mutedForeground,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 8),
          ShadBadge.secondary(child: Text('$count')),
        ],
      ],
    );
  }
}

class _RoleOptionLabel extends StatelessWidget {
  const _RoleOptionLabel({
    required this.label,
    required this.description,
  });

  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(height: 2),
        Text(
          description,
          style: theme.textTheme.small.copyWith(
            color: theme.colorScheme.mutedForeground,
            fontSize: 11,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.name,
    required this.avatarUrl,
    required this.subtitle,
    required this.trailing,
    this.isYou = false,
  });

  final String name;
  final String? avatarUrl;
  final String? subtitle;
  final Widget trailing;
  final bool isYou;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          AccountAvatar(
            radius: 15,
            backgroundColor: theme.colorScheme.muted,
            avatarUrl: avatarUrl,
            fallback: Text(
              initial,
              style: theme.textTheme.small.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.foreground,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(
                    text: name,
                    children: [
                      if (isYou)
                        TextSpan(
                          text: ' (you)',
                          style: TextStyle(
                            color: theme.colorScheme.mutedForeground,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                    ],
                  ),
                  style: theme.textTheme.small.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.small.copyWith(
                      color: theme.colorScheme.mutedForeground,
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}

class _OwnerLabel extends StatelessWidget {
  const _OwnerLabel();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      // Lines up with the role switches, which sit left of a 32px X.
      padding: const EdgeInsets.only(right: 40),
      child: Text(
        'Owner',
        style: theme.textTheme.small.copyWith(
          color: theme.colorScheme.mutedForeground,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

class _InheritedRoleLabel extends StatelessWidget {
  const _InheritedRoleLabel({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 40),
      child: Text(
        role == 'editor' ? 'Can edit' : 'Can view',
        style: theme.textTheme.small.copyWith(
          color: theme.colorScheme.mutedForeground,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

class _MemberControls extends StatelessWidget {
  const _MemberControls({
    required this.member,
    required this.busy,
    required this.onRoleChanged,
    required this.onRemove,
  });

  final ShareMember member;
  final bool busy;
  final ValueChanged<String> onRoleChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final name = _memberName(member);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShadSelect<String>(
          // Keyed by the role so a reload shows what the server holds.
          key: ValueKey('share-member-role-${member.memberId}-${member.role}'),
          enabled: !busy,
          initialValue: member.role,
          minWidth: 112,
          selectedOptionBuilder: (context, value) => Text(
            value == 'editor' ? 'Can edit' : 'Can view',
          ),
          options: const [
            ShadOption(
              value: 'viewer',
              child: _RoleOptionLabel(
                label: 'Can view',
                description: 'Opens every page, changes nothing',
              ),
            ),
            ShadOption(
              value: 'editor',
              child: _RoleOptionLabel(
                label: 'Can edit',
                description: 'Changes pages, drawings, and media',
              ),
            ),
          ],
          onChanged: (value) {
            if (value != null) onRoleChanged(value);
          },
        ),
        Semantics(
          label: 'Remove $name',
          button: true,
          enabled: !busy,
          onTap: busy ? null : onRemove,
          excludeSemantics: true,
          child: Tooltip(
            message: 'Remove $name',
            child: ShadButton.ghost(
              key: ValueKey('share-member-remove-${member.memberId}'),
              size: ShadButtonSize.sm,
              width: 32,
              padding: EdgeInsets.zero,
              onPressed: busy ? null : onRemove,
              child: busy
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.mutedForeground,
                      ),
                    )
                  : Icon(
                      LucideIcons.x,
                      size: 16,
                      color: theme.colorScheme.mutedForeground,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Confirms disabling a link. Pops null on cancel, otherwise whether to
/// also remove the people who joined through it.
class _DisableLinkDialog extends StatefulWidget {
  const _DisableLinkDialog({required this.joined});

  final List<ShareMember> joined;

  @override
  State<_DisableLinkDialog> createState() => _DisableLinkDialogState();
}

class _DisableLinkDialogState extends State<_DisableLinkDialog> {
  bool _removeJoined = true;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final joined = widget.joined;
    return ShadDialog.alert(
      title: const Text(ShareLinkCopy.disableTitle),
      description: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(ShareLinkCopy.disableDescription),
            if (joined.isNotEmpty) ...[
              const SizedBox(height: 14),
              ShadCheckbox(
                key: const ValueKey('share-link-disable-remove-joined'),
                value: _removeJoined,
                onChanged: (value) => setState(() => _removeJoined = value),
                label: Text(
                  ShareLinkCopy.removeJoinedLabel(joined.length),
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.foreground,
                  ),
                ),
                sublabel: Text(
                  joined.map(_memberName).join(', '),
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.mutedForeground,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        ShadButton.secondary(
          key: const ValueKey('share-link-disable-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton.destructive(
          key: const ValueKey('share-link-disable-confirm'),
          onPressed: () =>
              Navigator.of(context).pop(joined.isNotEmpty && _removeJoined),
          child: const Text(ShareLinkCopy.disableAction),
        ),
      ],
    );
  }
}

class _LinkKindBadge extends StatelessWidget {
  const _LinkKindBadge({required this.role, required this.isRevoked});

  final String role;
  final bool isRevoked;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final Color background;
    final Color foreground;
    final IconData? icon;
    final String label;
    if (isRevoked) {
      background = theme.colorScheme.destructive.withValues(alpha: 0.14);
      foreground = theme.colorScheme.destructive;
      icon = null;
      label = ShareLinkCopy.disabledStatus;
    } else {
      // Neutral for both kinds: violet marks actions, and a badge is not one.
      background = theme.colorScheme.muted;
      foreground = theme.colorScheme.mutedForeground;
      icon = role == 'editor' ? LucideIcons.pencil : LucideIcons.eye;
      label = role == 'editor' ? 'Edit' : 'View';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShareLinkTile extends StatefulWidget {
  const _ShareLinkTile({
    required this.link,
    required this.joinedCount,
    required this.isDisabling,
    required this.onDisable,
  });

  final ShareLinkSummary link;
  final int joinedCount;
  final bool isDisabling;
  final VoidCallback onDisable;

  @override
  State<_ShareLinkTile> createState() => _ShareLinkTileState();
}

class _ShareLinkTileState extends State<_ShareLinkTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final link = widget.link;
    final url = buildIcarusShareLink(link.token, origin: currentShareOrigin());
    final joined =
        widget.joinedCount > 0 ? ' · ${widget.joinedCount} joined' : '';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: _hoverDuration,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: _hovered && !link.isRevoked
                ? theme.colorScheme.ring
                : theme.colorScheme.border,
          ),
          borderRadius: theme.radius,
        ),
        child: AnimatedOpacity(
          duration: _hoverDuration,
          opacity: link.isRevoked ? 0.6 : 1,
          child: Row(
            children: [
              _LinkKindBadge(role: link.role, isRevoked: link.isRevoked),
              const SizedBox(width: 10),
              Expanded(
                child: Tooltip(
                  message: url,
                  waitDuration: const Duration(milliseconds: 400),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectionArea(
                        child: Text(
                          link.token,
                          style: theme.textTheme.small.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.3,
                            decoration: link.isRevoked
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Created ${_relativeTime(link.createdAt)}$joined',
                        style: theme.textTheme.small.copyWith(
                          color: theme.colorScheme.mutedForeground,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _CopyIconButton(
                buttonKey: ValueKey('share-link-copy-link-${link.token}'),
                tooltip: 'Copy link',
                icon: LucideIcons.link,
                enabled: !link.isRevoked,
                textToCopy: url,
                toastMessage: 'Share link copied to clipboard.',
              ),
              _CopyIconButton(
                buttonKey: ValueKey('share-link-copy-code-${link.token}'),
                tooltip: 'Copy code',
                icon: LucideIcons.hash,
                enabled: !link.isRevoked,
                textToCopy: link.token,
                toastMessage: 'Share code copied to clipboard.',
              ),
              Semantics(
                label: link.isRevoked
                    ? ShareLinkCopy.disabledTooltip
                    : ShareLinkCopy.disableTooltip,
                button: true,
                enabled: !link.isRevoked && !widget.isDisabling,
                onTap: link.isRevoked || widget.isDisabling
                    ? null
                    : widget.onDisable,
                excludeSemantics: true,
                child: Tooltip(
                  message: link.isRevoked
                      ? ShareLinkCopy.disabledTooltip
                      : ShareLinkCopy.disableTooltip,
                  child: ShadButton.ghost(
                    key: ValueKey('share-link-disable-${link.token}'),
                    size: ShadButtonSize.sm,
                    onPressed: link.isRevoked || widget.isDisabling
                        ? null
                        : widget.onDisable,
                    child: widget.isDisabling
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.mutedForeground,
                            ),
                          )
                        : Icon(
                            LucideIcons.link2Off,
                            size: 16,
                            color: link.isRevoked
                                ? theme.colorScheme.mutedForeground
                                : theme.colorScheme.destructive,
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyIconButton extends StatefulWidget {
  const _CopyIconButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.enabled,
    required this.textToCopy,
    required this.toastMessage,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final bool enabled;
  final String textToCopy;
  final String toastMessage;

  @override
  State<_CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<_CopyIconButton> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.textToCopy));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(_copiedFlashDuration, () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
    Settings.showToast(
      message: widget.toastMessage,
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Semantics(
      label: widget.tooltip,
      button: true,
      enabled: widget.enabled,
      onTap: widget.enabled ? _copy : null,
      excludeSemantics: true,
      child: Tooltip(
        message: widget.tooltip,
        child: ShadButton.ghost(
          key: widget.buttonKey,
          size: ShadButtonSize.sm,
          onPressed: widget.enabled ? _copy : null,
          child: AnimatedSwitcher(
            duration: _hoverDuration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: _copied
                ? Icon(
                    LucideIcons.check,
                    key: const ValueKey('check'),
                    size: 16,
                    color: theme.colorScheme.primary,
                  )
                : Icon(
                    widget.icon,
                    key: const ValueKey('idle'),
                    size: 16,
                    color: widget.enabled
                        ? theme.colorScheme.foreground
                        : theme.colorScheme.mutedForeground,
                  ),
          ),
        ),
      ),
    );
  }
}

class _LinkListMessage extends StatelessWidget {
  const _LinkListMessage({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.mutedForeground),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.textTheme.muted,
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            action!,
          ],
        ],
      ),
    );
  }
}

class _LinkListPlaceholder extends StatefulWidget {
  const _LinkListPlaceholder({super.key});

  @override
  State<_LinkListPlaceholder> createState() => _LinkListPlaceholderState();
}

class _LinkListPlaceholderState extends State<_LinkListPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 0.9).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Column(
        children: [
          for (var i = 0; i < 2; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            Container(
              height: 54,
              decoration: BoxDecoration(
                color: theme.colorScheme.muted.withValues(alpha: 0.4),
                borderRadius: theme.radius,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class AddSharedItemDialog extends ConsumerStatefulWidget {
  const AddSharedItemDialog({super.key});

  @override
  ConsumerState<AddSharedItemDialog> createState() =>
      _AddSharedItemDialogState();
}

class _AddSharedItemDialogState extends ConsumerState<AddSharedItemDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) {
      return;
    }
    final token = extractIcarusShareCode(
      _controller.text,
      currentOrigin: currentShareOrigin(),
    );
    if (token == null || token.isEmpty) {
      setState(() {
        _errorText = _controller.text.trim().isEmpty
            ? 'Paste a share link or code first.'
            : "That doesn't look like an Icarus share link or code.";
      });
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    final succeeded =
        await ref.read(shareLinkControllerProvider.notifier).redeemToken(token);
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (succeeded) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _errorText = "Couldn't add that item. The link may be revoked, "
            'or you may need to sign in.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final hasError = _errorText != null;

    return ShadDialog(
      title: const Text('Add Shared Item'),
      description: const Text(
        'Paste an Icarus share link or enter a share code to add it to '
        'Shared with Me.',
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: _isSubmitting ? null : _submit,
          leading: _isSubmitting
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primaryForeground,
                  ),
                )
              : null,
          child: Text(_isSubmitting ? 'Adding…' : 'Add'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextEditingShortcutScope(
            child: ShadInput(
              controller: _controller,
              autofocus: true,
              placeholder: Text(
                '${currentShareOrigin()}/share/… or ICR-XXXX-XXXX-XXXX-XXXX',
              ),
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_errorText != null) {
                  setState(() => _errorText = null);
                }
              },
              decoration: hasError
                  ? ShadDecoration(
                      border: ShadBorder.all(
                        color: theme.colorScheme.destructive,
                      ),
                    )
                  : null,
            ),
          ),
          AnimatedSize(
            duration: _stateSwitchDuration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: hasError
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          LucideIcons.circleAlert,
                          size: 13,
                          color: theme.colorScheme.destructive,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _errorText!,
                            style: theme.textTheme.small.copyWith(
                              color: theme.colorScheme.destructive,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// Whether the library is showing the top of Shared, where everything was
/// shared with the user directly and so can be left. Items inside a shared
/// folder come with the folder; leaving the folder is what ends them.
bool isAtSharedRoot(WidgetRef ref) =>
    ref.watch(libraryWorkspaceProvider) == LibraryWorkspace.cloud &&
    ref.watch(cloudLibrarySectionProvider) ==
        CloudLibrarySection.sharedWithMe &&
    ref.watch(folderProvider) == null;

/// Asks, then ends the user's own access to a strategy or folder shared
/// with them. The item leaves Shared on its own: the list is live.
Future<void> leaveSharedItem({
  required BuildContext context,
  required WidgetRef ref,
  required String targetType,
  required String targetPublicId,
  required String name,
}) async {
  final confirmed = await ConfirmAlertDialog.show(
    context: context,
    title: 'Leave "${name.replaceAll('"', "'")}"?',
    content: 'You lose access, and it leaves your Shared tab. You can only '
        'get it back through a link from its owner.',
    confirmText: 'Leave',
    isDestructive: true,
  );
  if (!confirmed) return;
  try {
    await ref.read(convexStrategyRepositoryProvider).leaveShared(
          targetType: targetType,
          targetPublicId: targetPublicId,
        );
  } catch (_) {
    Settings.showToast(
      message: "Couldn't leave it. Check your connection and try again.",
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }
}
