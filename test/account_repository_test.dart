import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/services/account_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'account_fixtures.dart';

void main() {
  test('optional usernames normalize and password policy rejects weak/reserved values', () {
    expect(AccountRepository.normalizeUsername(' Traveler_1 '), 'traveler_1');
    expect(AccountRepository.normalizeUsername(''), isNull);
    for (final value in [
      'adminModerator',
      'ADMIN',
      'bad@name',
      'ab',
      '1name',
      'a' * 25,
    ]) {
      expect(AccountRepository.validUsername(value), isFalse);
    }
    expect(AccountRepository.validUsername(''), isTrue);
    expect(AccountRepository.strongPassword('short'), isFalse);
    expect(AccountRepository.strongPassword('Upperlower12345'), isTrue);
  });
  test('email signup remains native Auth, carries only profile/application intents and awaits verification', () async {
    final f = AccountFixture();
    addTearDown(f.client.dispose);
    final repo = AccountRepository(f.client);
    await repo.signUp(
      email: 'one@example.test',
      password: 'Upperlower12345',
      username: ' Traveler ',
      moderator: true,
    );
    expect(f.client.auth.currentSession, isNull);
    final request = f.calls.singleWhere((r) => r.url.path.endsWith('/signup'));
    final data = jsonDecode(request.body) as Map;
    expect(data['data'], {
      'username': 'traveler',
      'moderator_application': true,
    });
    expect(data.containsKey('app_metadata'), isFalse);
    expect(
      f.calls.any((r) => r.url.path.endsWith('/report_moderators')),
      isFalse,
    );
    await repo.resendVerification('one@example.test');
    expect(f.calls.any((r) => r.url.path.endsWith('/resend')), isTrue);
  });
  test('registration accepts omitted username', () async {
    final f = AccountFixture();
    addTearDown(f.client.dispose);
    await AccountRepository(f.client)
        .signUp(email: 'one@example.test', password: 'Upperlower12345');
    expect(
      (jsonDecode(
        f.calls.singleWhere((r) => r.url.path.endsWith('/signup')).body,
      ) as Map)['data']['username'],
      isNull,
    );
  });
  test('email/password signs in directly through Auth; username uses server tokens and SDK refresh/persistence', () async {
    for (final identifier in ['one@example.test', 'Traveler']) {
      final f = AccountFixture();
      addTearDown(f.client.dispose);
      final repo = AccountRepository(f.client);
      await repo.signIn(identifier, 'correct-password');
      expect(f.client.auth.currentUser?.email, 'one@example.test');
      final tokenCall = f.calls.singleWhere(
        (r) => r.url.path.endsWith('/token'),
      );
      expect(
        tokenCall.url.queryParameters['grant_type'],
        identifier.contains('@') ? 'password' : 'refresh_token',
      );
      expect(
        f.calls.any((r) => r.url.path.endsWith('/resolve_account_login')),
        isFalse,
      );
    }
  });
  test(
    'invalid credentials are generic and unverified sessions are cleared',
    () async {
      final f = AccountFixture();
      addTearDown(f.client.dispose);
      final repo = AccountRepository(f.client);
      f.invalid = true;
      await expectLater(
        repo.signIn('traveler', 'incorrect'),
        throwsA(
          isA<AccountFailure>().having(
            (e) => e.message,
            'message',
            AccountRepository.signInError,
          ),
        ),
      );
      f.invalid = false;
      f.unverified = true;
      await expectLater(
        repo.signIn('one@example.test', 'correct'),
        throwsA(isA<AccountFailure>()),
      );
      expect(f.client.auth.currentSession, isNull);
    },
  );
  test('password recovery, profile changes and moderator application use supported APIs without granting roles', () async {
    final f = AccountFixture();
    addTearDown(f.client.dispose);
    final repo = AccountRepository(f.client);
    await repo.signIn('one@example.test', 'correct');
    await repo.recover('one@example.test');
    expect(f.calls.any((r) => r.url.path.endsWith('/recover')), isTrue);
    await repo.changeUsername(' New_Name ');
    expect((await repo.profile())?['username'], 'new_name');
    await repo.changeEmail('new@example.test');
    await repo.requestModerator();
    expect((await repo.application())?['request_status'], 'pending');
    expect(
      f.calls.any((r) => r.url.path.contains('admin_report_moderators')),
      isFalse,
    );
    f.requiresPassword = true;
    await repo.changePassword('Newpassword12345');
    expect(f.requiresPassword, isFalse);
  });
  test('refresh failure, sign-out and account switching use the SDK session lifecycle', () async {
    final f = AccountFixture();
    addTearDown(f.client.dispose);
    final repo = AccountRepository(f.client);
    await repo.signIn('one@example.test', 'correct');
    final first = f.client.auth.currentUser!.id;
    await f.client.auth.refreshSession();
    f.failRefresh = true;
    await expectLater(
      f.client.auth.refreshSession(),
      throwsA(isA<AuthException>()),
    );
    expect(f.client.auth.currentSession, isNull);
    f.failRefresh = false;
    await repo.signOut();
    expect(f.client.auth.currentSession, isNull);
    await repo.signIn('two@example.test', 'correct');
    expect(f.client.auth.currentUser!.id, isNot(first));
  });
}
