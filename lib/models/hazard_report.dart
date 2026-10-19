/// Shared UI model matching the Supabase hazard_reports table.
enum HazardType {
  missingSidewalk('Missing sidewalk'),
  difficultCrossing('Difficult crossing'),
  blockedPath('Blocked path'),
  bikeRoute('Bicycle-route concern');

  const HazardType(this.label);
  final String label;
}

enum ReportStatus {
  unverified('Unverified'),
  verified('Verified'),
  resolved('Resolved'),
  rejected('Rejected');

  const ReportStatus(this.label);
  final String label;
}

class HazardReport {
  const HazardReport({
    required this.id,
    required this.schoolId,
    required this.type,
    required this.severity,
    required this.description,
    required this.createdAt,
    this.status = ReportStatus.unverified,
    this.reporterId,
    this.latitude,
    this.longitude,
    this.isDemo = false,
  }) : assert(severity >= 1 && severity <= 5);

  final String id;
  final String schoolId;
  final HazardType type;
  final int severity;
  final String description;
  final DateTime createdAt;
  final ReportStatus status;
  final String? reporterId;

  /// Null until a user selects a real, verified map location.
  final double? latitude;
  final double? longitude;

  /// Reserved for explicitly labelled fixtures imported from test data.
  final bool isDemo;

  bool get hasLocation => latitude != null && longitude != null;

  HazardReport withStatus(ReportStatus status) => HazardReport(
    id: id,
    schoolId: schoolId,
    type: type,
    severity: severity,
    description: description,
    createdAt: createdAt,
    status: status,
    reporterId: reporterId,
    latitude: latitude,
    longitude: longitude,
    isDemo: isDemo,
  );
}
