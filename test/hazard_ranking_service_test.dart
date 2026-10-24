import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/services/hazard_ranking_service.dart';

void main() {
  HazardReport report({
    required String id,
    required HazardType type,
    required int severity,
    required DateTime createdAt,
    double? latitude,
    double? longitude,
    ReportStatus status = ReportStatus.unverified,
    String schoolId = 'school',
  }) => HazardReport(
    id: id,
    schoolId: schoolId,
    type: type,
    severity: severity,
    description: 'Test hazard',
    createdAt: createdAt,
    latitude: latitude,
    longitude: longitude,
    status: status,
  );

  test('groups nearby reports of the same type and explains the score', () {
    final now = DateTime(2026, 10, 18);
    final rankings = const HazardRankingService().rank([
      report(
        id: 'a',
        type: HazardType.missingSidewalk,
        severity: 5,
        createdAt: now.subtract(const Duration(days: 1)),
        latitude: 42,
        longitude: -88,
      ),
      report(
        id: 'b',
        type: HazardType.missingSidewalk,
        severity: 4,
        createdAt: now.subtract(const Duration(days: 4)),
        latitude: 42.0003,
        longitude: -88,
      ),
      report(
        id: 'different-type',
        type: HazardType.blockedPath,
        severity: 5,
        createdAt: now,
        latitude: 42.0001,
        longitude: -88,
      ),
      report(
        id: 'rejected',
        type: HazardType.missingSidewalk,
        severity: 5,
        createdAt: now,
        latitude: 42,
        longitude: -88,
        status: ReportStatus.rejected,
      ),
    ], now: now);

    expect(rankings, hasLength(2));
    final grouped = rankings.first;
    expect(grouped.reportCount, 2);
    expect(grouped.duplicateCount, 1);
    expect(grouped.averageSeverity, 4.5);
    expect(grouped.severityScore, 45);
    expect(grouped.frequencyScore, 12);
    expect(grouped.recencyScore, 20);
    expect(grouped.totalScore, 77);
    expect(grouped.priority, HazardPriority.high);
  });

  test('shared campus reports remain grouped by school association', () {
    final now = DateTime(2026, 10, 18);
    final rankings = const HazardRankingService().rank([
      for (final id in ['A', 'B'])
        report(
          id: id,
          schoolId: id,
          type: HazardType.blockedPath,
          severity: 3,
          createdAt: now,
          latitude: 42,
          longitude: -88,
        ),
    ], now: now);
    expect(rankings, hasLength(2));
    expect(rankings.every((r) => r.reportCount == 1), isTrue);
  });

  test('does not group reports farther than 75 meters', () {
    final now = DateTime(2026, 10, 18);
    final rankings = const HazardRankingService().rank([
      report(
        id: 'a',
        type: HazardType.bikeRoute,
        severity: 3,
        createdAt: now,
        latitude: 42,
        longitude: -88,
      ),
      report(
        id: 'b',
        type: HazardType.bikeRoute,
        severity: 3,
        createdAt: now,
        latitude: 42.01,
        longitude: -88,
      ),
    ], now: now);

    expect(rankings, hasLength(2));
    expect(rankings.every((ranking) => ranking.reportCount == 1), isTrue);
  });
}
