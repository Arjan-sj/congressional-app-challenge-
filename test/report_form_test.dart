import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/screens/report_form_screen.dart';

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
            onSubmit: (report) async {
              saved = report;
            },
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byType(TextFormField),
      'Observed concern for testing the form only',
    );
    await tester.ensureVisible(find.text('Submit unverified report'));
    await tester.tap(find.text('Submit unverified report'));
    await tester.pump();

    expect(saved, isNotNull);
    expect(saved!.latitude, 42.027416);
    expect(saved!.longitude, -88.106632);
    expect(saved!.status, ReportStatus.unverified);
    expect(saved!.isDemo, isFalse);
  });

  testWidgets('Failed live save keeps the description available for retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportFormScreen(
            selectedLatitude: 42.027416,
            selectedLongitude: -88.106632,
            isLive: true,
            onChooseLocation: () {},
            onSubmit: (_) async => throw StateError('Test connection failure'),
          ),
        ),
      ),
    );

    const description = 'Observed concern retained after a failed save';
    await tester.enterText(find.byType(TextFormField), description);
    await tester.tap(find.text('Submit unverified report'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not save:'), findsOneWidget);
    expect(find.text(description), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((widget) => widget is FilledButton),
          )
          .onPressed,
      isNotNull,
    );
  });
}
