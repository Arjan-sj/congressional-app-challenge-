/// Shared UI model matching the Supabase hazard_reports table.
enum HazardType {
  missingSidewalk('Missing sidewalk'),
  difficultCrossing('Dangerous crossing'),
  poorLighting('Poor lighting'),
  blockedPath('Blocked path'),
  bikeRoute('Bike infrastructure');

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
    this.photoPath,
    this.photoSignedUrl,
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

  /// Private Storage object path and its short-lived display URL.
  final String? photoPath;
  final String? photoSignedUrl;

  bool get hasLocation => latitude != null && longitude != null;
  bool get hasPhoto => photoPath != null;

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
    photoPath: photoPath,
    photoSignedUrl: photoSignedUrl,
  );

  HazardReport withPhoto({String? path, String? signedUrl}) => HazardReport(
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
    photoPath: path,
    photoSignedUrl: signedUrl,
  );
}
