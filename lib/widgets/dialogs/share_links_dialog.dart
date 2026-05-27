import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

String buildIcarusShareLink(String token) => 'icarus://share?token=$token';

/// Headline like: Share "My Strategy Name" (`"` in [name] become `'`).
String _shareDialogHeadline(String name) {
  final safe = name.replaceAll('"', "'");
  return 'Share "$safe"';
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

class _ShareLinksDialogState extends ConsumerState<ShareLinksDialog> {
  List<ShareLinkSummary> _links = const [];
  bool _isLoading = true;
  bool _isCreating = false;
  String _selectedRole = 'viewer';

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  Future<void> _loadLinks() async {
    setState(() => _isLoading = true);
    try {
      final links =
          await ref.read(convexStrategyRepositoryProvider).listShareLinks(
                targetType: widget.targetType,
                targetPublicId: widget.targetPublicId,
              );
      if (!mounted) return;
      setState(() {
        _links = links;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      Settings.showToast(
        message: 'Failed to load share links.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  Future<void> _createLink() async {
    setState(() => _isCreating = true);
    final token = const Uuid().v4();
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

  Future<void> _copyLink(String token) async {
    await Clipboard.setData(ClipboardData(text: buildIcarusShareLink(token)));
    Settings.showToast(
      message: 'Share link copied to clipboard.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }

  Future<void> _revokeLink(String token) async {
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
        'Links never expire. Anyone who opens one can join this item in your cloud library with the access you choose.',
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
            Text(
              'New link',
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 8),
            ShadSelect<String>(
              initialValue: _selectedRole,
              selectedOptionBuilder: (context, value) => Text(
                value == 'editor' ? 'Can edit' : 'View only',
              ),
              options: const [
                ShadOption(value: 'viewer', child: Text('View only')),
                ShadOption(value: 'editor', child: Text('Can edit')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedRole = value);
                }
              },
            ),
            const SizedBox(height: 12),
            ShadButton(
              onPressed: _isCreating ? null : _createLink,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.copy,
                    size: 16,
                    color: theme.colorScheme.primaryForeground,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isCreating ? 'Creating…' : 'Create link & copy',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Text(
                  'Active links',
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.mutedForeground,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                if (!_isLoading && _links.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  ShadBadge.secondary(
                    child: Text('${_links.length}'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_links.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'No links yet. Create one above to invite collaborators.',
                  style: theme.textTheme.muted,
                  textAlign: TextAlign.center,
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _links.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final link = _links[index];
                    final url = buildIcarusShareLink(link.token);
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: theme.colorScheme.border),
                        borderRadius: theme.radius,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Tooltip(
                                message: url,
                                child: SelectionArea(
                                  child: Text(
                                    url,
                                    style: theme.textTheme.small.copyWith(
                                      color: theme.colorScheme.mutedForeground,
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      height: 1.35,
                                    ),
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    softWrap: true,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Tooltip(
                                  message: 'Copy link',
                                  child: ShadButton.ghost(
                                    size: ShadButtonSize.sm,
                                    onPressed: () => _copyLink(link.token),
                                    child: Icon(
                                      LucideIcons.copy,
                                      size: 16,
                                      color: theme.colorScheme.foreground,
                                    ),
                                  ),
                                ),
                                Tooltip(
                                  message: link.isRevoked
                                      ? 'Revoked'
                                      : 'Revoke link',
                                  child: ShadButton.ghost(
                                    size: ShadButtonSize.sm,
                                    onPressed: link.isRevoked
                                        ? null
                                        : () => _revokeLink(link.token),
                                    child: Icon(
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
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class JoinShareLinkDialog extends ConsumerStatefulWidget {
  const JoinShareLinkDialog({super.key});

  @override
  ConsumerState<JoinShareLinkDialog> createState() =>
      _JoinShareLinkDialogState();
}

class _JoinShareLinkDialogState extends ConsumerState<JoinShareLinkDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _extractToken(String value) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null) {
      return uri.queryParameters['token'] ?? trimmed;
    }
    return trimmed;
  }

  Future<void> _submit() async {
    final token = _extractToken(_controller.text);
    if (token.isEmpty) {
      return;
    }
    setState(() => _isSubmitting = true);
    await ref.read(shareLinkControllerProvider.notifier).redeemToken(token);
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('Join Shared Item'),
      description: const Text(
          'Paste an Icarus share link to add it to your cloud library.'),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: _isSubmitting ? null : _submit,
          child: Text(_isSubmitting ? 'Joining...' : 'Join'),
        ),
      ],
      child: ShadInput(
        controller: _controller,
        placeholder: const Text('icarus://share?token=...'),
      ),
    );
  }
}
