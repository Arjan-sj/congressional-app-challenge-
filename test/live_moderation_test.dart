import 'dart:async';
import 'dart:convert';

import 'package:congressional_app/app.dart';
import 'package:congressional_app/screens/account_page.dart';
import 'package:congressional_app/screens/report_review_dialog.dart';
import 'package:congressional_app/screens/reports_screen.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String encoded(Object value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

Future<SupabaseClient> testClient({
  required bool moderator,
  bool Function()? membership,
  Future<http.Response?> Function(http.Request)? intercept,
}) async {
  const userId = '10000000-0000-0000-0000-000000000001';
  var serverReport = <String, dynamic>{
    'id': '20000000-0000-0000-0000-000000000001',
    'reporter_id': userId,
    'school_id': 'sample-school',
    'school': {'name': 'Nationwide test school'},
    'type': 'blocked_path',
    'severity': 3,
    'description': 'Private pending example',
    'status': 'unverified',
    'latitude': 42.0,
    'longitude': -88.0,
    'is_demo': false,
    'created_at': '2026-10-18T00:00:00Z',
  };
  final token =
      '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': userId, 'role': 'authenticated', 'exp': 4102444800})}.test-signature';
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-publishable-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      final intercepted = await intercept?.call(request);
      if (intercepted != null) {
        if (request.url.path.endsWith('/rpc/moderate_hazard_report') &&
            intercepted.statusCode == 200) {
          serverReport = {
            ...serverReport,
            ...jsonDecode(intercepted.body) as Map<String, dynamic>,
          };
        }
        return intercepted;
      }
      final signedIn = request.headers['Authorization'] == 'Bearer $token';
      final path = request.url.path;
      Object body;
      if (path.endsWith('/token')) {
        body = {
          'access_token': token,
          'refresh_token': 'test-refresh-token',
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': {
            'id': userId,
            'app_metadata': {},
            'user_metadata': {},
            'aud': 'authenticated',
            'created_at': '2026-10-18T00:00:00Z',
          },
        };
      } else if (path.endsWith('/logout')) {
        return http.Response('', 204, request: request);
      } else if (path.endsWith('/rpc/is_report_moderator')) {
        body = (membership?.call() ?? moderator) && signedIn;
      } else if (path.endsWith('/rpc/get_moderation_queue')) {
        if (!(membership?.call() ?? moderator) || !signedIn) {
          return http.Response(
            jsonEncode({
              'code': '42501',
              'message': 'Moderator access required',
            }),
            403,
            request: request,
          );
        }
        final p = jsonDecode(request.body) as Map<String, dynamic>;
        final q = p['p_queue'];
        final match =
            q == 'all' ||
            serverReport['status'] == (q == 'pending' ? 'unverified' : q);
        body = {
          'items': [
            if (match)
              {
                'report': serverReport,
                'district_name': 'Test district',
                'school_city': 'Test city',
                'school_state': 'IL',
                'open_flags': 0,
              },
          ],
          'counts': {
            'pending': serverReport['status'] == 'unverified' ? 1 : 0,
            'verified': serverReport['status'] == 'verified' ? 1 : 0,
            'flagged': 0,
            'resolved': 0,
            'rejected': 0,
            'all': 1,
          },
          'total': match ? 1 : 0,
          'limit': 25,
          'offset': 0,
          'has_more': false,
        };
      } else if (path.endsWith('/hazard_reports')) {
        body = signedIn ? [serverReport] : [];
      } else if (path.endsWith('/hazard_report_photos') ||
          path.endsWith('/report_flags') ||
          path.endsWith('/report_moderation_history')) {
        body = [];
      } else {
        throw StateError('Unexpected request: ${request.method} $path');
      }
      return http.Response(
        jsonEncode(body),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  await client.auth.signInWithPassword(
    email: 'tester@example.com',
    password: 'test-password',
  );
  return client;
}

