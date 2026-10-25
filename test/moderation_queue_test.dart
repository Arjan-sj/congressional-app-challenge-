import 'dart:convert';

import 'package:congressional_app/app.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/models/moderation_queue.dart';
import 'package:congressional_app/screens/explore_screen.dart';
import 'package:congressional_app/screens/live_moderation_screen.dart';
import 'package:congressional_app/screens/moderation_scope_picker.dart';
import 'package:congressional_app/screens/report_review_dialog.dart';
import 'package:congressional_app/services/moderation_repository.dart';
import 'package:congressional_app/services/map_data_service.dart';
import 'package:congressional_app/services/hazard_codec.dart';
import 'package:congressional_app/services/supabase_hazard_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'live_moderation_test.dart' as fixture;

Map<String, dynamic> report(
  String id, {
  String status = 'unverified',
  String school = '010000500001',
  String name = 'Nationwide School A',
}) => {
  'id': id,
  'school_id': school,
  'school': {'name': name},
  'type': 'blocked_path',
  'severity': 5,
  'description': 'Nationwide concern $id',
  'status': status,
  'reporter_id': '10000000-0000-0000-0000-000000000099',
  'latitude': 42.0,
  'longitude': -88.0,
  'created_at': '2026-10-01T00:00:00Z',
  'is_demo': false,
};
Map<String, dynamic> queueBody(
  List<Map<String, dynamic>> reports, {
  int offset = 0,
  int? total,
}) => {
  'items': [
    for (final r in reports)
      {
        'report': r,
        'district_name': 'Shared District',
        'school_city': 'City A',
        'school_state': 'AL',
        'open_flags': 1,
      },
  ],
  'counts': {
    'pending': 26,
    'flagged': 1,
    'verified': 1,
    'resolved': 1,
    'rejected': 1,
    'all': 30,
  },
  'total': total ?? reports.length,
  'offset': offset,
  'limit': 25,
  'has_more': offset + reports.length < (total ?? reports.length),
};
http.Response jsonResponse(
  http.Request request,
  Object body, {
  int status = 200,
}) => http.Response(
  jsonEncode(body),
  status,
  request: request,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('moderation preserves report identity, school name and existing photo evidence', () async {
    final row = report('20000000-0000-0000-0000-000000000001');
    final client = await fixture.testClient(
      moderator: true,
      intercept: (request) async {
        if (request.url.path.endsWith('/moderate_hazard_report')) {
          return jsonResponse(request, {...row, 'status': 'verified'});
        }
        return null;
      },
    );
    addTearDown(client.dispose);
    final original = HazardCodec.fromRow(row).withPhoto(
      path: 'existing/private/photo.jpg',
      signedUrl: 'https://storage.example/signed-photo',
    );
    final saved = await SupabaseHazardRepository(client).moderateReport(
      original,
      ReportStatus.verified,
      'Reviewed photo and school location',
    );
    expect(saved.id, original.id);
    expect(saved.schoolId, original.schoolId);
    expect(saved.schoolName, original.schoolName);
    expect(saved.photoPath, original.photoPath);
    expect(saved.photoSignedUrl, original.photoSignedUrl);
    expect(saved.status, ReportStatus.verified);
  });
  test('typed queue preserves report IDs, locations, school metadata and raw counts', () {
    final page = ModerationQueuePage.fromJson(
      queueBody([report('report-a')], total: 26),
    );
    expect(page.items.single.report.schoolName, 'Nationwide School A');
    expect(page.items.single.report.latitude, 42);
    expect(page.items.single.districtName, 'Shared District');
    expect(page.items.single.openFlags, 1);
    expect(page.total, 26);
    expect(page.hasMore, isTrue);
  });
  test(
    'repository sends every filter and pagination request to the server',
    () async {
      final calls = <Map<String, dynamic>>[];
      final client = await fixture.testClient(
        moderator: true,
        intercept: (request) async {
          if (request.url.path.endsWith('/get_moderation_queue')) {
            calls.add(jsonDecode(request.body) as Map<String, dynamic>);
            return jsonResponse(request, queueBody([]));
          }
          if (request.url.path.endsWith('/search_moderation_scopes')) {
            calls.add(jsonDecode(request.body) as Map<String, dynamic>);
            return jsonResponse(request, {
              'items': [],
              'has_more': false,
              'next_cursor': null,
            });
          }
          return null;
        },
      );
      addTearDown(client.dispose);
      final repository = ModerationRepository(client);
      await repository.fetch(
        queue: ModerationQueue.flagged,
        order: ModerationOrder.oldest,
        schoolId: 'school-b',
        districtId: 'nces-lea:0100005',
        offset: 25,
      );
      await repository.searchScopes(
        'school',
        query: 'School B',
        districtId: 'nces-lea:0100005',
        afterId: 'school-a',
      );
      expect(calls.first, {
        'p_queue': 'flagged',
        'p_order': 'oldest',
        'p_school_id': 'school-b',
        'p_district_id': 'nces-lea:0100005',
        'p_offset': 25,
        'p_limit': 25,
      });
      expect(calls.last['p_query'], 'School B');
      expect(calls.last['p_after_id'], 'school-a');
    },
  );
  testWidgets(
    'nationwide queues paginate, order, filter statuses and refresh after a decision',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final calls = <Map<String, dynamic>>[];
      var decision = false;
      final client = (await tester.runAsync(
        () => fixture.testClient(
          moderator: true,
          intercept: (request) async {
            if (!request.url.path.endsWith('/get_moderation_queue')) {
              return null;
            }
            final p = jsonDecode(request.body) as Map<String, dynamic>;
            calls.add(p);
            final offset = p['p_offset'] as int;
            return jsonResponse(
              request,
              queueBody(
                [
                  report(
                    offset == 0 ? 'school-a-report' : 'school-b-report',
                    name: offset == 0
                        ? 'Nationwide School A'
                        : 'Nationwide School B',
                    status: decision ? 'verified' : 'unverified',
                  ),
                ],
                offset: offset,
                total: 26,
              ),
            );
          },
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(client.dispose);
      });
      HazardReport? reviewed;
      Widget screen(int version) => MaterialApp(
        home: Scaffold(
          body: LiveModerationScreen(
            client: client,
            refreshVersion: version,
            onAccessLost: () {},
            onReview: (r) => reviewed = r,
          ),
        ),
      );
      await tester.pumpWidget(screen(0));
      await tester.pumpAndSettle();
      final scroll = find
          .descendant(
            of: find.byKey(const ValueKey('moderation-queue-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Next'),
        300,
        scrollable: scroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(calls.last['p_offset'], 25);
      expect(find.text('Nationwide School B'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Review report'),
        -150,
        scrollable: scroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review report'));
      expect(reviewed?.id, 'school-b-report');
      await tester.scrollUntilVisible(
        find.text('Verified'),
        -300,
        scrollable: scroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Verified'));
      await tester.pumpAndSettle();
      expect(calls.last['p_queue'], 'verified');
      expect(calls.last['p_offset'], 0);
      final order = find.byType(DropdownButtonFormField<ModerationOrder>);
      await tester.ensureVisible(order);
      await tester.pumpAndSettle();
      await tester.tap(order);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oldest first').last);
      await tester.pumpAndSettle();
      expect(calls.last['p_order'], 'oldest');
      decision = true;
      await tester.pumpWidget(screen(1));
      await tester.pumpAndSettle();
      expect(calls.last['p_offset'], 0);
      expect(calls.length, greaterThanOrEqualTo(5));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'school and district selection are remote, distinguish duplicate names and handle mobile text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final searches = <Map<String, dynamic>>[];
      ModerationScope? selected;
      final client = (await tester.runAsync(
        () => fixture.testClient(
          moderator: true,
          intercept: (request) async {
            if (!request.url.path.endsWith('/search_moderation_scopes')) {
              return null;
            }
            final p = jsonDecode(request.body) as Map<String, dynamic>;
            searches.add(p);
            return jsonResponse(request, {
              'items': [
                {
                  'id': 'nces-lea:0100005',
                  'name': 'Shared district',
                  'state': 'AL',
                },
                {
                  'id': 'nces-lea:1300005',
                  'name': 'Shared district',
                  'state': 'GA',
                },
              ],
              'has_more': false,
              'next_cursor': 'nces-lea:1300005',
            });
          },
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(client.dispose);
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final result = await showDialog<({ModerationScope? scope})>(
                    context: context,
                    builder: (_) => ModerationScopePicker(
                      repository: ModerationRepository(client),
                      kind: 'district',
                    ),
                  );
                  selected = result?.scope;
                },
                child: const Text('Choose'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Shared');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(searches.last['p_query'], 'Shared');
      expect(find.text('Shared district'), findsNWidgets(2));
      await tester.ensureVisible(find.textContaining('nces-lea:1300005'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('nces-lea:1300005'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'nces-lea:1300005');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'permission failure clears the remote page and calls access-loss handling',
    (tester) async {
      var revoked = false;
      var losses = 0;
      final client = (await tester.runAsync(
        () => fixture.testClient(
          moderator: true,
          intercept: (request) async {
            if (!request.url.path.endsWith('/get_moderation_queue')) {
              return null;
            }
            return revoked
                ? jsonResponse(request, {
                    'code': '42501',
                    'message': 'Moderator required',
                  }, status: 403)
                : jsonResponse(request, queueBody([report('private')]));
          },
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(client.dispose);
      });
      Widget screen(int v) => MaterialApp(
        home: Scaffold(
          body: LiveModerationScreen(
            client: client,
            refreshVersion: v,
            onReview: (_) {},
            onAccessLost: () => losses++,
          ),
        ),
      );
      await tester.pumpWidget(screen(0));
      await tester.pumpAndSettle();
      revoked = true;
      await tester.pumpWidget(screen(1));
      await tester.pumpAndSettle();
      expect(losses, 1);
      expect(find.textContaining('Nationwide concern'), findsNothing);
      expect(
        find.text('Moderator access is no longer available.'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'live review controls and large queue counts fit enlarged mobile text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = (await tester.runAsync(
        () => fixture.testClient(
          moderator: true,
          intercept: (request) async {
            if (!request.url.path.endsWith('/get_moderation_queue')) {
              return null;
            }
            final body = queueBody([
              report(
                'mobile-review',
                name: 'A long official public school name for the nationwide directory',
              ),
            ]);
            body['counts'] = {
              for (final q in ModerationQueue.values) q.name: 12345,
            };
            return jsonResponse(request, body);
          },
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(client.dispose);
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: LiveModerationScreen(
              client: client,
              onReview: (_) {},
              onAccessLost: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Review report'),
        350,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('moderation-queue-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'revocation with the same signed-in user closes review and removes moderator UI',
    (tester) async {
      var member = true;
      final client = (await tester.runAsync(
        () => fixture.testClient(moderator: true, membership: () => member),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(client.dispose);
      });
      await tester.pumpWidget(
        SafeRoutesApp(
          enableLiveUpdates: false,
          enableMapTiles: false,
          liveClient: client,
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
      member = false;
      // Model a background membership refresh while the modal blocks taps.
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Refresh reports',
            ),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(ReportReviewDialog), findsNothing);
      expect(find.text('Moderation'), findsNothing);
      expect(client.auth.currentUser, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'permission changes purge map hazard cache even when subsequent refresh fails',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var fail = false;
      final data = MapDataService(
        debounce: Duration.zero,
        rpc: (name, p) async {
          if (name == 'infrastructure_in_view') return [];
          if (name == 'hazards_in_view') {
            if (fail) throw StateError('offline');
            return {
              'items': [report('protected-hazard')],
            };
          }
          return {'items': []};
        },
      );
      Widget screen(int version) => MaterialApp(
        home: Scaffold(
          body: ExploreScreen(
            reports: const [],
            onReportAt: (_, _) {},
            onSelectLocation: (_, _) {},
            enableMapTiles: false,
            mapDataService: data,
            visibilityVersion: version,
          ),
        ),
      );
      await tester.pumpWidget(screen(0));
      await tester.pumpAndSettle();
      expect(data.hazards.hasData, isTrue);
      fail = true;
      await tester.pumpWidget(screen(1));
      await tester.pumpAndSettle();
      expect(data.hazards.data.items, isEmpty);
      expect(data.hazards.hasData, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
