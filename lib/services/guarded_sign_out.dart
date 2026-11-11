import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

typedef GuardedSignOutRequest = Future<bool> Function(BuildContext context);

/// The app shell replaces this with the cloud-aware implementation.
///
/// Keeping the default fail-closed lets auth UI depend on one contract without
/// introducing a provider import cycle through the editor state.
final guardedSignOutRequestProvider = Provider<GuardedSignOutRequest>(
  (ref) => (context) async {
    await showShadDialog<void>(
      context: context,
      builder: (context) => ShadDialog.alert(
        title: Text(context.l10n.signOutGuardCantSignOutTitle),
        description: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(context.l10n.signOutGuardUnverifiedDescription),
        ),
        actions: [
          ShadButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.signOutGuardStaySignedIn),
          ),
        ],
      ),
    );
    return false;
  },
);
