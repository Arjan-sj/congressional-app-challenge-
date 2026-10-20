import 'package:latlong2/latlong.dart';

import 'hazard_report.dart';

enum AnalyticsBucket {
  day('Daily'),
  week('Weekly'),
  month('Monthly');

  const AnalyticsBucket(this.label);
  final String label;
}

class AnalyticsBounds {
  const AnalyticsBounds({
    required this.minLatitude,
    required this.minLongitude,
    required this.maxLatitude,
    required this.maxLongitude,
  });

  final double minLatitude;
  final double minLongitude;
  final double maxLatitude;
  final double maxLongitude;
}

class AnalyticsFilter {
  AnalyticsFilter({
    required this.from,
    required this.to,
    this.bucket = AnalyticsBucket.day,
    Set<String>? schoolIds,
    Set<String>? districts,
    Set<HazardType>? types,
    Set<int>? severities,
    Set<ReportStatus>? statuses,
    this.bounds,
  }) : schoolIds = schoolIds ?? {},
       districts = districts ?? {},
       types = types ?? {},
       severities = severities ?? {},
       statuses = statuses ?? {};

  final DateTime from;
  final DateTime to;
  final AnalyticsBucket bucket;
  final Set<String> schoolIds;
  final Set<String> districts;
  final Set<HazardType> types;
  final Set<int> severities;
  final Set<ReportStatus> statuses;
  final AnalyticsBounds? bounds;

  AnalyticsFilter copyWith({
    DateTime? from,
    DateTime? to,
    AnalyticsBucket? bucket,
    Set<String>? schoolIds,
    Set<String>? districts,
    Set<HazardType>? types,
    Set<int>? severities,
    Set<ReportStatus>? statuses,
    AnalyticsBounds? bounds,
    bool clearBounds = false,
  }) => AnalyticsFilter(
    from: from ?? this.from,
    to: to ?? this.to,
    bucket: bucket ?? this.bucket,
    schoolIds: schoolIds ?? this.schoolIds,
    districts: districts ?? this.districts,
    types: types ?? this.types,
    severities: severities ?? this.severities,
    statuses: statuses ?? this.statuses,
    bounds: clearBounds ? null : bounds ?? this.bounds,
  );

  Map<String, dynamic> toRpcParams({int limit = 1000, int offset = 0}) {
    final params = <String, dynamic>{
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
      'p_bucket': bucket.name,
      'p_limit': limit,
      'p_offset': offset,
    };
    if (schoolIds.isNotEmpty) params['p_school_ids'] = schoolIds.toList();
    if (districts.isNotEmpty) params['p_districts'] = districts.toList();
    if (types.isNotEmpty) {
      params['p_types'] = types.map(_hazardTypeKey).toList();
    }
    if (severities.isNotEmpty) {
      params['p_severities'] = severities.toList()..sort();
    }
    if (statuses.isNotEmpty) {
      params['p_statuses'] = statuses.map((status) => status.name).toList();
    }
    if (bounds case final value?) {
      params
        ..['p_min_lat'] = value.minLatitude
        ..['p_min_lng'] = value.minLongitude
        ..['p_max_lat'] = value.maxLatitude
        ..['p_max_lng'] = value.maxLongitude;
    }
    return params;
  }
}

class AnalyticsData {
  const AnalyticsData({
    required this.generatedAt,
    required this.from,
    required this.to,
    required this.bucket,
    required this.summary,
    required this.previousSummary,
    required this.trend,
    required this.categories,
    required this.severities,
    required this.statuses,
    required this.schools,
    required this.markers,
    required this.deduplication,
    required this.pagination,
  });

  factory AnalyticsData.fromJson(Map<String, dynamic> json) {
    final range = _map(json['range']);
    return AnalyticsData(
      generatedAt: _date(json['generated_at']),
      from: _date(range['from']),
      to: _date(range['to']),
      bucket: AnalyticsBucket.values.firstWhere(
        (value) => value.name == range['bucket'],
        orElse: () => AnalyticsBucket.day,
      ),
      summary: AnalyticsSummary.fromJson(_map(json['summary'])),
      previousSummary: AnalyticsSummary.fromJson(
        _map(json['previous_summary']),
      ),
      trend: _maps(json['trend']).map(AnalyticsTrendPoint.fromJson).toList(),
      categories: _maps(json['categories'])
          .map(AnalyticsBreakdown.fromJson)
          .toList(),
      severities: _maps(json['severities'])
          .map(AnalyticsBreakdown.fromJson)
          .toList(),
      statuses: _maps(json['statuses'])
          .map(AnalyticsBreakdown.fromJson)
          .toList(),
      schools: _maps(json['schools']).map(SchoolAnalytics.fromJson).toList(),
      markers: _maps(json['markers']).map(AnalyticsMarker.fromJson).toList(),
      deduplication: DeduplicationInfo.fromJson(_map(json['deduplication'])),
      pagination: AnalyticsPagination.fromJson(_map(json['pagination'])),
    );
  }

