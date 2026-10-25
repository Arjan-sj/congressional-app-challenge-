import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:congressional_app/app.dart';
import 'package:congressional_app/main.dart' as entry;
import 'package:congressional_app/models/hazard_photo.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/screens/community_review_dialog.dart';
import 'package:congressional_app/screens/community_screen.dart';
import 'package:congressional_app/services/community_repository.dart';
import 'package:congressional_app/services/hazard_codec.dart';
import 'package:congressional_app/services/supabase_hazard_repository.dart';

const reportId = '97000000-0000-0000-0000-000000000001';

class Fixture {
  Fixture() {
    client = SupabaseClient(
      'https://example.supabase.co',
      'public-project-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(_request),
    );
  }
  late final SupabaseClient client;
  final calls = <http.Request>[];
  int votes = 0, round = 0;
  String status = 'unverified';
  bool failure = false, own = false;
  Map<String, dynamic> get row => {
    'id': reportId,
    'school_id': 'nationwide-school',
    'school': {'name': 'Nationwide Community School'},
    'type': 'blocked_path',
    'severity': 3,
    'description': 'Observed a blocked public walkway',
    'status': status,
    'latitude': 44,
    'longitude': -90,
    'is_demo': false,
    'created_at': '2026-10-25T00:00:00Z',
  };
  HazardReport get report => HazardCodec.fromRow(row);
  Future<http.Response> _request(http.Request r) async {
    calls.add(r);
    Object data;
    if (r.url.path.endsWith('/community-reports')) {
      final p = jsonDecode(r.body) as Map;
      expect(p['visitor'], matches(RegExp(r'^[-_A-Za-z0-9]{43}$')));
      expect(client.auth.currentSession, isNull);
      if (failure) {
        return http.Response(
          '{"error":"Contribution limit reached. Try again later."}',
          429,
          headers: {'content-type': 'application/json'},
        );
      }
      bool changed = false;
      if (p['action'] == 'review') {
        expect(p['report']['review_round'], round);
        expect(p['report']['expected_status'], status);
        votes++;
        if (votes == 3) {
          status = p['report']['choice'] as String;
          round++;
          votes = 0;
          changed = true;
        }
      }
      data = {
        'report': row,
        'counts': {
          'report_id': reportId,
          'review_round': round,
          'verified': votes,
          'resolved': 0,
          'rejected': 0,
          'flags': 0,
        },
        'own_choice': p['action'] == 'review' ? 'verified' : null,
        'can_review': !own,
        'changed': changed,
        if (p['photo'] != null) 'photo_path': '$reportId/1.png',
        if (p['photo'] != null)
          'photo_url': 'https://example.test/signed-photo',
      };
    } else if (r.url.path.endsWith('/hazard_reports')) {
      data = [row];
    } else if (r.url.path.endsWith('/hazard_report_photos')) {
      data = [];
    } else if (r.url.path.endsWith('/community_review_totals')) {
      data = [
        {
          'report_id': reportId,
          'review_round': round,
          'verified': votes,
          'flags': 1,
        },
      ];
    } else {
      throw StateError('Unexpected request ${r.url.path}');
    }
    return http.Response(
      jsonEncode(data),
      200,
      request: r,
      headers: {'content-type': 'application/json'},
    );
  }
}

