import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum AuthDialogMode { signIn, signUp }

enum _AuthView { signIn, signUp, resetPassword }

enum _AuthField { email, password, confirm }

const _bannerDuration = Duration(milliseconds: 180);

class AuthDialog extends ConsumerStatefulWidget {
  const AuthDialog({
    super.key,
    this.initialMode = AuthDialogMode.signIn,
  });

  final AuthDialogMode initialMode;

  @override
  ConsumerState<AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends ConsumerState<AuthDialog> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  final FocusNode _confirmFocusNode = FocusNode();
  bool _submitting = false;
  late _AuthView _view;
  bool _waitingForDiscord = false;
  String? _message;
  bool _messageIsInfo = false;
  _AuthField? _errorField;

  @override
  void initState() {
    super.initState();
    _view = widget.initialMode == AuthDialogMode.signUp
        ? _AuthView.signUp
        : _AuthView.signIn;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmFocusNode.dispose();
    super.dispose();
  }

  void _setValidationError(String message, _AuthField field) {
    setState(() {
      _message = message;
      _messageIsInfo = false;
      _errorField = field;
    });
  }

  bool get _isSignUp => _view == _AuthView.signUp;

  void _showView(_AuthView view) {
    setState(() {
      _view = view;
      _message = null;
      _messageIsInfo = false;
      _errorField = null;
    });
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (email.isEmpty || !email.contains('@')) {
      _setValidationError('Enter a valid email address.', _AuthField.email);
      return;
    }

    if (_view == _AuthView.resetPassword) {
      await _sendPasswordReset(email);
      return;
    }

    if (password.length < 6) {
      _setValidationError(
        'Password must be at least 6 characters.',
        _AuthField.password,
      );
      return;
    }

    if (_isSignUp && password != confirm) {
      _setValidationError('Passwords do not match.', _AuthField.confirm);
      return;
    }

    setState(() {
      _submitting = true;
      _message = null;
      _messageIsInfo = false;
      _errorField = null;
    });

    final notifier = ref.read(authProvider.notifier);
    final error = _isSignUp
        ? await notifier.signUpWithEmailPassword(
            email: email, password: password)
        : await notifier.signInWithEmailPassword(
            email: email, password: password);

    if (!mounted) return;

    // On success the sign-in lands in the auth state, which closes this
    // dialog; closing it here too would also close the route beneath.
    setState(() {
      _submitting = false;
      _message = error;
      // The "account created" outcome comes back through the error channel
      // but is good news — present it as info, not failure.
      _messageIsInfo = error != null && error.startsWith('Account created');
    });
  }

