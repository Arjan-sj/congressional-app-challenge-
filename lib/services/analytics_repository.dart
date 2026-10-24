import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/analytics.dart';

class AnalyticsRepository {
  const AnalyticsRepository(this.client);

  final SupabaseClient client;

  Future<List<String>> fetchDistricts() async {
    final values = await client.rpc('analytics_school_districts');
    return (values as List).cast<String>();
  }

  Future<AnalyticsData> fetch(
    AnalyticsFilter filter, {
    int limit = 1000,
    int offset = 0,
  }) async {
    final response = await client.rpc(
      'get_hazard_analytics',
      params: filter.toRpcParams(limit: limit, offset: offset),
    );
    if (response is! Map) {
      throw const FormatException('Analytics response was not an object.');
    }
    return AnalyticsData.fromJson(
      response.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  Future<List<AnalyticsSchoolOption>> fetchSchools({
    String query = '',
    String afterId = '',
  }) async {
    final rows = await client.rpc(
      'search_analytics_schools',
      params: {'p_query': query, 'p_after_id': afterId, 'p_limit': 100},
    );
    return (rows as List)
        .map(
          (row) => AnalyticsSchoolOption.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList(growable: false);
  }

  RealtimeChannel subscribeToChanges(void Function() onChange) {
    final channel = client.channel('hazard-analytics');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'hazard_reports',
          callback: (_) => onChange(),
        )
        .subscribe();
    return channel;
  }
}
