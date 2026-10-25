import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/account_repository.dart';
import 'account_page.dart';

enum AuthenticationMode { signIn, signUp, recovery }

class AuthenticationPage extends StatefulWidget {
  const AuthenticationPage({
    super.key,
    required this.client,
    this.initialMode = AuthenticationMode.signIn,
  });
  final SupabaseClient client;
  final AuthenticationMode initialMode;
  @override
  State<AuthenticationPage> createState() => _AuthenticationPageState();
}

class _AuthenticationPageState extends State<AuthenticationPage> {
  final _form = GlobalKey<FormState>();
  final _identifier = TextEditingController(),
      _username = TextEditingController(),
      _password = TextEditingController(),
      _confirmation = TextEditingController();
  late AuthenticationMode _mode;
  bool _busy = false,
      _showPassword = false,
      _showConfirmation = false,
      _moderator = false,
      _verification = false;
  String? _message;
  AccountRepository get _accounts => AccountRepository(widget.client);
  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  @override
  void dispose() {
    for (final c in [_identifier, _username, _password, _confirmation]) {
      c.dispose();
    }
    super.dispose();
  }

  void _switch(AuthenticationMode next) {
    setState(() {
      _mode = next;
      _message = null;
      _verification = false;
      _password.clear();
      _confirmation.clear();
    });
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (_mode == AuthenticationMode.signIn) {
        await _accounts.signIn(_identifier.text, _password.text);
        if (!mounted) return;
        await Navigator.of(context).pushReplacement<void, void>(
          MaterialPageRoute(builder: (_) => AccountPage(client: widget.client)),
        );
      } else if (_mode == AuthenticationMode.signUp) {
        await _accounts.signUp(
          email: _identifier.text,
          password: _password.text,
          username: _username.text,
          moderator: _moderator,
        );
        if (mounted) {
          setState(() {
            _verification = true;
            _password.clear();
            _confirmation.clear();
            _message = 'Check your email for verification instructions, then return to sign in. If you already have an account, sign in or reset your password. Moderator requests never grant access automatically.';
          });
        }
      } else {
        await _accounts.recover(_identifier.text);
        if (mounted) {
          setState(
            () => _message = 'If the account can receive email, password reset instructions have been sent.',
          );
        }
      }
    } on AccountFailure catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Account service is unavailable. Please try again later.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    setState(() => _busy = true);
    try {
      await _accounts.resendVerification(_identifier.text);
      if (mounted) {
        setState(
          () => _message =
              'If eligible, verification instructions have been sent.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _message = 'Unable to send instructions. Please try again later.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signup = _mode == AuthenticationMode.signUp,
        recovery = _mode == AuthenticationMode.recovery;
    final title = signup
        ? 'Create account'
        : recovery
        ? 'Reset password'
        : 'Sign in';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _form,
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'SafeRoutes',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Explore public information without an account. Sign in to submit and track your reports.',
                          ),
                          const SizedBox(height: 20),
                          if (signup) ...[
                            const Text('Account type'),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<bool>(
                              initialValue: _moderator,
                              isExpanded: true,
                              items: const [
                                DropdownMenuItem(
                                  value: false,
                                  child: Text('Regular user'),
                                ),
                                DropdownMenuItem(
                                  value: true,
                                  child: Text('Request moderator access'),
                                ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) =>
                                        setState(() => _moderator = v ?? false),
                              decoration: const InputDecoration(
                                labelText: 'Choose account type',
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Moderator applicants stay regular users until a trusted administrator approves access.',
                            ),
                            const SizedBox(height: 16),
                          ],
                          TextFormField(
                            controller: _identifier,
                            enabled: !_busy,
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            keyboardType: signup || recovery
                                ? TextInputType.emailAddress
                                : TextInputType.text,
                            autofillHints: [
                              signup || recovery
                                  ? AutofillHints.email
                                  : AutofillHints.username,
                            ],
                            decoration: InputDecoration(
                              labelText: signup || recovery
                                  ? 'Email address'
                                  : 'Username or email',
                            ),
                            validator: (v) => signup || recovery
                                ? (AccountRepository.validEmail(v ?? '')
                                      ? null
                                      : 'Enter a valid email address.')
                                : (v?.trim().isNotEmpty == true
                                      ? null
                                      : 'Enter your username or email.'),
                          ),
                          if (signup) ...[
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _username,
                              enabled: !_busy,
                              autocorrect: false,
                              maxLength: 24,
                              decoration: const InputDecoration(
                                labelText: 'Username (optional)',
                                helperText: '3–24 letters, numbers or underscores. Start with a letter.',
                                helperMaxLines: 3,
                              ),
                              validator: (v) =>
                                  AccountRepository.validUsername(v ?? '')
                                  ? null
                                  : 'Choose a valid, unreserved username.',
                            ),
                          ],
                          if (!recovery) ...[
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _password,
                              enabled: !_busy,
                              obscureText: !_showPassword,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: [
                                signup
                                    ? AutofillHints.newPassword
                                    : AutofillHints.password,
                              ],
                              decoration: InputDecoration(
                                labelText: 'Password',
                                suffixIcon: IconButton(
                                  tooltip: _showPassword
                                      ? 'Hide password'
                                      : 'Show password',
                                  onPressed: () => setState(
                                    () => _showPassword = !_showPassword,
                                  ),
                                  icon: Icon(
                                    _showPassword
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                  ),
                                ),
                              ),
                              validator: (v) => signup
                                  ? (AccountRepository.strongPassword(v ?? '')
                                        ? null
                                        : 'Use 12–128 characters, uppercase, lowercase and a number.')
                                  : (v?.isNotEmpty == true
                                        ? null
                                        : 'Enter your password.'),
                            ),
                            if (signup) ...[
                              const SizedBox(height: 8),
                              const Text(
                                'Password: at least 12 characters, including uppercase, lowercase and a number.',
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _confirmation,
                                enabled: !_busy,
                                obscureText: !_showConfirmation,
                                autocorrect: false,
                                enableSuggestions: false,
                                autofillHints: const [
                                  AutofillHints.newPassword,
                                ],
                                decoration: InputDecoration(
                                  labelText: 'Confirm password',
                                  suffixIcon: IconButton(
                                    tooltip: _showConfirmation
                                        ? 'Hide confirmation'
                                        : 'Show confirmation',
                                    onPressed: () => setState(
                                      () => _showConfirmation =
                                          !_showConfirmation,
                                    ),
                                    icon: Icon(
                                      _showConfirmation
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                    ),
                                  ),
                                ),
                                validator: (v) => v == _password.text
                                    ? null
                                    : 'Passwords must match.',
                              ),
                            ],
                          ],
                          if (_message != null) ...[
                            const SizedBox(height: 16),
                            Semantics(liveRegion: true, child: Text(_message!)),
                          ],
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    recovery
                                        ? 'Send reset instructions'
                                        : title,
                                  ),
                          ),
                          if (_verification)
                            TextButton(
                              onPressed: _busy ? null : _resend,
                              child: const Text('Resend verification email'),
                            ),
                          if (!signup && !recovery)
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _switch(AuthenticationMode.recovery),
                              child: const Text('Forgot password?'),
                            ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _switch(
                                    signup || recovery
                                        ? AuthenticationMode.signIn
                                        : AuthenticationMode.signUp,
                                  ),
                            child: Text(
                              signup || recovery
                                  ? 'Back to sign in'
                                  : 'Create account',
                            ),
                          ),
                          const Divider(height: 28),
                          const Text(
                            'Privacy: use an email address you are allowed to use. If you need help, ask a trusted adult. Never include students’ home addresses or daily travel schedules in reports. Usernames are optional; your email is not published.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
