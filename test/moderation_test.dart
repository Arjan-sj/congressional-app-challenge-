import 'dart:async';

import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/models/report_moderation.dart';
import 'package:congressional_app/screens/report_review_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final report = HazardReport(
  id: 'report-1',
  schoolId: 'sample-school',
  type: HazardType.blockedPath,
  severity: 3,
  description: 'Example walking path is blocked.',
  createdAt: DateTime(2026, 10, 18),
);
const emptyReview = ReportReviewData(flags: [], history: []);

Future<void> tapVisible(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).first);
  await tester.pumpAndSettle();
}

Future<void> openDialog(
  WidgetTester tester, {
  Future<void> Function(ReportStatus, String)? onModerate,
  Future<void> Function(String)? onFlag,
  bool canViewHistory = true,
  Future<ReportReviewData> Function()? loadData,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ReportReviewDialog(
                report: report,
                canViewHistory: canViewHistory,
                loadData: loadData ?? () async => emptyReview,
                onModerate: onModerate,
                onFlag: onFlag,
              ),
            ),
            child: const Text('Open review'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open review'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('moderator validates reason before applying decision', (
    tester,
  ) async {
    ReportStatus? savedStatus;
    String? savedReason;
    await openDialog(
      tester,
      onModerate: (status, reason) async {
        savedStatus = status;
        savedReason = reason;
      },
    );
    await tapVisible(tester, 'Verify');
    expect(
      find.text('Enter a reason with at least 5 characters.'),
      findsOneWidget,
    );
    expect(savedStatus, isNull);
    await tester.enterText(
      find.byType(TextFormField),
      '  Checked the crossing details.  ',
    );
    await tapVisible(tester, 'Verify');
    expect(savedStatus, ReportStatus.verified);
    expect(savedReason, 'Checked the crossing details.');
    expect(find.byType(ReportReviewDialog), findsNothing);
  });

  for (final entry in {
    ReportStatus.rejected: 'Reject',
    ReportStatus.resolved: 'Resolve',
  }.entries) {
    testWidgets('${entry.value} records the selected outcome', (tester) async {
      ReportStatus? saved;
      await openDialog(
        tester,
        onModerate: (status, reason) async => saved = status,
      );
      await tester.enterText(
        find.byType(TextFormField),
        'Reviewed current conditions.',
      );
      await tapVisible(tester, entry.value);
      expect(saved, entry.key);
    });
  }

  testWidgets('regular users flag without moderation controls', (tester) async {
    String? flag;
    await openDialog(
      tester,
      canViewHistory: false,
      onFlag: (reason) async => flag = reason,
    );
    expect(find.text('Verify'), findsNothing);
    expect(find.text('Reject'), findsNothing);
    expect(find.text('Resolve'), findsNothing);
    await tester.enterText(
      find.byType(TextFormField),
      'The crossing description is inaccurate.',
    );
    await tapVisible(tester, 'Flag inaccurate');
    expect(flag, 'The crossing description is inaccurate.');
  });

  testWidgets('failed and duplicate flag requests keep the review open', (
    tester,
  ) async {
    await openDialog(
      tester,
      onFlag: (_) async =>
          throw const PostgrestException(message: 'duplicate', code: '23505'),
    );
    await tester.enterText(
      find.byType(TextFormField),
      'The path is currently open.',
    );
    await tapVisible(tester, 'Flag inaccurate');
    expect(find.text('You have already flagged this report.'), findsOneWidget);
    expect(find.byType(ReportReviewDialog), findsOneWidget);
  });

  testWidgets('review details can retry loading after a connection failure', (
    tester,
  ) async {
    var attempts = 0;
    await openDialog(
      tester,
      loadData: () async {
        if (attempts++ == 0) throw StateError('offline');
        return emptyReview;
      },
    );
    expect(
      find.text('Unable to load review details. Try again.'),
      findsOneWidget,
    );
    await tapVisible(tester, 'Retry');
    expect(find.text('No moderation decisions yet.'), findsOneWidget);
  });

  testWidgets('pending saves prevent repeated decisions', (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await openDialog(
      tester,
      onModerate: (_, _) {
        calls++;
        return pending.future;
      },
    );
    await tester.enterText(
      find.byType(TextFormField),
      'Checked the reported location.',
    );
    await tester.ensureVisible(find.text('Verify'));
    await tester.tap(find.text('Verify'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Reject'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
          .onPressed,
      isNull,
    );
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('review remains usable on mobile with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await openDialog(tester, onModerate: (_, _) async {}, onFlag: (_) async {});
    await tester.enterText(find.byType(TextFormField), 'Checked for the demo.');
    await tapVisible(tester, 'Resolve');
    expect(tester.takeException(), isNull);
  });
}
