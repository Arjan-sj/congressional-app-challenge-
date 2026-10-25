import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/moderation_queue.dart';

class ModerationRepository {
  const ModerationRepository(this.client);
  final SupabaseClient client;
  Future<ModerationQueuePage> fetch({
    ModerationQueue queue = ModerationQueue.pending,
    ModerationOrder order = ModerationOrder.priority,
    String? schoolId,
    String? districtId,
    int offset = 0,
  }) async => ModerationQueuePage.fromJson(
    Map<String, dynamic>.from(
      await client.rpc(
        'get_moderation_queue',
        params: {
          'p_queue': queue.name,
          'p_order': order.name,
          'p_school_id': schoolId,
          'p_district_id': districtId,
          'p_offset': offset,
          'p_limit': 25,
        },
      ) as Map,
    ),
  );
  Future<ModerationScopePage> searchScopes(
    String kind, {
    String query = '',
    String? districtId,
    String afterId = '',
  }) async => ModerationScopePage.fromJson(
    Map<String, dynamic>.from(
      await client.rpc(
        'search_moderation_scopes',
        params: {
          'p_kind': kind,
          'p_query': query,
          'p_district_id': districtId,
          'p_after_id': afterId,
          'p_limit': 50,
        },
      ) as Map,
    ),
  );
}
