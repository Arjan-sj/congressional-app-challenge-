import '../models/hazard_report.dart';

/// Converts between SafeRoutes' typed model and the Supabase migration.
/// IDs, timestamps and verification status are always server-controlled.
class HazardCodec {
  const HazardCodec._();

  static const types = {
    HazardType.missingSidewalk: 'missing_sidewalk',
    HazardType.difficultCrossing: 'difficult_crossing',
    HazardType.blockedPath: 'blocked_path',
    HazardType.bikeRoute: 'bike_route',
  };

  static HazardReport fromRow(Map<String, dynamic> row) {
    final type = types.entries.firstWhere((e) => e.value == row['type']).key;
    final status = ReportStatus.values.firstWhere(
      (e) => e.name == row['status'],
    );
    return HazardReport(
      id: row['id'] as String,
      schoolId: row['school_id'] as String,
      type: type,
      severity: (row['severity'] as num).toInt(),
      description: row['description'] as String,
      status: status,
      reporterId: row['reporter_id'] as String?,
      latitude: (row['latitude'] as num).toDouble(),
      longitude: (row['longitude'] as num).toDouble(),
      isDemo: row['is_demo'] as bool? ?? false,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  static Map<String, Object> insertPayload(
    HazardReport report, {
    required String reporterId,
  }) {
    if (!report.hasLocation) {
      throw ArgumentError('Select a map location before submitting.');
    }
    if (report.description.trim().length < 5 ||
        report.description.trim().length > 250) {
      throw ArgumentError('Description must be 5–250 characters.');
    }
    if (report.latitude! < -90 ||
        report.latitude! > 90 ||
        report.longitude! < -180 ||
        report.longitude! > 180) {
      throw ArgumentError('Map coordinates out of range.');
    }
    return {
      'school_id': report.schoolId,
      'type': types[report.type]!,
      'severity': report.severity,
      'description': report.description.trim(),
      'latitude': report.latitude!,
      'longitude': report.longitude!,
      'reporter_id': reporterId,
      'is_demo': report.isDemo,
    };
  }
}