  Future<void> _sendPasswordReset(String email) async {
    setState(() {
      _submitting = true;
      _message = null;
      _messageIsInfo = false;
      _errorField = null;
    });
    final result =
        await ref.read(authProvider.notifier).sendPasswordReset(email);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _message = result.message;
      _messageIsInfo = result.sent;
    });
  }

  void _startDiscordSignIn() {
    setState(() {
      _waitingForDiscord = true;
      _message = null;
      _messageIsInfo = false;
      _errorField = null;
    });
    unawaited(ref.read(authProvider.notifier).signInWithDiscord());
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final busy = _submitting || authState.isLoading;

    // This is the one place the dialog closes: once a session lands, from
    // the password form here or from a Discord or reset link coming back
    // through the browser. A Discord failure drops the pending state.
    ref.listen(authProvider, (previous, next) {
      if (next.isAuthenticated && previous?.isAuthenticated != true) {
        Navigator.of(context).pop(true);
        return;
      }
      if (!_waitingForDiscord) {
        return;
      }
      if (next.errorMessage != null &&
          next.errorMessage != previous?.errorMessage) {
        setState(() {
          _waitingForDiscord = false;
          _message = next.errorMessage;
          _messageIsInfo = false;
        });
      }
    });

    final resetting = _view == _AuthView.resetPassword;
    final theme = ShadTheme.of(context);

    return ShadDialog(
      title: Text(switch (_view) {
        _AuthView.signIn => 'Sign in',
        _AuthView.signUp => 'Create account',
        _AuthView.resetPassword => 'Reset password',
      }),
      description: Text(switch (_view) {
        _AuthView.signIn => 'Sign in with email and password.',
        _AuthView.signUp => 'Use email and password to create an account.',
        _AuthView.resetPassword =>
          "Enter your account's email and we'll send a link to set a new "
              'password. It works for accounts made with Discord too.',
      }),
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CustomTextField(
              key: const ValueKey('auth-email-field'),
              controller: _emailController,
              focusNode: _emailFocusNode,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              hintText: 'Email',
              textInputAction:
                  resetting ? TextInputAction.done : TextInputAction.next,
              onSubmitted: resetting ? (_) => _submit() : null,
              hasError: _errorField == _AuthField.email,
            ),
            if (!resetting) ...[
              const SizedBox(height: 10),
              CustomTextField(
                key: const ValueKey('auth-password-field'),
                controller: _passwordController,
                focusNode: _passwordFocusNode,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                hintText: 'Password',
                textInputAction:
                    _isSignUp ? TextInputAction.next : TextInputAction.done,
                onSubmitted: _isSignUp ? null : (_) => _submit(),
                hasError: _errorField == _AuthField.password,
              ),
            ],
            if (_view == _AuthView.signIn)
              Align(
                alignment: Alignment.centerRight,
                child: ShadButton.link(
                  key: const ValueKey('auth-forgot-password'),
                  height: 28,
                  padding: EdgeInsets.zero,
                  foregroundColor: theme.colorScheme.mutedForeground,
                  hoverForegroundColor: theme.colorScheme.foreground,
                  onPressed: busy
                      ? null
                      : () => _showView(_AuthView.resetPassword),
                  child: const Text('Forgot password?'),
                ),
              ),
            if (_isSignUp) ...[
              const SizedBox(height: 10),
              CustomTextField(
                key: const ValueKey('auth-confirm-password-field'),
                controller: _confirmController,
                focusNode: _confirmFocusNode,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                hintText: 'Confirm password',
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                hasError: _errorField == _AuthField.confirm,
              ),
            ],
            const SizedBox(height: 12),
            AnimatedSize(
              duration: _bannerDuration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _message != null
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: AuthMessageBanner(
                        message: _message!,
                        isInfo: _messageIsInfo,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            AnimatedSize(
              duration: _bannerDuration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _waitingForDiscord
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _DiscordPendingBanner(
                        onCancel: () {
                          setState(() => _waitingForDiscord = false);
                        },
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            Row(
              children: [
                Expanded(
                  child: ShadButton.secondary(
                    key: const ValueKey('auth-mode-switch'),
                    onPressed: busy
                        ? null
                        : () => _showView(
                              _view == _AuthView.signIn
                                  ? _AuthView.signUp
                                  : _AuthView.signIn,
                            ),
                    child: Text(switch (_view) {
                      _AuthView.signIn => 'Create an account',
                      _AuthView.signUp => 'Sign in instead',
                      _AuthView.resetPassword => 'Back to sign in',
                    }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (!resetting) ...[
              ShadButton.secondary(
                key: const ValueKey('auth-discord-button'),
                onPressed:
                    busy || _waitingForDiscord ? null : _startDiscordSignIn,
                child: const Text('Continue with Discord'),
              ),
              const SizedBox(height: 10),
            ],
            ShadButton(
              key: const ValueKey('auth-submit-button'),
              onPressed: busy ? null : _submit,
              leading: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              child: Text(switch ((_view, busy)) {
                (_AuthView.signIn, false) => 'Sign in',
                (_AuthView.signIn, true) => 'Signing in…',
                (_AuthView.signUp, false) => 'Create account',
                (_AuthView.signUp, true) => 'Creating…',
                (_AuthView.resetPassword, false) => 'Send reset link',
                (_AuthView.resetPassword, true) => 'Sending…',
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthMessageBanner extends StatelessWidget {
  const AuthMessageBanner({
    super.key,
    required this.message,
    required this.isInfo,
  });

  final String message;
  final bool isInfo;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final color =
        isInfo ? theme.colorScheme.primary : theme.colorScheme.destructive;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isInfo ? LucideIcons.mailCheck : LucideIcons.circleAlert,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.small.copyWith(
                color: color,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscordPendingBanner extends StatelessWidget {
  const _DiscordPendingBanner({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.muted.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.mutedForeground,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Finish signing in with Discord in your browser — this dialog '
              'will close automatically.',
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ShadButton.ghost(
            size: ShadButtonSize.sm,
            onPressed: onCancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
