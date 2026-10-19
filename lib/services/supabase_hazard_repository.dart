import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hazard_report.dart';
import '../models/report_moderation.dart';
import 'hazard_codec.dart';

class SupabaseHazardRepository {
  const SupabaseHazardRepository(this.client);
  final SupabaseClient client;

  static const fields =
      'id,school_id,type,severity,description,status,latitude,longitude,'
      'is_demo,created_at,reporter_id';

  Future<List<HazardReport>> fetchHazards({String? schoolId}) async {
    // RLS returns reviewed/own reports, or the full queue for moderators.
    final query = client
        .from('hazard_reports')
        .select(fields)
        .eq('is_demo', false);
    final rows = schoolId == null
        ? await query.order('created_at', ascending: false).limit(1000)
        : await query
              .eq('school_id', schoolId)
              .order('created_at', ascending: false)
              .limit(1000);
    return rows.map(HazardCodec.fromRow).toList();
  }

  Future<HazardReport> submitHazard(HazardReport report) async {
    final user = client.auth.currentUser;
    if (user == null) {
      throw StateError('Sign in using the account icon before saving.');
    }
    final row = await client
        .from('hazard_reports')
        .insert(HazardCodec.insertPayload(report, reporterId: user.id))
        .select(fields)
        .single();
    return HazardCodec.fromRow(row);
  }

  Future<bool> canModerate() async {
    if (client.auth.currentUser == null) return false;
    return await client.rpc('is_report_moderator') as bool;
  }

  Future<List<ReportFlag>> fetchFlags(String schoolId) async {
    if (client.auth.currentUser == null) return [];
    final rows = await client
        .from('report_flags')
        .select(
          'report_id,user_id,reason,created_at,reviewed_at,hazard_reports!inner(school_id)',
        )
        .eq('hazard_reports.school_id', schoolId)
        .order('created_at', ascending: false);
    return rows.map(ReportFlag.fromRow).toList();
  }

  Future<List<ModerationEvent>> fetchHistory(String reportId) async {
    if (client.auth.currentUser == null) return [];
    final rows = await client
        .from('report_moderation_history')
        .select('report_id,actor_id,previous_status,status,reason,created_at')
        .eq('report_id', reportId)
        .order('created_at', ascending: false);
    return rows.map(ModerationEvent.fromRow).toList();
  }

  Future<void> flagReport(HazardReport report, String reason) async {
    final user = client.auth.currentUser;
    if (user == null) throw StateError('Sign in before flagging a report.');
    await client.from('report_flags').insert({
      'report_id': report.id,
      'user_id': user.id,
      'reason': reason.trim(),
    });
  }

  Future<HazardReport> moderateReport(
    HazardReport report,
    ReportStatus status,
    String reason,
  ) async {
    final row = await client
        .rpc(
          'moderate_hazard_report',
          params: {
            'p_report_id': report.id,
            'p_status': status.name,
            'p_reason': reason.trim(),
            'p_expected_status': report.status.name,
          },
        )
        .single();
    return HazardCodec.fromRow(row);
  }
}
