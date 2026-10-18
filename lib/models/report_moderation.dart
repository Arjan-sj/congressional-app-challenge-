import 'hazard_report.dart';

class ReportFlag {
  const ReportFlag({
    required this.reportId,
    required this.userId,
    required this.reason,
    required this.createdAt,
    this.reviewedAt,
  });

  final String reportId;
  final String userId;
  final String reason;
  final DateTime createdAt;
  final DateTime? reviewedAt;
  bool get isOpen => reviewedAt == null;

  factory ReportFlag.fromRow(Map<String, dynamic> row) => ReportFlag(
    reportId: row['report_id'] as String,
    userId: row['user_id'] as String,
    reason: row['reason'] as String,
    createdAt: DateTime.parse(row['created_at'] as String),
    reviewedAt: row['reviewed_at'] == null
        ? null
        : DateTime.parse(row['reviewed_at'] as String),
  );

  ReportFlag reviewed(DateTime at) => ReportFlag(
    reportId: reportId,
    userId: userId,
    reason: reason,
    createdAt: createdAt,
    reviewedAt: reviewedAt ?? at,
  );
}

class ModerationEvent {
  const ModerationEvent({
    required this.reportId,
    required this.actorId,
    required this.previousStatus,
    required this.status,
    required this.reason,
    required this.createdAt,
  });

  final String reportId;
  final String? actorId;
  final ReportStatus previousStatus;
  final ReportStatus status;
  final String reason;
  final DateTime createdAt;

  factory ModerationEvent.fromRow(Map<String, dynamic> row) => ModerationEvent(
    reportId: row['report_id'] as String,
    actorId: row['actor_id'] as String?,
    previousStatus: ReportStatus.values.byName(
      row['previous_status'] as String,
    ),
    status: ReportStatus.values.byName(row['status'] as String),
    reason: row['reason'] as String,
    createdAt: DateTime.parse(row['created_at'] as String),
  );
}

class ReportReviewData {
  const ReportReviewData({required this.flags, required this.history});
  final List<ReportFlag> flags;
  final List<ModerationEvent> history;
}