  final DateTime generatedAt;
  final DateTime from;
  final DateTime to;
  final AnalyticsBucket bucket;
  final AnalyticsSummary summary;
  final AnalyticsSummary previousSummary;
  final List<AnalyticsTrendPoint> trend;
  final List<AnalyticsBreakdown> categories;
  final List<AnalyticsBreakdown> severities;
  final List<AnalyticsBreakdown> statuses;
  final List<SchoolAnalytics> schools;
  final List<AnalyticsMarker> markers;
  final DeduplicationInfo deduplication;
  final AnalyticsPagination pagination;

  AnalyticsData withMarkers(
    List<AnalyticsMarker> values,
    AnalyticsPagination page,
  ) => AnalyticsData(
    generatedAt: generatedAt,
    from: from,
    to: to,
    bucket: bucket,
    summary: summary,
    previousSummary: previousSummary,
    trend: trend,
    categories: categories,
    severities: severities,
    statuses: statuses,
    schools: schools,
    markers: values,
    deduplication: deduplication,
    pagination: page,
  );

  Map<String, dynamic> toPrivacySafeJson() => {
    'generated_at': generatedAt.toIso8601String(),
    'range': {
      'from': from.toIso8601String(),
      'to': to.toIso8601String(),
      'bucket': bucket.name,
    },
    'summary': summary.toJson(),
    'previous_summary': previousSummary.toJson(),
    'trend': trend.map((value) => value.toJson()).toList(),
    'categories': categories.map((value) => value.toJson()).toList(),
    'severities': severities.map((value) => value.toJson()).toList(),
    'statuses': statuses.map((value) => value.toJson()).toList(),
    'schools': schools.map((value) => value.toJson()).toList(),
    'hazards': markers.map((value) => value.toJson()).toList(),
    'deduplication': deduplication.toJson(),
  };

  Map<String, dynamic> toGeoJson() => {
    'type': 'FeatureCollection',
    'generated_at': generatedAt.toIso8601String(),
    'features': markers
        .map(
          (marker) => {
            'type': 'Feature',
            'id': marker.id,
            'geometry': {
              'type': 'Point',
              'coordinates': [marker.longitude, marker.latitude],
            },
            'properties': {
              'school_id': marker.schoolId,
              'school_name': marker.schoolName,
              'hazard_type': _hazardTypeKey(marker.type),
              'severity': marker.severity,
              'status': marker.status.name,
              'first_reported_at': marker.firstReportedAt.toIso8601String(),
              'resolved_at': marker.resolvedAt?.toIso8601String(),
              'duplicate_reports_consolidated': marker.duplicateCount,
              'distance_to_school_meters': marker.distanceToSchoolMeters,
            },
          },
        )
        .toList(),
  };
}

class AnalyticsSummary {
  const AnalyticsSummary({
    required this.total,
    required this.pending,
    required this.verified,
    required this.resolved,
    required this.rejected,
    required this.highPriority,
    required this.affectedSchools,
    this.resolutionRate,
    this.averageResolutionHours,
  });

  factory AnalyticsSummary.fromJson(Map<String, dynamic> json) =>
      AnalyticsSummary(
        total: _int(json['total']),
        pending: _int(json['pending']),
        verified: _int(json['verified']),
        resolved: _int(json['resolved']),
        rejected: _int(json['rejected']),
        highPriority: _int(json['high_priority']),
        affectedSchools: _int(json['affected_schools']),
        resolutionRate: _nullableDouble(json['resolution_rate']),
        averageResolutionHours: _nullableDouble(
          json['average_resolution_hours'],
        ),
      );

  final int total;
  final int pending;
  final int verified;
  final int resolved;
  final int rejected;
  final int highPriority;
  final int affectedSchools;
  final double? resolutionRate;
  final double? averageResolutionHours;

  Map<String, dynamic> toJson() => {
    'total': total,
    'pending': pending,
    'verified': verified,
    'resolved': resolved,
    'rejected': rejected,
    'high_priority': highPriority,
    'affected_schools': affectedSchools,
    'resolution_rate': resolutionRate,
    'average_resolution_hours': averageResolutionHours,
  };
}

class AnalyticsTrendPoint {
  const AnalyticsTrendPoint({
    required this.period,
    required this.total,
    required this.pending,
    required this.verified,
    required this.resolved,
  });

