import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/screens/authentication_page.dart';
import 'package:congressional_app/screens/account_page.dart';
import 'package:congressional_app/services/account_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'account_fixtures.dart';

void main() {
  testWidgets('retryable refresh errors clear account details and can recover', (
    tester,
  ) async {
    final f = (await tester.runAsync(() async => AccountFixture()))!;
    await tester.runAsync(
      () => AccountRepository(f.client).signIn('one@example.test', 'correct'),
    );
    addTearDown(() async {
      await tester.runAsync(f.client.dispose);
    });
    await tester.pumpWidget(MaterialApp(home: AccountPage(client: f.client)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
    // Inject the SDK's documented stream outcome without making a network call.
    // ignore: invalid_use_of_internal_member
    f.client.auth.notifyException(
      AuthRetryableFetchException(message: 'Synthetic network failure'),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Session could not be refreshed'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Username (optional)'),
          )
          .controller!
          .text,
      isEmpty,
    );
    final retry = find.widgetWithText(
      OutlinedButton,
      'Refresh account details',
    );
    await tester.ensureVisible(retry);
    await tester.runAsync(() async {
      await tester.tap(retry);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Username (optional)'),
          )
          .controller!
          .text,
      'traveler',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'password recovery and bootstrap accounts require a password change before moderator access',
    (tester) async {
      final f = (await tester.runAsync(() async => AccountFixture()))!;
      f.requiresPassword = true;
      f.moderator = true;
      await tester.runAsync(
        () => AccountRepository(f.client).signIn('one@example.test', 'correct'),
      );
      addTearDown(() async {
        await tester.runAsync(f.client.dispose);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AccountPage(client: f.client, passwordRecovery: true),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Set a new password before continuing'),
        findsOneWidget,
      );
      expect(find.text('Account type: Regular user'), findsOneWidget);
      expect(find.text('Save username'), findsNothing);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Changedpassword12345');
      await tester.enterText(fields.at(1), 'Changedpassword12345');
      final update = find.widgetWithText(FilledButton, 'Update password');
      await tester.ensureVisible(update);
      await tester.runAsync(() async {
        await tester.tap(update);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('Password updated.'), findsOneWidget);
      expect(find.text('Account type: Moderator'), findsOneWidget);
      expect(find.text('Save username'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'responsive sign-in, registration and recovery forms are accessible with enlarged mobile text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final f = (await tester.runAsync(() async => AccountFixture()))!;
      addTearDown(() async {
        await tester.runAsync(f.client.dispose);
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.7)),
            child: child!,
          ),
          home: AuthenticationPage(client: f.client),
        ),
      );
      expect(
        find.widgetWithText(TextFormField, 'Username or email'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byTooltip('Show password'));
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(find.byTooltip('Hide password'), findsOneWidget);
      final create = find.widgetWithText(TextButton, 'Create account');
      await tester.ensureVisible(create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextFormField, 'Username (optional)'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextFormField, 'Confirm password'),
        findsOneWidget,
      );
      expect(find.text('Choose account type'), findsOneWidget);
      final type = find.byType(DropdownButtonFormField<bool>);
      await tester.ensureVisible(type);
      await tester.tap(type);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Request moderator access').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<DropdownButtonFormField<bool>>(type).initialValue,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      final back = find.widgetWithText(TextButton, 'Back to sign in');
      await tester.ensureVisible(back);
      await tester.tap(back);
      await tester.pumpAndSettle();
      final forgot = find.widgetWithText(TextButton, 'Forgot password?');
      await tester.ensureVisible(forgot);
      await tester.tap(forgot);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextFormField, 'Email address'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, 'Send reset instructions'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'signup validates passwords and reserved usernames without sending requests',
    (tester) async {
      final f = (await tester.runAsync(() async => AccountFixture()))!;
      addTearDown(() async {
        await tester.runAsync(f.client.dispose);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AuthenticationPage(
            client: f.client,
            initialMode: AuthenticationMode.signUp,
          ),
        ),
      );
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'one@example.test');
      await tester.enterText(fields.at(1), 'adminModerator');
      await tester.enterText(fields.at(2), 'weak');
      await tester.enterText(fields.at(3), 'different');
      final submit = find.widgetWithText(FilledButton, 'Create account');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      expect(find.text('Choose a valid, unreserved username.'), findsOneWidget);
      expect(find.text('Passwords must match.'), findsOneWidget);
      expect(f.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'account settings show verified membership and pending status; account switch clears the page',
    (tester) async {
      final f = (await tester.runAsync(() async => AccountFixture()))!;
      f.applicationStatus = 'pending';
      await tester.runAsync(
        () => AccountRepository(f.client).signIn('one@example.test', 'correct'),
      );
      addTearDown(() async {
        await tester.runAsync(f.client.dispose);
      });
      await tester.pumpWidget(MaterialApp(home: AccountPage(client: f.client)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Account type: Regular user'), findsOneWidget);
      expect(find.text('Moderator application: Pending'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'Username (optional)'),
        findsOneWidget,
      );
      await tester.runAsync(() => f.client.auth.signOut());
      await tester.pumpAndSettle();
      expect(find.text('one@example.test'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