void main() {
  testWidgets(
    'Auth refresh errors clear protected Home data and recovery opens one password page',
    (tester) async {
      final client = (await tester.runAsync(
        () => testClient(
          moderator: true,
          intercept: (request) async {
            final path = request.url.path;
            Object? body;
            if (path.endsWith('/user')) {
              body = {
                'id': '10000000-0000-0000-0000-000000000001',
                'aud': 'authenticated',
                'created_at': '2026-10-18T00:00:00Z',
                'email': 'synthetic@example.test',
                'app_metadata': {},
                'user_metadata': {},
              };
            } else if (path.endsWith('/user_profiles') ||
                path.endsWith('/moderator_access_requests')) {
              body = [];
            }
            return body == null
                ? null
                : http.Response(
                    jsonEncode(body),
                    200,
                    request: request,
                    headers: {'content-type': 'application/json'},
                  );
          },
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(client.dispose);
      });
      await tester.pumpWidget(
        SafeRoutesApp(
          enableMapTiles: false,
          liveClient: client,
          enableLiveUpdates: false,
          persistAccessibilityPreferences: false,
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReportsScreen>(
              find.byType(ReportsScreen, skipOffstage: false),
            )
            .reports,
        isNotEmpty,
      );
      // Reproduce the SDK's retryable refresh notification without network retries.
      // ignore: invalid_use_of_internal_member
      client.auth.notifyException(
        AuthRetryableFetchException(message: 'Synthetic temporary outage'),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReportsScreen>(
              find.byType(ReportsScreen, skipOffstage: false),
            )
            .reports,
        isEmpty,
      );
      expect(
        find.textContaining('Session could not be refreshed'),
        findsOneWidget,
      );
      // The same event is replayed to late listeners by the SDK at cold startup.
      // ignore: invalid_use_of_internal_member
      client.auth.notifyAllSubscribers(AuthChangeEvent.passwordRecovery);
      // ignore: invalid_use_of_internal_member
      client.auth.notifyAllSubscribers(AuthChangeEvent.passwordRecovery);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AccountPage, skipOffstage: false), findsOneWidget);
      expect(
        find.textContaining('Set a new password before continuing'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final moderator in [false, true]) {
    testWidgets('live moderator tab follows server membership: $moderator', (
      tester,
    ) async {
      final client = (await tester.runAsync(
        () => testClient(moderator: moderator),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(client.dispose);
      });
      await tester.pumpWidget(
        SafeRoutesApp(
          enableLiveUpdates: false,
          environmentName: moderator ? 'staging' : 'local',
          liveClient: client,
          enableMapTiles: false,
          persistAccessibilityPreferences: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Moderation'),
        moderator ? findsOneWidget : findsNothing,
      );
      expect(find.textContaining('Database connection failed'), findsNothing);
      expect(find.text(moderator ? 'STAGING' : 'LOCAL'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('signing out closes review and clears protected reports', (
    tester,
  ) async {
    final client = (await tester.runAsync(() => testClient(moderator: true)))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(client.dispose);
    });
    await tester.pumpWidget(
      SafeRoutesApp(
        enableLiveUpdates: false,
        liveClient: client,
        enableMapTiles: false,
        persistAccessibilityPreferences: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moderation'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Review report'),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('moderation-queue-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review report'));
    await tester.pumpAndSettle();
    expect(find.byType(ReportReviewDialog), findsOneWidget);
    await client.auth.signOut();
    await tester.pumpAndSettle();
    expect(find.byType(ReportReviewDialog), findsNothing);
    expect(find.text('Moderation'), findsNothing);
    expect(find.text('Private pending example'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an older refresh cannot replace a completed moderation decision',
    (tester) async {
      var holdRefresh = false;
      final pending = Completer<http.Response>();
      final client = (await tester.runAsync(
        () => testClient(
          moderator: true,
          intercept: (request) async {
            if (request.url.path.endsWith('/hazard_reports') &&
                holdRefresh &&
                !(request.url.queryParameters['id']?.startsWith('eq.') ??
                    false)) {
              return pending.future;
            }
            if (request.url.path.endsWith('/rpc/moderate_hazard_report')) {
              final payload = jsonDecode(request.body) as Map<String, dynamic>;
              expect(payload['p_expected_status'], 'unverified');
              expect(payload['p_status'], 'verified');
              expect(payload['p_reason'], 'Reviewed example conditions.');
              return http.Response(
                jsonEncode({
                  'id': payload['p_report_id'],
                  'school_id': 'sample-school',
                  'type': 'blocked_path',
                  'severity': 3,
                  'description': 'Reviewed example',
                  'status': 'verified',
                  'latitude': 42,
                  'longitude': -88,
                  'is_demo': true,
                  'created_at': '2026-10-18T00:00:00Z',
                }),
                200,
                request: request,
              );
            }
            return null;
          },
        ),
      ))!;
      addTearDown(() async {
        if (!pending.isCompleted) pending.complete(http.Response('[]', 200));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(client.dispose);
      });
      await tester.pumpWidget(
        SafeRoutesApp(
          enableLiveUpdates: false,
          liveClient: client,
          enableMapTiles: false,
          persistAccessibilityPreferences: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Moderation'));
      await tester.pumpAndSettle();
      holdRefresh = true;
      await tester.tap(find.byTooltip('Refresh reports'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Review report'),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('moderation-queue-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Review report'));
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.enterText(
        find.byType(TextFormField),
        'Reviewed example conditions.',
      );
      await tester.ensureVisible(find.text('Verify'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();
      // An empty stale response would erase the freshly moderated report.
      pending.complete(
        http.Response(
          '[]',
          200,
          request: http.Request(
            'GET',
            Uri.parse('https://example.supabase.co/rest/v1/hazard_reports'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final reportList = tester.widget<ReportsScreen>(
        find.byType(ReportsScreen, skipOffstage: false),
      );
      expect(reportList.reports.single.description, 'Reviewed example');
      expect(reportList.reports.single.status, ReportStatus.verified);
      expect(tester.takeException(), isNull);
    },
  );
}
