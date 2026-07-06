import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';

/// Small uppercase micro badges used to mark cloud ownership and share role.
///
/// Styling follows the Icarus design system: 10px, w600, 0.5 letter spacing,
/// uppercase text on a tinted pill. Colors come only from the tactical theme
/// tokens (no hardcoded Material colors).
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
      // Unknown role: treat as viewer so shared items are never mistaken for
      // owned ones.
      return role == null ? null : CloudBadgeKind.viewer;
  }
}

class CloudRoleBadge extends StatelessWidget {
  const CloudRoleBadge({super.key, required this.kind});

  final CloudBadgeKind kind;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;

    switch (kind) {
      case CloudBadgeKind.owned:
        // Owned cloud strategies: a muted cloud glyph pill, deliberately quiet.
        return _BadgePill(
          background: theme.muted,
          border: theme.border,
          child: Icon(
            Icons.cloud_outlined,
            size: 12,
            color: theme.mutedForeground,
          ),
        );
      case CloudBadgeKind.editor:
        // Shared with edit access: violet tint to echo the "action" accent.
        return _BadgePill(
          background: theme.primary.withValues(alpha: 0.16),
          border: theme.primary.withValues(alpha: 0.32),
          child: _BadgeLabel(text: 'EDIT', color: theme.primary),
        );
      case CloudBadgeKind.viewer:
        // Shared read-only: muted, no command color.
        return _BadgePill(
          background: theme.muted,
          border: theme.border,
          child: _BadgeLabel(text: 'VIEW', color: theme.mutedForeground),
        );
    }
  }
}

class _BadgePill extends StatelessWidget {
  const _BadgePill({
    required this.background,
    required this.border,
    required this.child,
  });

  final Color background;
  final Color border;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: child,
    );
  }
}

class _BadgeLabel extends StatelessWidget {
  const _BadgeLabel({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        height: 1.2,
      ),
    );
  }
}
