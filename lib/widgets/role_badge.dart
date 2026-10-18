import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// What the cloud says about a strategy's place in the library: yours, shared
/// with edit access, or shared read-only.
enum CloudBadgeKind { owned, editor, viewer }

CloudBadgeKind? cloudBadgeKindForRole(String? role) {
  switch (role) {
    case 'owner':
      return CloudBadgeKind.owned;
    case 'editor':
      return CloudBadgeKind.editor;
    case 'viewer':
      return CloudBadgeKind.viewer;
    default:
      // Unknown non-null roles fall back to the viewer badge. This mirrors
      // StrategyCapabilities.fromCloudRole (strategy_capabilities_provider),
      // which grants viewer capabilities to any role that is not exactly
      // 'owner' or 'editor' — so the badge matches what the user can actually
      // do, and shared items are never mistaken for owned ones.
      return role == null ? null : CloudBadgeKind.viewer;
  }
}

/// The pill drawn over a strategy thumbnail to say where it lives or how it
/// was shared. Owned cloud strategies are the ordinary case in a signed-in
/// library, so they carry no badge; only the exceptions get one.
class StrategyBadge extends StatelessWidget {
  const StrategyBadge({
    super.key,
    required IconData this.icon,
    required this.label,
    required this.tooltip,
  }) : leading = null;

  /// A badge led by [leading] in place of an icon.
  const StrategyBadge.leading({
    super.key,
    required Widget this.leading,
    required this.label,
    required this.tooltip,
  }) : icon = null;

  final IconData? icon;
  final Widget? leading;
  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.background.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: theme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading ?? Icon(icon, size: 12, color: theme.foreground),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "On this device": the strategy exists only in the local library.
class DeviceOnlyBadge extends StatelessWidget {
  const DeviceOnlyBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return const StrategyBadge(
      icon: LucideIcons.monitor,
      label: 'On this device',
      tooltip: 'Saved only on this computer',
    );
  }
}

/// A cloud strategy that can't be opened while offline: this computer keeps
/// no copy of it yet.
class NeedsConnectionBadge extends StatelessWidget {
  const NeedsConnectionBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return const StrategyBadge(
      icon: LucideIcons.cloudOff,
      label: 'Needs a connection',
      tooltip: 'Needs a connection the first time you open it',
    );
  }
}

/// How opaque a strategy or folder is while it moves to the cloud: still
/// readable, plainly not available.
const double movingToCloudOpacity = 0.45;

/// A strategy on its way from this device to the cloud.
class MovingToCloudBadge extends StatelessWidget {
  const MovingToCloudBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return StrategyBadge.leading(
      leading: SizedBox.square(
        dimension: 10,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: Settings.tacticalVioletTheme.foreground,
        ),
      ),
      label: 'Moving to cloud',
      tooltip: 'Stays on this computer until all of it is in the cloud',
    );
  }
}

/// The share role of a strategy someone else owns. Null for owned strategies.
class CloudRoleBadge extends StatelessWidget {
  const CloudRoleBadge({super.key, required this.kind});

  final CloudBadgeKind kind;

  @override
  Widget build(BuildContext context) {
    switch (kind) {
      case CloudBadgeKind.owned:
        return const SizedBox.shrink();
      case CloudBadgeKind.editor:
        return const StrategyBadge(
          icon: LucideIcons.users,
          label: 'Shared · Can edit',
          tooltip: 'Shared with you. You can edit it.',
        );
      case CloudBadgeKind.viewer:
        return const StrategyBadge(
          icon: LucideIcons.users,
          label: 'Shared · View only',
          tooltip: 'Shared with you. Ask the owner for edit access.',
        );
    }
  }
}
