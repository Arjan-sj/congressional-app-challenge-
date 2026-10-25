import 'package:supabase_flutter/supabase_flutter.dart';

class AccountFailure implements Exception {
  const AccountFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class AccountRepository {
  const AccountRepository(this.client);
  final SupabaseClient client;
  static const signInError =
      'Unable to sign in. Check your details and verify your email.';
  static String? normalizeUsername(String value) {
    final name = value.trim().toLowerCase();
    return name.isEmpty ? null : name;
  }

  static const reserved = {
    'admin',
    'administrator',
    'adminmoderator',
    'moderator',
    'root',
    'system',
    'support',
    'security',
    'saferoutes',
  };
  static bool validUsername(String value) =>
      normalizeUsername(value) == null ||
      RegExp(r'^[a-z][a-z0-9_]{2,23}$').hasMatch(value.trim().toLowerCase()) &&
          !reserved.contains(value.trim().toLowerCase());
  static bool strongPassword(String value) =>
      value.length >= 12 &&
      value.length <= 128 &&
      RegExp('[a-z]').hasMatch(value) &&
      RegExp('[A-Z]').hasMatch(value) &&
      RegExp('[0-9]').hasMatch(value);
  static bool validEmail(String value) =>
      value.length <= 320 &&
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim());
  static String get redirectUrl =>
      const String.fromEnvironment('AUTH_REDIRECT_URL').isNotEmpty
      ? const String.fromEnvironment('AUTH_REDIRECT_URL')
      : Uri.base.scheme == 'http' || Uri.base.scheme == 'https'
      ? Uri.base.origin
      : 'saferoutes://auth-callback';

  Future<void> _preflight(String identifier) async {
    try {
      await client.functions.invoke(
        'account-auth',
        body: {'action': 'preflight', 'identifier': identifier.trim()},
      );
    } on FunctionException catch (e) {
      throw AccountFailure(
        e.status == 429
            ? 'Too many attempts. Please try again later.'
            : 'Account service is unavailable. Please try again.',
      );
    }
  }

  Future<void> signIn(String identifier, String password) async {
    try {
      if (identifier.contains('@')) {
        await _preflight(identifier);
        await client.auth.signInWithPassword(
          email: identifier.trim(),
          password: password,
        );
      } else {
        final r = await client.functions.invoke(
          'account-auth',
          body: {
            'action': 'login',
            'identifier': normalizeUsername(identifier),
            'password': password,
          },
        );
        if (r.data is! Map || r.data['refresh_token'] is! String) {
          throw const AccountFailure(signInError);
        }
        // The SDK verifies/refreshes the session and retains its normal persistence
        // and automatic refresh lifecycle; no hand-built JWT/session storage.
        await client.auth.setSession(r.data['refresh_token'] as String);
      }
      if (client.auth.currentUser?.emailConfirmedAt == null) {
        await client.auth.signOut();
        throw const AccountFailure(signInError);
      }
    } on FunctionException catch (e) {
      throw AccountFailure(
        e.status == 429
            ? 'Too many attempts. Please try again later.'
            : signInError,
      );
    } on AuthException {
      throw const AccountFailure(signInError);
    }
  }

  Future<void> signUp({
    required String email,
    required String password,
    String username = '',
    bool moderator = false,
  }) async {
    if (!validEmail(email) ||
        !validUsername(username) ||
        !strongPassword(password)) {
      throw const AccountFailure(
        'Check your email, username and password requirements.',
      );
    }
    await _preflight(email);
    try {
      final r = await client.auth.signUp(
        email: email.trim(),
        password: password,
        emailRedirectTo: redirectUrl,
        data: {
          'username': normalizeUsername(username),
          'moderator_application': moderator,
        },
      );
      // Confirmation-disabled projects must not silently enter the app on signup.
      if (r.session != null) await client.auth.signOut();
    } on AuthException {
      throw const AccountFailure(
        'Unable to create the account. Check your details or try another username.',
      );
    }
  }

  Future<void> recover(String email) async {
    if (!validEmail(email)) {
      throw const AccountFailure(
        'Enter your email address to receive reset instructions.',
      );
    }
    await _preflight(email);
    try {
      await client.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: redirectUrl,
      );
    } on AuthException {
      throw const AccountFailure(
        'Unable to send instructions. Please try again later.',
      );
    }
  }

  Future<void> resendVerification(String email) async {
    if (!validEmail(email)) {
      throw const AccountFailure('Enter a valid email address.');
    }
    await _preflight(email);
    await client.auth.resend(
      type: OtpType.signup,
      email: email.trim(),
      emailRedirectTo: redirectUrl,
    );
  }

  Future<Map<String, dynamic>?> profile() async => await client
      .from('user_profiles')
      .select('user_id,username,requires_password_change,created_at,updated_at')
      .eq('user_id', client.auth.currentUser!.id)
      .maybeSingle();
  Future<Map<String, dynamic>?> application() async => await client
      .from('moderator_access_requests')
      .select('id,request_status,created_at,reviewed_at')
      .eq('user_id', client.auth.currentUser!.id)
      .maybeSingle();
  Future<void> changeUsername(String value) async {
    if (!validUsername(value)) {
      throw const AccountFailure(
        'Use 3–24 letters, numbers or underscores, starting with a letter. This name may be reserved.',
      );
    }
    try {
      await client
          .from('user_profiles')
          .update({'username': normalizeUsername(value)})
          .eq('user_id', client.auth.currentUser!.id)
          .select('user_id,username')
          .single();
    } on PostgrestException {
      throw const AccountFailure(
        'That username is unavailable. Please try another.',
      );
    }
  }

  Future<void> changeEmail(String value) async {
    if (!validEmail(value)) {
      throw const AccountFailure('Enter a valid email address.');
    }
    await client.auth.updateUser(
      UserAttributes(email: value.trim()),
      emailRedirectTo: redirectUrl,
    );
  }

  Future<void> changePassword(String value) async {
    if (!strongPassword(value)) {
      throw const AccountFailure(
        'Use 12–128 characters with uppercase, lowercase and a number.',
      );
    }
    await client.auth.updateUser(UserAttributes(password: value));
    await client.auth.refreshSession();
  }

  Future<void> requestModerator() async =>
      await client.rpc('request_moderator_access');
  Future<void> signOut() => client.auth.signOut();
}
