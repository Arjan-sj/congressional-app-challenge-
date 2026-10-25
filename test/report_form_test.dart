import 'dart:convert';

import 'package:congressional_app/models/nearby_school.dart';

import 'dart:typed_data';

import 'package:congressional_app/models/hazard_photo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/screens/report_form_screen.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  testWidgets('Selected location is included in a Supabase report', (
    tester,
  ) async {
    HazardReport? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportFormScreen(
            selectedLatitude: 42.027416,
            selectedLongitude: -88.106632,
            onChooseLocation: () {},
            isLive: true,
            lookupSchools: (_, _) async => [
              const NearbySchool(
                id: '173045003167',
                name: 'Schaumburg High School',
                distanceMeters: 25,
                latitude: 42.027416,
                longitude: -88.106632,
              ),
            ],
            onSubmit: (report, photo, onProgress) async {
              saved = report;
              expect(photo, isNull);
            },
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextFormField));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField),
      'Observed concern for testing the form only',
    );
    await tester.ensureVisible(find.text('Submit unverified report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit unverified report'));
    await tester.pump();

    expect(saved, isNotNull);
    expect(saved!.schoolId, '173045003167');
    expect(saved!.latitude, 42.027416);
    expect(saved!.longitude, -88.106632);
    expect(saved!.status, ReportStatus.unverified);
    expect(saved!.isDemo, isFalse);
  });

  testWidgets('Failed live save keeps the description available for retry', (
    tester,
  ) async {
    final attemptedIds = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportFormScreen(
            selectedLatitude: 42.027416,
            selectedLongitude: -88.106632,
            isLive: true,
            lookupSchools: (_, _) async => [
              const NearbySchool(
                id: '173045003167',
                name: 'Schaumburg High School',
                distanceMeters: 25,
                latitude: 42.027416,
                longitude: -88.106632,
              ),
            ],
            onChooseLocation: () {},
            onSubmit: (report, _, _) async {
              attemptedIds.add(report.id);
              throw StateError('Test connection failure');
            },
          ),
        ),
      ),
    );

    const description = 'Observed concern retained after a failed save';
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextFormField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), description);
    await tester.tap(find.text('Submit unverified report'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not save:'), findsOneWidget);
    expect(find.text(description), findsOneWidget);
    await tester.ensureVisible(find.text('Submit unverified report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit unverified report'));
    await tester.pumpAndSettle();
    expect(attemptedIds.length, 2);
    expect(
      attemptedIds[0],
      attemptedIds[1],
      reason: 'A retry must reuse the report UUID instead of inserting another report',
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((widget) => widget is FilledButton),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('photo can be previewed, replaced, and removed before submit', (
    tester,
  ) async {
    var picks = 0;
    final pngBytes = Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportFormScreen(
            selectedLatitude: 42.027416,
            selectedLongitude: -88.106632,
            isLive: true,
            lookupSchools: (_, _) async => [
              const NearbySchool(
                id: '173045003167',
                name: 'Schaumburg High School',
                distanceMeters: 25,
                latitude: 42.027416,
                longitude: -88.106632,
              ),
            ],
            onChooseLocation: () {},
            onSubmit: (_, _, _) async {},
            pickPhoto: (source) async {
              expect(source, ImageSource.gallery);
              picks++;
              return HazardPhotoDraft.validate(
                bytes: pngBytes,
                fileName: 'evidence-$picks.png',
                declaredMimeType: 'image/png',
              );
            },
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Upload image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload image'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-preview')), findsOneWidget);
    expect(find.text('Replace image'), findsOneWidget);

    await tester.ensureVisible(find.text('Replace image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace image'));
    await tester.pumpAndSettle();
    expect(find.textContaining('evidence-2.png'), findsOneWidget);

    await tester.ensureVisible(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-preview')), findsNothing);
    expect(find.text('Upload image'), findsOneWidget);
  });
}
