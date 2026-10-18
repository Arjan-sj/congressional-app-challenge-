import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hazard_report.dart';
import 'hazard_codec.dart';

class SupabaseHazardRepository {
  const SupabaseHazardRepository(this.client);
  final SupabaseClient client;

  static const fields =
      'id,school_id,type,severity,description,status,latitude,longitude,'
      'is_demo,created_at';

  Future<List<HazardReport>> fetchHazards(String schoolId) async {
    // RLS returns only reviewed records and the signed-in user's own reports.
    final rows = await client.from('hazard_reports')
        .select(fields)
        .eq('school_id', schoolId)
        .order('created_at', ascending: false);
    return rows.map(HazardCodec.fromRow).toList();
  }

  Future<HazardReport> submitHazard(HazardReport report) async {
    final user = client.auth.currentUser;
    if (user == null) {
      throw StateError('Sign in using the account icon before saving.');
    }
    final row = await client.from('hazard_reports')
        .insert(HazardCodec.insertPayload(report, reporterId: user.id))
        .select(fields)
        .single();
    return HazardCodec.fromRow(row);
  }
}