  factory AnalyticsTrendPoint.fromJson(Map<String, dynamic> json) =>
      AnalyticsTrendPoint(
        period: _date(json['period']),
        total: _int(json['total']),
        pending: _int(json['pending']),
        verified: _int(json['verified']),
        resolved: _int(json['resolved']),
      );

  final DateTime period;
  final int total;
  final int pending;
  final int verified;
  final int resolved;

  Map<String, dynamic> toJson() => {
    'period': period.toIso8601String(),
    'total': total,
    'pending': pending,
    'verified': verified,
    'resolved': resolved,
  };
}

class AnalyticsBreakdown {
  const AnalyticsBreakdown({
    required this.key,
    required this.count,
    required this.percentage,
    this.previousCount,
  });

  factory AnalyticsBreakdown.fromJson(Map<String, dynamic> json) =>
      AnalyticsBreakdown(
        key: json['key'].toString(),
        count: _int(json['count']),
        percentage: _nullableDouble(json['percentage']) ?? 0,
        previousCount: json.containsKey('previous_count')
            ? _int(json['previous_count'])
            : null,
      );

  final String key;
  final int count;
  final double percentage;
  final int? previousCount;

  Map<String, dynamic> toJson() => {
    'key': key,
    'count': count,
    'percentage': percentage,
    if (previousCount != null) 'previous_count': previousCount,
  };
}

class AnalyticsMarker {
  const AnalyticsMarker({
    required this.id,
    required this.schoolId,
    required this.schoolName,
    required this.type,
    required this.severity,
    required this.status,
    required this.latitude,
    required this.longitude,
    required this.firstReportedAt,
    required this.duplicateCount,
    required this.distanceToSchoolMeters,
    this.resolvedAt,
  });

  factory AnalyticsMarker.fromJson(Map<String, dynamic> json) =>
      AnalyticsMarker(
        id: json['id'].toString(),
        schoolId: json['school_id'].toString(),
        schoolName: json['school_name']?.toString() ?? 'School unavailable',
        type: _hazardType(json['type']),
        severity: _int(json['severity']),
        status: _reportStatus(json['status']),
        latitude: _double(json['latitude']),
        longitude: _double(json['longitude']),
        firstReportedAt: _date(json['first_reported_at']),
        resolvedAt: _nullableDate(json['resolved_at']),
        duplicateCount: _int(json['duplicate_count']),
        distanceToSchoolMeters:
            _nullableDouble(json['distance_to_school_meters']) ?? 0,
      );

  final String id;
  final String schoolId;
  final String schoolName;
  final HazardType type;
  final int severity;
  final ReportStatus status;
  final double latitude;
  final double longitude;
  final DateTime firstReportedAt;
  final DateTime? resolvedAt;
  final int duplicateCount;
  final double distanceToSchoolMeters;

  LatLng get location => LatLng(latitude, longitude);

  Map<String, dynamic> toJson() => {
    'id': id,
    'school_id': schoolId,
    'school_name': schoolName,
    'type': _hazardTypeKey(type),
    'severity': severity,
    'status': status.name,
    'latitude': latitude,
    'longitude': longitude,
    'first_reported_at': firstReportedAt.toIso8601String(),
    'resolved_at': resolvedAt?.toIso8601String(),
    'duplicate_count': duplicateCount,
    'distance_to_school_meters': distanceToSchoolMeters,
  };
}

class SchoolAnalytics {
  const SchoolAnalytics({
    required this.id,
    required this.name,
    required this.district,
    required this.latitude,
    required this.longitude,
    required this.total,
    required this.pending,
    required this.verified,
    required this.resolved,
    required this.highPriority,
    required this.averageSeverity,
    required this.resolutionRate,
    required this.categories,
    required this.severities,
    this.city,
    this.state,
    this.averageResolutionHours,
  });

  factory SchoolAnalytics.fromJson(Map<String, dynamic> json) =>
      SchoolAnalytics(
        id: json['id'].toString(),
        name: json['name']?.toString() ?? 'School unavailable',
        district: json['district']?.toString() ?? 'District unavailable',
        city: json['city']?.toString(),
        state: json['state']?.toString(),
        latitude: _double(json['latitude']),
        longitude: _double(json['longitude']),
        total: _int(json['total']),
        pending: _int(json['pending']),
        verified: _int(json['verified']),
        resolved: _int(json['resolved']),
        highPriority: _int(json['high_priority']),
        averageSeverity: _nullableDouble(json['average_severity']) ?? 0,
        resolutionRate: _nullableDouble(json['resolution_rate']) ?? 0,
        averageResolutionHours: _nullableDouble(
          json['average_resolution_hours'],
        ),
        categories: _maps(json['categories'])
            .map(AnalyticsBreakdown.fromJson)
            .toList(),
        severities: _maps(json['severities'])
            .map(AnalyticsBreakdown.fromJson)
            .toList(),
      );

