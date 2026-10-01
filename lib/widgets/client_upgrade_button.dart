import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:icarus/services/browser_url.dart';
import 'package:icarus/widgets/strip_status_icons.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The way out when the server needs a newer Icarus. The web reloads into the
/// build being served; a desktop install opens its waiting update, as the
/// strip's update icon does, and shows nothing while no update is known.
class ClientUpgradeButton extends StatelessWidget {
  const ClientUpgradeButton({super.key, this.size, this.isWeb = kIsWeb});

  final ShadButtonSize? size;
  final bool isWeb;

  @override
  Widget build(BuildContext context) {
    if (isWeb) {
      return _button(
        icon: LucideIcons.refreshCw,
        label: 'Reload',
        onPressed: reloadBrowserPage,
      );
    }
    return WaitingUpdateBuilder(
      builder: (context, openUpdate) => openUpdate == null
          ? const SizedBox.shrink()
          : _button(
              icon: LucideIcons.download,
              label: 'Update',
              onPressed: openUpdate,
            ),
    );
  }

  Widget _button({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return ShadButton(
      key: const ValueKey('client-upgrade-button'),
      size: size,
      expands: false,
      leading: Icon(icon, size: 14),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}
