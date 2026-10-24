import 'dart:async';
import 'dart:convert';

import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/models/nearby_school.dart';
import 'package:congressional_app/screens/report_form_screen.dart';
import 'package:congressional_app/screens/analytics_school_picker.dart';
import 'package:congressional_app/services/analytics_repository.dart';
import 'package:congressional_app/services/supabase_hazard_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

NearbySchool school(String id, {double distance = 10}) => NearbySchool(
  id: id,
  name: 'School $id',
  distanceMeters: distance,
  latitude: 40,
  longitude: -80,
);

Widget form({
  required NearbySchoolLookup lookup,
  double latitude = 40,
  Future<void> Function(HazardReport)? onSave,
}) => MaterialApp(
  home: Scaffold(
    body: ReportFormScreen(
      selectedLatitude: latitude,
      selectedLongitude: -80,
      isLive: true,
      lookupSchools: lookup,
      onChooseLocation: () {},
      onSubmit: (report, _, _) async {
        await onSave?.call(report);
      },
    ),
  ),
);

Future<void> confirm(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(CheckboxListTile));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pumpAndSettle();
}

bool canSave(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null;

void main() {
  for (final id in ['A', 'B', '173045003167']) {
    testWidgets('confirmed nearest $id is saved with hazard coordinates', (
      tester,
    ) async {
      HazardReport? saved;
      await tester.pumpWidget(
        form(
          lookup: (_, _) async => [school(id)],
          onSave: (r) async => saved = r,
        ),
      );
      await tester.pumpAndSettle();
      expect(canSave(tester), isFalse);
      await confirm(tester);
      await tester.ensureVisible(find.byType(TextFormField));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'Hazard at the reported pin',
      );
      await tester.tap(find.text('Submit unverified report'));
      await tester.pumpAndSettle();
      expect(saved!.schoolId, id);
      expect(saved!.latitude, 40);
      expect(saved!.longitude, -80);
      expect(saved!.status, ReportStatus.unverified);
    });
  }

  testWidgets(
    'shared campus offers an alternate school and requires confirmation',
    (tester) async {
      HazardReport? saved;
      await tester.pumpWidget(
        form(
          lookup: (_, _) async => [school('A'), school('B')],
          onSave: (r) async => saved = r,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Several schools share this area'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('School B • 10 m').last);
      await tester.pumpAndSettle();
      expect(canSave(tester), isFalse);
      await confirm(tester);
      await tester.ensureVisible(find.byType(TextFormField));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'Shared campus concern',
      );
      await tester.tap(find.text('Submit unverified report'));
      await tester.pumpAndSettle();
      expect(saved!.schoolId, 'B');
    },
  );

  testWidgets(
    'moving the pin clears confirmation and ignores stale lookup responses',
    (tester) async {
      final pending = Completer<List<NearbySchool>>();
      Future<List<NearbySchool>> lookup(double lat, double _) async => lat == 40
          ? [school('A')]
          : lat == 41
          ? pending.future
          : [school('B')];
      await tester.pumpWidget(form(lookup: lookup));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(canSave(tester), isTrue);
      await tester.pumpWidget(form(lookup: lookup, latitude: 41));
      await tester.pump();
      expect(canSave(tester), isFalse);
      await tester.pumpWidget(form(lookup: lookup, latitude: 42));
      await tester.pumpAndSettle();
      expect(find.textContaining('Suggested: School B'), findsOneWidget);
      expect(canSave(tester), isFalse);
      pending.complete([school('STALE')]);
      await tester.pumpAndSettle();
      expect(find.textContaining('STALE'), findsNothing);
      expect(find.textContaining('Suggested: School B'), findsOneWidget);
    },
  );

  for (final fails in [false, true]) {
    testWidgets('empty or failed lookup blocks submission: $fails', (
      tester,
    ) async {
      await tester.pumpWidget(
        form(
          lookup: (_, _) async {
            if (fails) throw StateError('offline');
            return [];
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('school-lookup-error')), findsOneWidget);
      expect(canSave(tester), isFalse);
      expect(find.textContaining('Suggested:'), findsNothing);
    });
  }

  test(
    'repository calls the nearest RPC and decodes meter distances',
    () async {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/rest/v1/rpc/nearest_schools');
          expect(jsonDecode(request.body), {
            'p_latitude': 40.0,
            'p_longitude': -80.0,
          });
          return http.Response(
            jsonEncode([
              {
                'school_id': 'A',
                'name': 'School A',
                'distance_meters': 42.5,
                'latitude': 40,
                'longitude': -80,
              },
            ]),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final results = await SupabaseHazardRepository(client)
          .findNearbySchools(40, -80);
      expect(results.single.id, 'A');
      expect(results.single.distanceMeters, 42.5);
    },
  );

  testWidgets(
    'Analytics searches nationwide and pages beyond the first results',
    (tester) async {
      final calls = <Map<String, dynamic>>[];
      final client = (await tester.runAsync(
        () async => SupabaseClient(
          'https://example.supabase.co',
          'test-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            final params = jsonDecode(request.body) as Map<String, dynamic>;
            calls.add(params);
            final query = params['p_query'];
            final after = params['p_after_id'];
            final rows = query == '60194'
                ? [
                    {'id': '173045003167', 'name': 'Schaumburg High School'},
                  ]
                : after == ''
                ? [
                    for (var i = 0; i < 100; i++)
                      {
                        'id': 'school-${i.toString().padLeft(3, '0')}',
                        'name': 'School $i',
                      },
                  ]
                : [
                    {'id': 'school-100', 'name': 'Beyond first page'},
                  ];
            return http.Response(
              jsonEncode(rows),
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(client.dispose);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AnalyticsSchoolPicker(
            repository: AnalyticsRepository(client),
            selected: const {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Load more schools'),
        600,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Load more schools'));
      await tester.pumpAndSettle();
      expect(calls.last['p_after_id'], 'school-099');
      expect(find.text('Beyond first page'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '60194');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(calls.last['p_query'], '60194');
      expect(find.text('Schaumburg High School'), findsOneWidget);
    },
  );
}
