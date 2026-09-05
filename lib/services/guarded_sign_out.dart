import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
        title: const Text("Can't sign out yet"),
        description: const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'Icarus could not verify pending cloud work. Stay signed in and '
            'try again.',
          ),
        ),
        actions: [
          ShadButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Stay Signed In'),
          ),
        ],
      ),
    );
    return false;
  },
);
