import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/services/browser_url.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/widgets/strip_status_icons.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// What the user is told while the server refuses this build, and the one
/// action that can help, if there is one. The web reloads into the build
/// being served. Desktop installs the waiting update (the one the strip's
/// update icon opens); while none is known it says so and offers to check
/// again, which also asks the server whether it accepts this build again.
class ClientUpgradeNotice extends StatelessWidget {
  const ClientUpgradeNotice({
    super.key,
    required this.builder,
    this.buttonSize,
    this.isWeb = kIsWeb,
    this.onReload = reloadBrowserPage,
  });

  final Widget Function(BuildContext context, String message, Widget? action)
      builder;
  final ShadButtonSize? buttonSize;
  final bool isWeb;

  /// Loads the page again; replaced in tests.
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    if (isWeb) {
      return builder(
        context,
        clientUpgradeRequiredMessage(isWeb: true),
        _ReloadButton(size: buttonSize, onReload: onReload),
      );
    }
    return WaitingUpdateBuilder(
      builder: (context, openUpdate, isChecking) {
        if (openUpdate != null) {
          return builder(
            context,
            clientUpgradeRequiredMessage(isWeb: false),
            _button(
              icon: LucideIcons.download,
              label: 'Update',
              size: buttonSize,
              onPressed: openUpdate,
            ),
          );
        }
        return builder(
          context,
          clientUpgradeRequiredMessage(
            isWeb: false,
            update: isChecking
                ? ClientUpdateAvailability.checking
                : ClientUpdateAvailability.unavailable,
          ),
          isChecking ? null : _CheckAgainButton(size: buttonSize),
        );
      },
    );
  }
}

/// Reloading throws the page away, as leaving the strategy does, so it goes
/// through the same guard as Home: it saves what it can, and asks before
/// leaving anything it could not confirm is kept on this device.
class _ReloadButton extends ConsumerStatefulWidget {
  const _ReloadButton({required this.size, required this.onReload});

  final ShadButtonSize? size;
  final VoidCallback onReload;

  @override
  ConsumerState<_ReloadButton> createState() => _ReloadButtonState();
}

class _ReloadButtonState extends ConsumerState<_ReloadButton> {
  bool _leaving = false;

  Future<void> _reload() async {
    setState(() => _leaving = true);
    await guardUnsavedStrategyExit(
      context: context,
      ref: ref,
      onContinue: () async => widget.onReload(),
      source: 'client_upgrade.reload',
    );
    if (mounted) setState(() => _leaving = false);
  }

  @override
  Widget build(BuildContext context) {
    return _button(
      icon: LucideIcons.refreshCw,
      label: 'Reload',
      size: widget.size,
      onPressed: _leaving ? null : _reload,
    );
  }
}

class _CheckAgainButton extends ConsumerWidget {
  const _CheckAgainButton({required this.size});

  final ShadButtonSize? size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _button(
      icon: LucideIcons.refreshCw,
      label: 'Check again',
      size: size,
      onPressed: () {
        ref.invalidate(appUpdateStatusProvider);
        ref.read(clientUpgradeRequiredProvider.notifier).recheck();
      },
    );
  }
}

Widget _button({
  required IconData icon,
  required String label,
  required ShadButtonSize? size,
  required VoidCallback? onPressed,
}) {
  return ShadButton(
    key: const ValueKey('client-upgrade-button'),
    size: size,
    expands: false,
    leading: Icon(icon, size: 16),
    onPressed: onPressed,
    child: Text(label),
  );
}