  final String id;
  final String name;
  final String district;
  final String? city;
  final String? state;
  final double latitude;
  final double longitude;
  final int total;
  final int pending;
  final int verified;
  final int resolved;
  final int highPriority;
  final double averageSeverity;
  final double resolutionRate;
  final double? averageResolutionHours;
  final List<AnalyticsBreakdown> categories;
  final List<AnalyticsBreakdown> severities;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'district': district,
    'city': city,
    'state': state,
    'latitude': latitude,
    'longitude': longitude,
    'total': total,
    'pending': pending,
    'verified': verified,
    'resolved': resolved,
    'high_priority': highPriority,
    'average_severity': averageSeverity,
    'resolution_rate': resolutionRate,
    'average_resolution_hours': averageResolutionHours,
    'categories': categories.map((value) => value.toJson()).toList(),
    'severities': severities.map((value) => value.toJson()).toList(),
  };
}

class AnalyticsSchoolOption {
  const AnalyticsSchoolOption({
    required this.id,
    required this.name,
    required this.district,
    required this.latitude,
    required this.longitude,
    this.city,
    this.state,
  });

  factory AnalyticsSchoolOption.fromJson(Map<String, dynamic> json) =>
      AnalyticsSchoolOption(
        id: json['id'].toString(),
        name: json['name']?.toString() ?? 'School unavailable',
        district: json['district']?.toString() ?? 'District unavailable',
        city: json['city']?.toString(),
        state: json['state']?.toString(),
        latitude: _double(json['latitude']),
        longitude: _double(json['longitude']),
      );

  final String id;
  final String name;
  final String district;
  final String? city;
  final String? state;
  final double latitude;
  final double longitude;
}

class DeduplicationInfo {
  const DeduplicationInfo({
    required this.method,
    required this.rawReports,
    required this.uniqueHazards,
    required this.duplicatesRemoved,
  });

  factory DeduplicationInfo.fromJson(Map<String, dynamic> json) =>
      DeduplicationInfo(
        method: json['method']?.toString() ?? '',
        rawReports: _int(json['raw_reports']),
        uniqueHazards: _int(json['unique_hazards']),
        duplicatesRemoved: _int(json['duplicates_removed']),
      );

  final String method;
  final int rawReports;
  final int uniqueHazards;
  final int duplicatesRemoved;

  Map<String, dynamic> toJson() => {
    'method': method,
    'raw_reports': rawReports,
    'unique_hazards': uniqueHazards,
    'duplicates_removed': duplicatesRemoved,
  };
}

class AnalyticsPagination {
  const AnalyticsPagination({
    required this.limit,
    required this.offset,
    required this.total,
    required this.hasMore,
  });

  factory AnalyticsPagination.fromJson(Map<String, dynamic> json) =>
      AnalyticsPagination(
        limit: _int(json['limit']),
        offset: _int(json['offset']),
        total: _int(json['total']),
        hasMore: json['has_more'] == true,
      );

  final int limit;
  final int offset;
  final int total;
  final bool hasMore;
}

Map<String, dynamic> _map(dynamic value) => value is Map
    ? value.map((key, item) => MapEntry(key.toString(), item))
    : <String, dynamic>{};

List<Map<String, dynamic>> _maps(dynamic value) =>
    value is List ? value.map(_map).toList(growable: false) : const [];

int _int(dynamic value) => value is num ? value.toInt() : 0;
double _double(dynamic value) => value is num ? value.toDouble() : 0;
double? _nullableDouble(dynamic value) =>
    value is num ? value.toDouble() : null;
DateTime _date(dynamic value) => DateTime.parse(value.toString());
DateTime? _nullableDate(dynamic value) =>
    value == null ? null : DateTime.tryParse(value.toString());

HazardType _hazardType(dynamic value) => switch (value?.toString()) {
  'missing_sidewalk' => HazardType.missingSidewalk,
  'difficult_crossing' => HazardType.difficultCrossing,
  'poor_lighting' => HazardType.poorLighting,
  'blocked_path' => HazardType.blockedPath,
  'bike_route' => HazardType.bikeRoute,
  _ => HazardType.missingSidewalk,
};

String _hazardTypeKey(HazardType value) => switch (value) {
  HazardType.missingSidewalk => 'missing_sidewalk',
  HazardType.difficultCrossing => 'difficult_crossing',
  HazardType.poorLighting => 'poor_lighting',
  HazardType.blockedPath => 'blocked_path',
  HazardType.bikeRoute => 'bike_route',
};

ReportStatus _reportStatus(dynamic value) => ReportStatus.values.firstWhere(
  (status) => status.name == value?.toString(),
  orElse: () => ReportStatus.unverified,
);
