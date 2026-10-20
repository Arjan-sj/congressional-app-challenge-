import 'package:congressional_app/models/analytics.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('analytics parses aggregates and exports only privacy-safe fields', () {
    final data = AnalyticsData.fromJson({
      'generated_at': '2026-10-19T12:00:00Z',
      'range': {
        'from': '2026-10-01T00:00:00Z',
        'to': '2026-10-19T12:00:00Z',
        'bucket': 'day',
      },
      'summary': {
        'total': 1,
        'pending': 0,
        'verified': 1,
        'resolved': 0,
        'rejected': 0,
        'high_priority': 1,
        'affected_schools': 1,
        'resolution_rate': 0,
      },
      'previous_summary': {
        'total': 0,
        'pending': 0,
        'verified': 0,
        'resolved': 0,
        'rejected': 0,
        'high_priority': 0,
        'affected_schools': 0,
      },
      'trend': [
        {
          'period': '2026-10-19T00:00:00Z',
          'total': 1,
          'pending': 0,
          'verified': 1,
          'resolved': 0,
        },
      ],
      'categories': [
        {
          'key': 'poor_lighting',
          'count': 1,
          'percentage': 100,
          'previous_count': 0,
        },
      ],
      'severities': [
        {'key': 4, 'count': 1, 'percentage': 100},
      ],
      'statuses': [
        {'key': 'verified', 'count': 1, 'percentage': 100},
      ],
      'schools': [],
      'markers': [
        {
          'id': 'hazard-1',
          'school_id': 'school-1',
          'school_name': 'Example School',
          'type': 'poor_lighting',
          'severity': 4,
          'status': 'verified',
          'latitude': 42.0,
          'longitude': -88.0,
          'first_reported_at': '2026-10-19T10:00:00Z',
          'duplicate_count': 2,
          'distance_to_school_meters': 180,
        },
      ],
      'deduplication': {
        'method': 'test method',
        'raw_reports': 2,
        'unique_hazards': 1,
        'duplicates_removed': 1,
      },
      'pagination': {'limit': 500, 'offset': 0, 'total': 1, 'has_more': false},
    });

    expect(data.summary.total, 1);
    expect(data.markers.single.type, HazardType.poorLighting);
    expect(data.markers.single.duplicateCount, 2);

    final json = data.toPrivacySafeJson().toString();
    expect(json, isNot(contains('reporter_id')));
    expect(json, isNot(contains('description')));

    final geoJson = data.toGeoJson();
    expect(geoJson['type'], 'FeatureCollection');
    final feature = (geoJson['features'] as List).single as Map;
    expect((feature['geometry'] as Map)['coordinates'], [-88.0, 42.0]);
  });

  test('analytics filters serialize every global filter for the RPC', () {
    final filter = AnalyticsFilter(
      from: DateTime.utc(2026, 10, 1),
      to: DateTime.utc(2026, 10, 20),
      bucket: AnalyticsBucket.week,
      schoolIds: {'school-1'},
      districts: {'District 211'},
      types: {HazardType.poorLighting},
      severities: {4, 5},
      statuses: {ReportStatus.verified},
      bounds: const AnalyticsBounds(
        minLatitude: 41,
        minLongitude: -89,
        maxLatitude: 43,
        maxLongitude: -87,
      ),
    );

    final params = filter.toRpcParams();
    expect(params['p_bucket'], 'week');
    expect(params['p_school_ids'], ['school-1']);
    expect(params['p_districts'], ['District 211']);
    expect(params['p_types'], ['poor_lighting']);
    expect(params['p_severities'], [4, 5]);
    expect(params['p_statuses'], ['verified']);
    expect(params['p_min_lat'], 41);
    expect(params['p_max_lng'], -87);
  });
}
