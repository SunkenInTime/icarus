import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Covers the editor on an upright phone, which is too narrow to place
/// anything on a map that's bound by height. The editor stays alive under
/// it, so turning the phone picks up exactly where it was.
///
/// The app's shortcuts sit above every screen, so a keyboard attached to the
/// phone would reach the editor from anywhere. Keys stop here instead: nobody
/// should delete what they can't see.
class TurnPhoneNotice extends StatefulWidget {
  const TurnPhoneNotice({super.key, required this.onLeave, this.backTooltip});

  final VoidCallback onLeave;

  /// Where leaving goes when it isn't the library.
  final String? backTooltip;

  @override
  State<TurnPhoneNotice> createState() => _TurnPhoneNoticeState();
}

class _TurnPhoneNoticeState extends State<TurnPhoneNotice> {
  final _focusNode = FocusNode(debugLabel: 'turn-phone-notice');

  /// What it takes to reach the button and press it.
  static final _keysToLeave = {
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Also runs when a dialog over the editor closes, and focus comes back.
    if (ModalRoute.isCurrentOf(context) ?? true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _keepFromEditor(FocusNode node, KeyEvent event) {
    return _keysToLeave.contains(event.logicalKey)
        ? KeyEventResult.ignored
        : KeyEventResult.skipRemainingHandlers;
  }

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _keepFromEditor,
      child: ColoredBox(
        key: const ValueKey('turn-phone-notice'),
        color: theme.background,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.smartphone,
                    size: 38,
                    color: theme.mutedForeground,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Turn your phone sideways to edit',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'If nothing happens, check that rotation lock is off.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.mutedForeground),
                  ),
                  const SizedBox(height: 16),
                  ShadButton.secondary(
                    key: const ValueKey('turn-phone-leave'),
                    onPressed: widget.onLeave,
                    child: Text(widget.backTooltip ?? 'Back to My Library'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
