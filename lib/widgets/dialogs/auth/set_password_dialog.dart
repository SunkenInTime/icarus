import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Asks for a new password after a password reset link signed the user in.
/// The user is already signed in, so "Not now" keeps them signed in with
/// their old password, or none if the account was made with Discord.
class SetPasswordDialog extends ConsumerStatefulWidget {
  const SetPasswordDialog({super.key});

  @override
  ConsumerState<SetPasswordDialog> createState() => _SetPasswordDialogState();
}

class _SetPasswordDialogState extends ConsumerState<SetPasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  final FocusNode _passwordFocusNode = FocusNode();
  final FocusNode _confirmFocusNode = FocusNode();
  bool _saving = false;
  String? _error;
  bool _confirmHasError = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    _passwordFocusNode.dispose();
    _confirmFocusNode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final password = _passwordController.text;
    if (password.length < 6) {
      setState(() {
        _error = 'Password must be at least 6 characters.';
        _confirmHasError = false;
      });
      return;
    }
    if (password != _confirmController.text) {
      setState(() {
        _error = 'Passwords do not match.';
        _confirmHasError = true;
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _confirmHasError = false;
    });
    final error =
        await ref.read(authProvider.notifier).setNewPassword(password);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error;
      });
      return;
    }

    Navigator.of(context).pop();
    Settings.showToast(
      message: 'Password saved. Sign in with your email and this password '
          'from now on.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }

  @override
  Widget build(BuildContext context) {
    final email = ref.watch(authProvider.select((state) => state.user?.email));

    return ShadDialog(
      title: const Text('Set a new password'),
      description: Text(
        email == null
            ? 'Choose the password you will sign in with.'
            : "You're signed in as $email. Choose the password you will "
                'sign in with.',
      ),
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CustomTextField(
              key: const ValueKey('set-password-field'),
              controller: _passwordController,
              focusNode: _passwordFocusNode,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              hintText: 'New password',
              textInputAction: TextInputAction.next,
              hasError: _error != null && !_confirmHasError,
            ),
            const SizedBox(height: 10),
            CustomTextField(
              key: const ValueKey('set-password-confirm-field'),
              controller: _confirmController,
              focusNode: _confirmFocusNode,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              hintText: 'Confirm new password',
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              hasError: _confirmHasError,
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AuthMessageBanner(message: _error!, isInfo: false),
              ),
            Row(
              children: [
                Expanded(
                  child: ShadButton.secondary(
                    key: const ValueKey('set-password-not-now'),
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ShadButton(
                    key: const ValueKey('set-password-save'),
                    onPressed: _saving ? null : _save,
                    leading: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    child: Text(_saving ? 'Saving…' : 'Save password'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
