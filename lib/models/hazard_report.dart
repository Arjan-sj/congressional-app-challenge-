/// Shared UI model for the *demo*. Before adding Supabase, agree on the
/// production database fields in docs/INTEGRATION_CONTRACT.md.
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
    this.latitude,
    this.longitude,
    this.isDemo = true,
  }) : assert(severity >= 1 && severity <= 5);

  final String id;
  final String schoolId;
  final HazardType type;
  final int severity;
  final String description;
  final DateTime createdAt;
  final ReportStatus status;

  /// Null until a user selects a real, verified map location.
  final double? latitude;
  final double? longitude;

  /// All current entries are fictional samples and never verified findings.
  final bool isDemo;

  bool get hasLocation => latitude != null && longitude != null;
}
