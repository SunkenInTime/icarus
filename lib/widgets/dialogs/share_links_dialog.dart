import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/share/share_link_format.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
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

enum _LinksStatus { loading, error, ready }

class _ShareLinksDialogState extends ConsumerState<ShareLinksDialog> {
  List<ShareLinkSummary> _links = const [];
  _LinksStatus _status = _LinksStatus.loading;
  bool _isCreating = false;
  String? _revokingToken;
  String _selectedRole = 'viewer';

  Future<void> _loadLinks() async {
    setState(() => _status = _LinksStatus.loading);
    try {
      final links =
          await ref.read(convexStrategyRepositoryProvider).listShareLinks(
                targetType: widget.targetType,
                targetPublicId: widget.targetPublicId,
              );
      if (!mounted) return;
      setState(() {
        _links = links;
        _status = _LinksStatus.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = _LinksStatus.error);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  Future<void> _createLink() async {
    setState(() => _isCreating = true);
    final token = generateIcarusShareCode();
    try {
      await ref.read(convexStrategyRepositoryProvider).createShareLink(
            targetType: widget.targetType,
            targetPublicId: widget.targetPublicId,
            token: token,
            role: _selectedRole,
          );
      await Clipboard.setData(ClipboardData(text: buildIcarusShareLink(token)));
      Settings.showToast(
        message: 'Share link copied to clipboard.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
      await _loadLinks();
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

  Future<void> _revokeLink(String token) async {
    final confirmed = await ConfirmAlertDialog.show(
      context: context,
      title: 'Revoke this link?',
      content: 'Anyone who has the link or code loses the ability to join. '
          'People who already joined keep their access.',
      confirmText: 'Revoke',
      isDestructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _revokingToken = token);
    try {
      await ref.read(convexStrategyRepositoryProvider).revokeShareLink(
            targetType: widget.targetType,
            targetPublicId: widget.targetPublicId,
            token: token,
          );
      await _loadLinks();
    } catch (_) {
      Settings.showToast(
        message: 'Failed to revoke share link.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } finally {
      if (mounted) {
        setState(() => _revokingToken = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadDialog(
      title: Text(
        _shareDialogHeadline(widget.title),
        softWrap: true,
      ),
      description: const Text(
        'Links never expire. Anyone who opens one joins this item with the '
        'access you choose.',
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
      child: SizedBox(
        width: double.infinity,
        child: Column(
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
                    initialValue: _selectedRole,
                    selectedOptionBuilder: (context, value) => Text(
                      value == 'editor' ? 'Can edit' : 'View only',
                    ),
                    options: const [
                      ShadOption(
                        value: 'viewer',
                        child: _RoleOptionLabel(
                          label: 'View only',
                          description: 'Can open and view every page',
                        ),
                      ),
                      ShadOption(
                        value: 'editor',
                        child: _RoleOptionLabel(
                          label: 'Can edit',
                          description: 'Can change pages, drawings, and media',
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
            const SizedBox(height: 20),
            Row(
              children: [
                const _SectionLabel(label: 'Active links'),
                if (_status == _LinksStatus.ready && _links.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  ShadBadge.secondary(
                    child: Text('${_links.length}'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            AnimatedSize(
              duration: _stateSwitchDuration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: _stateSwitchDuration,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                child: _buildLinksBody(theme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLinksBody(ShadThemeData theme) {
    switch (_status) {
      case _LinksStatus.loading:
        return const _LinkListPlaceholder(key: ValueKey('loading'));
      case _LinksStatus.error:
        return _LinkListMessage(
          key: const ValueKey('error'),
          icon: LucideIcons.circleAlert,
          message: "Couldn't load share links.",
          action: ShadButton.ghost(
            size: ShadButtonSize.sm,
            onPressed: _loadLinks,
            leading: const Icon(LucideIcons.refreshCw, size: 14),
            child: const Text('Retry'),
          ),
        );
      case _LinksStatus.ready:
        if (_links.isEmpty) {
          return const _LinkListMessage(
            key: ValueKey('empty'),
            icon: LucideIcons.link2,
            message: 'No links yet. Create one above to invite collaborators.',
          );
        }
        return ConstrainedBox(
          key: const ValueKey('links'),
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _links.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final link = _links[index];
              return _ShareLinkTile(
                link: link,
                isRevoking: _revokingToken == link.token,
                onRevoke: () => _revokeLink(link.token),
              );
            },
          ),
        );
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Text(
      label,
      style: theme.textTheme.small.copyWith(
        color: theme.colorScheme.mutedForeground,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
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

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role, required this.isRevoked});

  final String role;
  final bool isRevoked;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final Color background;
    final Color foreground;
    final String label;
    if (isRevoked) {
      background = theme.colorScheme.destructive.withValues(alpha: 0.14);
      foreground = theme.colorScheme.destructive;
      label = 'REVOKED';
    } else if (role == 'editor') {
      background = theme.colorScheme.primary.withValues(alpha: 0.16);
      foreground = theme.colorScheme.primary;
      label = 'EDIT';
    } else {
      background = theme.colorScheme.muted;
      foreground = theme.colorScheme.mutedForeground;
      label = 'VIEW';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ShareLinkTile extends StatefulWidget {
  const _ShareLinkTile({
    required this.link,
    required this.isRevoking,
    required this.onRevoke,
  });

  final ShareLinkSummary link;
  final bool isRevoking;
  final VoidCallback onRevoke;

  @override
  State<_ShareLinkTile> createState() => _ShareLinkTileState();
}

class _ShareLinkTileState extends State<_ShareLinkTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final link = widget.link;
    final url = buildIcarusShareLink(link.token);

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
              _RoleBadge(role: link.role, isRevoked: link.isRevoked),
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
                        'Created ${_relativeTime(link.createdAt)}',
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
                tooltip: 'Copy link',
                icon: LucideIcons.link,
                enabled: !link.isRevoked,
                textToCopy: url,
                toastMessage: 'Share link copied to clipboard.',
              ),
              _CopyIconButton(
                tooltip: 'Copy code',
                icon: LucideIcons.hash,
                enabled: !link.isRevoked,
                textToCopy: link.token,
                toastMessage: 'Share code copied to clipboard.',
              ),
              Tooltip(
                message: link.isRevoked ? 'Revoked' : 'Revoke link',
                child: ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: link.isRevoked || widget.isRevoking
                      ? null
                      : widget.onRevoke,
                  child: widget.isRevoking
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.mutedForeground,
                          ),
                        )
                      : Icon(
                          LucideIcons.trash2,
                          size: 16,
                          color: link.isRevoked
                              ? theme.colorScheme.mutedForeground
                              : theme.colorScheme.destructive,
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
    required this.tooltip,
    required this.icon,
    required this.enabled,
    required this.textToCopy,
    required this.toastMessage,
  });

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
    return Tooltip(
      message: widget.tooltip,
      child: ShadButton.ghost(
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
    final token = extractIcarusShareCode(_controller.text);
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
          ShadInput(
            controller: _controller,
            autofocus: true,
            placeholder: const Text(
              'https://$icarusShareHost/share/… or ICR-XXXX-XXXX-XXXX-XXXX',
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
