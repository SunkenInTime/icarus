import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum AuthDialogMode { signIn, signUp }

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
  bool _submitting = false;
  bool _isSignUp = false;
  bool _waitingForDiscord = false;
  String? _message;
  bool _messageIsInfo = false;
  _AuthField? _errorField;

  @override
  void initState() {
    super.initState();
    _isSignUp = widget.initialMode == AuthDialogMode.signUp;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _setValidationError(String message, _AuthField field) {
    setState(() {
      _message = message;
      _messageIsInfo = false;
      _errorField = field;
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

    setState(() {
      _submitting = false;
      _message = error;
      // The "account created" outcome comes back through the error channel
      // but is good news — present it as info, not failure.
      _messageIsInfo = error != null && error.startsWith('Account created');
    });

    if (error == null) {
      Navigator.of(context).pop(true);
    }
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

    // The Discord flow completes via a browser round-trip and deep link:
    // close the dialog once the session actually lands, and drop the pending
    // state if the provider reports a failure instead.
    ref.listen(authProvider, (previous, next) {
      if (!_waitingForDiscord) {
        return;
      }
      if (next.isAuthenticated && previous?.isAuthenticated != true) {
        Navigator.of(context).pop(true);
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

    return ShadDialog(
      title: Text(_isSignUp ? 'Create account' : 'Sign in'),
      description: Text(
        _isSignUp
            ? 'Use email and password to create an account.'
            : 'Sign in with email and password.',
      ),
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CustomTextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              hintText: 'Email',
              textInputAction: TextInputAction.next,
              hasError: _errorField == _AuthField.email,
            ),
            const SizedBox(height: 10),
            CustomTextField(
              controller: _passwordController,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              hintText: 'Password',
              textInputAction:
                  _isSignUp ? TextInputAction.next : TextInputAction.done,
              onSubmitted: _isSignUp ? null : (_) => _submit(),
              hasError: _errorField == _AuthField.password,
            ),
            if (_isSignUp) ...[
              const SizedBox(height: 10),
              CustomTextField(
                controller: _confirmController,
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
                      child: _AuthMessageBanner(
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
                    onPressed: busy
                        ? null
                        : () {
                            setState(() {
                              _isSignUp = !_isSignUp;
                              _message = null;
                              _messageIsInfo = false;
                              _errorField = null;
                            });
                          },
                    child: Text(
                      _isSignUp
                          ? 'Already have an account? Sign in'
                          : 'Need an account? Sign up',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ShadButton.secondary(
                    onPressed:
                        busy || _waitingForDiscord ? null : _startDiscordSignIn,
                    child: const Text('Continue with Discord'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ShadButton(
                    onPressed: busy ? null : _submit,
                    leading: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    child: Text(
                      busy
                          ? (_isSignUp ? 'Creating…' : 'Signing in…')
                          : (_isSignUp ? 'Create account' : 'Sign in'),
                    ),
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

class _AuthMessageBanner extends StatelessWidget {
  const _AuthMessageBanner({
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
            isInfo ? Icons.mark_email_read_outlined : Icons.error_outline,
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
