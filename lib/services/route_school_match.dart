import '../models/school.dart';

/// Uses the directory's ILIKE results and favors an exact school-name match
/// without relying on capitalization or minor punctuation differences.
class RouteSchoolMatch {
  const RouteSchoolMatch._();

  static String normalize(String value) =>
      value.toLowerCase().trim().replaceAll(RegExp(r'[\s.,_-]+'), ' ');

  static School? uniqueBestMatch(String query, List<School> schools) {
    if (schools.isEmpty) return null;
    final normalized = normalize(query);
    final exactNames = schools
        .where((school) => normalize(school.name) == normalized)
        .toList(growable: false);
    if (exactNames.length == 1) return exactNames.single;
    if (exactNames.length > 1) return null;
    return schools.length == 1 ? schools.single : null;
  }

  static String ambiguousMessage(List<School> schools) {
    final names = schools.take(3).map((s) => '${s.name} (${s.city}, ${s.state})');
    return 'Multiple schools matched: ${names.join('; ')}. '
        'Enter the full school name or choose the location on the map.';
  }
}
