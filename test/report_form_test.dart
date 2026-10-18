import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/screens/report_form_screen.dart';

void main() {
  testWidgets('Selected location is included in a local demo report', (tester) async {
    HazardReport? saved;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReportFormScreen(
          selectedLatitude: 42.027416,
          selectedLongitude: -88.106632,
          onChooseLocation: () {},
          onSubmit: (report) async { saved = report; },
        ),
      ),
    ));

    await tester.enterText(
      find.byType(TextFormField),
      'Fictional example for testing the form only',
    );
    await tester.ensureVisible(find.text('Save demo report locally'));
    await tester.tap(find.text('Save demo report locally'));
    await tester.pump();

    expect(saved, isNotNull);
    expect(saved!.latitude, 42.027416);
    expect(saved!.longitude, -88.106632);
    expect(saved!.status, ReportStatus.unverified);
    expect(saved!.isDemo, isTrue);
  });
}
