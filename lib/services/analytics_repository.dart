import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/analytics.dart';

class AnalyticsRepository {
  const AnalyticsRepository(this.client);

  final SupabaseClient client;

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

  Future<List<AnalyticsSchoolOption>> fetchSchools() async {
    final rows = await client
        .from('schools')
        .select('id,name,district,city,state,latitude,longitude')
        .order('name')
        .limit(5000);
    return rows.map(AnalyticsSchoolOption.fromJson).toList(growable: false);
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
