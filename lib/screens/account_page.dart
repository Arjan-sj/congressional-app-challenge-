import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/account_repository.dart';
import '../services/supabase_hazard_repository.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.client,
    this.passwordRecovery = false,
  });
  final SupabaseClient client;
  final bool passwordRecovery;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _username = TextEditingController(),
      _email = TextEditingController(),
      _password = TextEditingController(),
      _confirm = TextEditingController();
  late final String? _actor;
  StreamSubscription<AuthState>? _subscription;
  Map<String, dynamic>? _profile, _application;
  bool _busy = false,
      _loading = true,
      _moderator = false,
      _required = false,
      _showPassword = false;
  String? _message;
  AccountRepository get _accounts => AccountRepository(widget.client);
  @override
  void initState() {
    super.initState();
    _actor = widget.client.auth.currentUser?.id;
    _required = widget.passwordRecovery;
    _subscription = widget.client.auth.onAuthStateChange.listen(
      (_) {
        if (widget.client.auth.currentUser?.id != _actor) {
          if (mounted) {
            setState(() {
              _profile = null;
              _application = null;
              _username.clear();
              _email.clear();
              _password.clear();
              _confirm.clear();
              _moderator = false;
              _message = null;
              _required = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            });
          }
        }
      },
      onError: (Object _) {
        if (!mounted) return;
        setState(() {
          _profile = null;
          _application = null;
          _username.clear();
          _email.clear();
          _moderator = false;
          _loading = false;
          _message = 'Session could not be refreshed. Retry or sign in again.';
        });
      },
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    for (final c in [_username, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final user = (await widget.client.auth.getUser()).user;
      if (user?.id != _actor) return;
      final profile = await _accounts.profile(),
          application = await _accounts.application();
      final moderator = await SupabaseHazardRepository(widget.client)
          .canModerate();
      if (!mounted || widget.client.auth.currentUser?.id != _actor) return;
      setState(() {
        _message = null;
        _profile = profile;
        _application = application;
        _moderator = moderator;
        _required = _required || profile?['requires_password_change'] == true;
        _username.text = profile?['username'] as String? ?? '';
        _email.text = user?.email ?? '';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Account details are unavailable. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() operation, String success) async {
    if (widget.client.auth.currentUser?.id != _actor) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation();
      if (mounted && widget.client.auth.currentUser?.id == _actor) {
        await _load();
        if (mounted) setState(() => _message = success);
      }
    } on AccountFailure catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Unable to update your account. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _savePassword() async {
    if (_password.text != _confirm.text) {
      setState(() => _message = 'Passwords must match.');
      return;
    }
    await _run(() async {
      await _accounts.changePassword(_password.text);
      _password.clear();
      _confirm.clear();
      _required = false;
    }, 'Password updated.');
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.client.auth.currentUser;
    final status = _application?['request_status'] as String?;
    return PopScope(
      canPop: !_required,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Account'),
          automaticallyImplyLeading: !_required,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 660),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_loading) const LinearProgressIndicator(),
                        Text(
                          user?.email ?? 'Account',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Account type: ${_moderator ? 'Moderator' : 'Regular user'}',
                        ),
                        if (status != null)
                          Text(
                            'Moderator application: ${status[0].toUpperCase()}${status.substring(1)}',
                          ),
                        if (status == 'approved' && !_moderator)
                          const Text(
                            'Your application was approved; moderator access is not currently active.',
                          ),
                        if (_required) ...[
                          const SizedBox(height: 16),
                          const Text(
                            'Set a new password before continuing. Your account cannot use moderator privileges until this is completed.',
                          ),
                        ],
                        if (!_required) ...[
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _username,
                            enabled: !_busy && !_loading,
                            autocorrect: false,
                            maxLength: 24,
                            decoration: const InputDecoration(
                              labelText: 'Username (optional)',
                              helperText: 'Your username is used for sign-in. It never grants permissions.',
                              helperMaxLines: 2,
                            ),
                          ),
                          FilledButton.tonal(
                            onPressed: _busy || _loading
                                ? null
                                : () => _run(() async {
                                    if (AccountRepository.normalizeUsername(
                                          _username.text,
                                        ) !=
                                        _profile?['username']) {
                                      await _accounts.changeUsername(
                                        _username.text,
                                      );
                                    }
                                  }, 'Username saved.'),
                            child: const Text('Save username'),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _email,
                            enabled: !_busy && !_loading,
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'Email address',
                            ),
                          ),
                          OutlinedButton(
                            onPressed: _busy || _loading
                                ? null
                                : () => _run(
                                    () => _accounts.changeEmail(_email.text),
                                    'Check your current and new email addresses to confirm the change.',
                                  ),
                            child: const Text('Request email change'),
                          ),
                          OutlinedButton(
                            onPressed: _busy || _loading
                                ? null
                                : () => _run(
                                    () => _accounts.recover(user?.email ?? ''),
                                    'If eligible, password reset instructions have been sent.',
                                  ),
                            child: const Text('Send password reset email'),
                          ),
                          if (!_moderator && status == null)
                            OutlinedButton(
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _run(
                                      _accounts.requestModerator,
                                      'Moderator application submitted. You remain a regular user until approval.',
                                    ),
                              child: const Text('Request moderator access'),
                            ),
                        ],
                        OutlinedButton.icon(
                          onPressed: _busy || _loading
                              ? null
                              : () async {
                                  setState(() => _loading = true);
                                  await _load();
                                },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh account details'),
                        ),
                        const Divider(height: 32),
                        Text(
                          'Change password',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password,
                          enabled: !_busy,
                          obscureText: !_showPassword,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'New password',
                            helperText: '12–128 characters, uppercase, lowercase and a number.',
                            helperMaxLines: 2,
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
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _confirm,
                          enabled: !_busy,
                          obscureText: !_showPassword,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'Confirm new password',
                          ),
                        ),
                        FilledButton(
                          onPressed: _busy ? null : _savePassword,
                          child: const Text('Update password'),
                        ),
                        if (_message != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(_message!),
                            ),
                          ),
                        if (_busy) const LinearProgressIndicator(),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(_accounts.signOut, 'Signed out.'),
                          child: const Text('Sign out'),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Your email and profile details are private. Do not add home addresses or recurring travel schedules. Moderator membership is checked on the server and can be revoked.',
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
    );
  }
}
