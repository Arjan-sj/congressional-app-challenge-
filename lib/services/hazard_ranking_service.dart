import 'dart:math' as math;

import '../models/hazard_report.dart';

enum HazardPriority {
  high('High priority'),
  elevated('Elevated'),
  monitor('Monitor');

  const HazardPriority(this.label);
  final String label;
}

class HazardRanking {
  const HazardRanking({
    required this.reports,
    required this.averageSeverity,
    required this.severityScore,
    required this.frequencyScore,
    required this.recencyScore,
    required this.totalScore,
    required this.priority,
    required this.latitude,
    required this.longitude,
  });

  final List<HazardReport> reports;
  final double averageSeverity;
  final double severityScore;
  final double frequencyScore;
  final double recencyScore;
  final double totalScore;
  final HazardPriority priority;
  final double? latitude;
  final double? longitude;

  HazardReport get newestReport => reports.reduce(
    (current, candidate) =>
        candidate.createdAt.isAfter(current.createdAt) ? candidate : current,
  );

  HazardType get type => reports.first.type;
  int get reportCount => reports.length;
  int get duplicateCount => math.max(0, reportCount - 1);
  bool get hasLocation => latitude != null && longitude != null;
}

class HazardRankingService {
  const HazardRankingService();

  static const duplicateRadiusMeters = 75.0;

  List<HazardRanking> rank(List<HazardReport> reports, {DateTime? now}) {
    final scoredAt = now ?? DateTime.now();
    final active = reports
        .where(
          (report) =>
              report.status != ReportStatus.resolved &&
              report.status != ReportStatus.rejected,
        )
        .toList(growable: false);
    final groups = _groupDuplicates(active);
    final rankings = groups
        .map((group) => _score(group, scoredAt))
        .toList(growable: false);
    rankings.sort((a, b) {
      final scoreOrder = b.totalScore.compareTo(a.totalScore);
      if (scoreOrder != 0) return scoreOrder;
      return b.newestReport.createdAt.compareTo(a.newestReport.createdAt);
    });
    return rankings;
  }

  List<List<HazardReport>> _groupDuplicates(List<HazardReport> reports) {
    final groups = <List<HazardReport>>[];
    final visited = <int>{};

    for (var start = 0; start < reports.length; start++) {
      if (visited.contains(start)) continue;
      visited.add(start);
      final group = <HazardReport>[reports[start]];
      final queue = <int>[start];

      while (queue.isNotEmpty) {
        final currentIndex = queue.removeLast();
        final current = reports[currentIndex];
        if (!current.hasLocation) continue;
        for (
          var candidateIndex = 0;
          candidateIndex < reports.length;
          candidateIndex++
        ) {
          if (visited.contains(candidateIndex)) continue;
          final candidate = reports[candidateIndex];
          if (!candidate.hasLocation || candidate.type != current.type) {
            continue;
          }
          if (_distanceMeters(current, candidate) <= duplicateRadiusMeters) {
            visited.add(candidateIndex);
            group.add(candidate);
            queue.add(candidateIndex);
          }
        }
      }
      groups.add(group);
    }
    return groups;
  }

  HazardRanking _score(List<HazardReport> reports, DateTime now) {
    final averageSeverity =
        reports.fold<int>(0, (sum, report) => sum + report.severity) /
        reports.length;
    final severityScore = averageSeverity / 5 * 50;
    final frequencyScore = math.min(reports.length, 5) / 5 * 30;
    final newest = reports.reduce(
      (current, candidate) =>
          candidate.createdAt.isAfter(current.createdAt) ? candidate : current,
    );
    final ageDays = math.max(0, now.difference(newest.createdAt).inDays);
    final recencyScore = switch (ageDays) {
      <= 7 => 20.0,
      <= 30 => 15.0,
      <= 90 => 10.0,
      <= 180 => 5.0,
      _ => 0.0,
    };
    final totalScore = severityScore + frequencyScore + recencyScore;
    final priority = totalScore >= 70
        ? HazardPriority.high
        : totalScore >= 45
        ? HazardPriority.elevated
        : HazardPriority.monitor;
    final located = reports.where((report) => report.hasLocation).toList();

    return HazardRanking(
      reports: List.unmodifiable(reports),
      averageSeverity: averageSeverity,
      severityScore: severityScore,
      frequencyScore: frequencyScore,
      recencyScore: recencyScore,
      totalScore: totalScore,
      priority: priority,
      latitude: located.isEmpty
          ? null
          : located.fold<double>(0, (sum, report) => sum + report.latitude!) /
                located.length,
      longitude: located.isEmpty
          ? null
          : located.fold<double>(0, (sum, report) => sum + report.longitude!) /
                located.length,
    );
  }

  double _distanceMeters(HazardReport a, HazardReport b) {
    const earthRadiusMeters = 6371000.0;
    final lat1 = _radians(a.latitude!);
    final lat2 = _radians(b.latitude!);
    final deltaLat = _radians(b.latitude! - a.latitude!);
    final deltaLon = _radians(b.longitude! - a.longitude!);
    final haversine =
        math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLon / 2) *
            math.sin(deltaLon / 2);
    return earthRadiusMeters *
        2 *
        math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
  }

  double _radians(double degrees) => degrees * math.pi / 180;
}
