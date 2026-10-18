import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pilot test-account login. Do not open public registration before adding
/// age-appropriate privacy disclosures and anti-abuse protections.
class AuthDialog extends StatefulWidget {
  const AuthDialog({super.key, required this.client});
  final SupabaseClient client;

  @override
  State<AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<AuthDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _auth({required bool signUp}) async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@') || password.length < 6) {
      setState(() => _message =
          'Enter a valid email and password of at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (signUp) {
        final result = await widget.client.auth.signUp(
          email: email,
          password: password,
          emailRedirectTo: Uri.base.origin,
        );
        if (!mounted) return;
        if (result.session == null) {
          setState(() => _message =
              'Check your email to confirm the account, then return and sign in.');
          return;
        }
      } else {
        await widget.client.auth.signInWithPassword(
          email: email,
          password: password,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _message = 'Authentication failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await widget.client.auth.signOut();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _message = 'Sign out failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = widget.client.auth.currentUser != null;
    return AlertDialog(
      title: Text(signedIn ? 'Account' : 'SafeRoutes test account'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Internal pilot only. Never submit real student names, home '
                'addresses, or commuting routes.',
              ),
              if (!signedIn) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _email,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ] else
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('Signed in. Your pending reports are private to you.'),
                ),
              if (_message != null) ...[
                const SizedBox(height: 10),
                Text(
                  _message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (signedIn)
          FilledButton(
            onPressed: _busy ? null : _signOut,
            child: const Text('Sign out'),
          )
        else ...[
          TextButton(
            onPressed: _busy ? null : () => _auth(signUp: true),
            child: const Text('Create account'),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _auth(signUp: false),
            child: const Text('Sign in'),
          ),
        ],
      ],
    );
  }
}
