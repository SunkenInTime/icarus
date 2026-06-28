import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum AuthDialogMode { signIn, signUp }

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
  String? _errorMessage;

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

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _errorMessage = 'Enter a valid email address.';
      });
      return;
    }

    if (password.length < 6) {
      setState(() {
        _errorMessage = 'Password must be at least 6 characters.';
      });
      return;
    }

    if (_isSignUp && password != confirm) {
      setState(() {
        _errorMessage = 'Passwords do not match.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    final notifier = ref.read(authProvider.notifier);
    final error = _isSignUp
        ? await notifier.signUpWithEmailPassword(email: email, password: password)
        : await notifier.signInWithEmailPassword(email: email, password: password);

    if (!mounted) return;

    setState(() {
      _submitting = false;
      _errorMessage = error;
    });

    if (error == null) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final busy = _submitting || authState.isLoading;

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
              ),
            ],
            const SizedBox(height: 12),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(
                    color: ShadTheme.of(context).colorScheme.destructive,
                    fontSize: 12,
                  ),
                ),
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
                              _errorMessage = null;
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
                    onPressed: busy
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            unawaited(
                              ref.read(authProvider.notifier).signInWithDiscord(),
                            );
                          },
                    child: const Text('Continue with Discord'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ShadButton(
                    onPressed: busy ? null : _submit,
                    child: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isSignUp ? 'Create account' : 'Sign in'),
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