// Bridge the fake frame queue and the SDK's real JSON-worker isolate.
Future<void> settleCommunity(WidgetTester tester) async {
  for (var tick = 0; tick < 20; tick++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  test('startup discards old local sessions and preserves the anonymous review token', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sb-example-auth-token', 'synthetic-old-session');
    final visitor = await CommunityRepository.visitorToken();
    await entry.discardPreviousSession('https://example.supabase.co');
    expect(prefs.getString('sb-example-auth-token'), isNull);
    expect(prefs.getString('community_visitor_token'), visitor);
  });
  test('anonymous browser token persists without an Auth identity; report IDs are UUIDs', () async {
    final a = await CommunityRepository.visitorToken(),
        b = await CommunityRepository.visitorToken();
    expect(a, b);
    expect(a, matches(RegExp(r'^[-_A-Za-z0-9]{43}$')));
    expect(
      CommunityRepository.newReportId(),
      matches(
        RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ),
      ),
    );
  });
  test('report and photo submission use the community endpoint without login or role queries', () async {
    final f = Fixture();
    addTearDown(f.client.dispose);
    final progress = <double>[];
    final saved = await SupabaseHazardRepository(f.client).submitHazard(
      f.report,
      photo: HazardPhotoDraft(
        bytes: Uint8List.fromList([
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
          0,
          0,
          0,
          0,
        ]),
        mimeType: 'image/png',
        extension: 'png',
        fileName: 'fixture.png',
      ),
      onProgress: progress.add,
    );
    expect(saved.id, reportId);
    expect(saved.hasPhoto, isTrue);
    expect(saved.photoSignedUrl, 'https://example.test/signed-photo');
    expect(progress.last, 1);
    expect(f.calls.length, 1);
    final p = jsonDecode(f.calls.single.body) as Map;
    expect(p['report'].containsKey('school_id'), isFalse);
    expect(p['report'].containsKey('reporter_id'), isFalse);
  });
  test('server errors remain actionable and do not create sessions', () async {
    final f = Fixture();
    addTearDown(f.client.dispose);
    f.failure = true;
    await expectLater(
      CommunityRepository(f.client).summary(reportId),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Contribution limit'),
        ),
      ),
    );
    expect(f.client.auth.currentUser, isNull);
  });
  testWidgets(
    'all visitors see Community with no account or privileged review controls',
    (tester) async {
      final f = (await tester.runAsync(() async {
        await CommunityRepository.visitorToken();
        final fixture = Fixture();
        await CommunityRepository(fixture.client).summary(reportId);
        return fixture;
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(f.client.dispose);
      });
      await tester.pumpWidget(
        SafeRoutesApp(
          liveClient: f.client,
          enableMapTiles: false,
          enableLiveUpdates: false,
          persistAccessibilityPreferences: false,
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Sign in to SafeRoutes'), findsNothing);
      expect(find.text('Moderation'), findsNothing);
      expect(find.text('Community'), findsOneWidget);
      await tester.tap(find.text('Community'));
      await tester.pumpAndSettle();
      expect(find.text('Review local concerns together'), findsOneWidget);
      expect(find.text('Review report'), findsOneWidget);
      expect(
        f.calls.any(
          (r) =>
              r.url.path.contains('/auth/') ||
              r.url.path.contains('is_report_moderator'),
        ),
        isFalse,
      );
    },
  );
  testWidgets(
    'review validates reasons, records a vote without directly changing status, and refreshes',
    (tester) async {
      final f = (await tester.runAsync(() async {
        await CommunityRepository.visitorToken();
        final fixture = Fixture();
        await CommunityRepository(fixture.client).summary(reportId);
        return fixture;
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(f.client.dispose);
      });
      final changed = <HazardReport>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommunityReviewDialog(
              client: f.client,
              report: f.report,
              onChanged: changed.add,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await settleCommunity(tester);
      final vote = find.widgetWithText(OutlinedButton, 'Concern exists');
      await tester.ensureVisible(vote);
      await tester.tap(vote);
      await tester.pump();
      expect(
        find.text('Give a reason with at least 5 characters.'),
        findsOneWidget,
      );
      expect(
        f.calls.where((r) => jsonDecode(r.body)['action'] == 'review'),
        isEmpty,
      );
      await tester.enterText(
        find.byType(TextField),
        'I observed this blocked walkway.',
      );
      await tester.runAsync(() async {
        await tester.tap(vote);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await settleCommunity(tester);
      expect(changed.single.status, ReportStatus.unverified);
      expect(find.text('Concern exists: 1'), findsOneWidget);
      f.votes = 2;
      await tester.runAsync(() async {
        await tester.tap(vote);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await settleCommunity(tester);
      expect(changed.last.status, ReportStatus.verified);
      expect(
        find.textContaining('Community consensus recorded'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'own submission cannot vote; narrow enlarged-text review remains accessible',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final f = (await tester.runAsync(() async {
        await CommunityRepository.visitorToken();
        final fixture = Fixture();
        await CommunityRepository(fixture.client).summary(reportId);
        return fixture;
      }))!;
      f.own = true;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(f.client.dispose);
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.7)),
            child: child!,
          ),
          home: Scaffold(
            body: CommunityReviewDialog(
              client: f.client,
              report: f.report,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await settleCommunity(tester);
      expect(
        find.textContaining('cannot review your own submission'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'community queue paginates and filters schools including flagged reports',
    (tester) async {
      final f = (await tester.runAsync(() async {
        await CommunityRepository.visitorToken();
        final fixture = Fixture();
        await CommunityRepository(fixture.client).summary(reportId);
        return fixture;
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(f.client.dispose);
      });
      final reports = [
        f.report,
        for (var i = 0; i < 25; i++)
          HazardReport(
            id: 'fixture-$i',
            schoolId: 'other',
            schoolName: 'Other School $i',
            type: HazardType.blockedPath,
            severity: 3,
            description: 'Public concern $i',
            createdAt: DateTime(2026),
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommunityScreen(
              reports: reports,
              client: f.client,
              onReview: (_) {},
            ),
          ),
        ),
      );
      await settleCommunity(tester);
      await tester.scrollUntilVisible(
        find.text('Next'),
        600,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -600,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'Nationwide');
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flagged'));
      await tester.pumpAndSettle();
      expect(find.text('Nationwide Community School'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
