import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/services/auth_callback_uri.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:icarus/widgets/loading_spinner.dart';
import 'package:icarus/const/settings.dart';

enum AuthDialogMode { signIn, signUp }

enum _AuthView { signIn, signUp, resetPassword }

enum _AuthField { email, password, confirm }

const _bannerDuration = Duration(milliseconds: 180);

/// Supabase takes an address like `foo@bar`, then can't send to it and
/// answers as if its mail server had failed, so stop it here.
final _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s.]+$');

class AuthDialog extends ConsumerStatefulWidget {
  const AuthDialog({
    super.key,
    this.initialMode = AuthDialogMode.signIn,
    this.notice,
  });

  final AuthDialogMode initialMode;

  /// Why the dialog opened by itself, shown until the user moves on.
  final AuthLinkNotice? notice;

  /// Whether one is on screen, so that an email link landing now speaks
  /// through it rather than stacking a second one.
  static bool get isOpen => _AuthDialogState._open > 0;

  @override
  ConsumerState<AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends ConsumerState<AuthDialog> {
  static int _open = 0;

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
    _open++;
    _view = widget.initialMode == AuthDialogMode.signUp
        ? _AuthView.signUp
        : _AuthView.signIn;
    if (widget.notice case final notice?) _applyNotice(notice);
  }

  void _applyNotice(AuthLinkNotice notice) {
    // The dialog that sent the email may still be on the create-account form.
    _view = notice == AuthLinkNotice.resetLinkTimedOut
        ? _AuthView.resetPassword
        : _AuthView.signIn;
    _message = notice.message(ref.read(l10nProvider));
    _messageIsInfo = notice.isInfo;
    _errorField = null;
  }

  @override
  void dispose() {
    _open--;
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
    // Enter in a field still submits while a request is out.
    if (_submitting || ref.read(authProvider).isLoading) return;
    final l10n = context.l10n;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (!_emailShape.hasMatch(email)) {
      _setValidationError(l10n.authInvalidEmail, _AuthField.email);
      return;
    }

    if (_view == _AuthView.resetPassword) {
      await _sendPasswordReset(email);
      return;
    }

    if (password.length < 6) {
      _setValidationError(
        l10n.authPasswordTooShort,
        _AuthField.password,
      );
      return;
    }

    if (_isSignUp && password != confirm) {
      _setValidationError(l10n.authPasswordsDoNotMatch, _AuthField.confirm);
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
      // These outcomes come back through the error channel but are good
      // news — present them as info, not failure.
      _messageIsInfo = error == l10n.authMsgSignUpCheckInbox ||
          error == l10n.authMsgSignUpAlreadySent;
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
        // Only while this dialog is on top: dismissed and still animating
        // out, popping would close the route beneath it.
        if (ModalRoute.of(context)?.isCurrent ?? false) {
          Navigator.of(context).pop(true);
        }
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

    // While Discord is out, a link failing here is that sign-in coming back
    // and failing, not an email.
    ref.listen(authLinkNoticeProvider, (_, notice) {
      if (notice == null) return;
      setState(() {
        if (_waitingForDiscord) {
          _waitingForDiscord = false;
          _message = context.l10n.authDiscordLoginFailed;
          _messageIsInfo = false;
        } else {
          _applyNotice(notice);
        }
      });
    });

    final resetting = _view == _AuthView.resetPassword;
    final theme = ShadTheme.of(context);
    final l10n = context.l10n;

    return ShadDialog(
      title: Text(switch (_view) {
        _AuthView.signIn => l10n.authSignInTitle,
        _AuthView.signUp => l10n.authSignUpTitle,
        _AuthView.resetPassword => l10n.authResetPasswordTitle,
      }),
      description: Text(switch (_view) {
        _AuthView.signIn => l10n.authSignInDescription,
        _AuthView.signUp => l10n.authSignUpDescription,
        _AuthView.resetPassword => l10n.authResetPasswordDescription,
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
              hintText: l10n.authEmailHint,
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
                hintText: l10n.authPasswordHint,
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
                  onPressed:
                      busy ? null : () => _showView(_AuthView.resetPassword),
                  child: Text(l10n.authForgotPassword),
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
                hintText: l10n.authConfirmPasswordHint,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                hasError: _errorField == _AuthField.confirm,
              ),
            ],
            const SizedBox(height: 12),
            AnimatedSize(
              duration: _bannerDuration,
              curve: Settings.easeOut,
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
              curve: Settings.easeOut,
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
                      _AuthView.signIn => l10n.authSwitchToSignUp,
                      _AuthView.signUp => l10n.authSwitchToSignIn,
                      _AuthView.resetPassword => l10n.authBackToSignIn,
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
                child: Text(l10n.authContinueWithDiscord),
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
                      child: LoadingSpinner(strokeWidth: 2),
                    )
                  : null,
              child: Text(switch ((_view, busy)) {
                (_AuthView.signIn, false) => l10n.authSignInButton,
                (_AuthView.signIn, true) => l10n.authSigningIn,
                (_AuthView.signUp, false) => l10n.authSignUpButton,
                (_AuthView.signUp, true) => l10n.authCreating,
                (_AuthView.resetPassword, false) => l10n.authSendResetLink,
                (_AuthView.resetPassword, true) => l10n.authSending,
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
            child: LoadingSpinner(
              strokeWidth: 1.8,
              color: theme.colorScheme.mutedForeground,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.authDiscordPending,
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
            child: Text(context.l10n.commonCancel),
          ),
        ],
      ),
    );
  }
}
