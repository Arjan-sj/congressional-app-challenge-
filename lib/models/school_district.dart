/// A canonical public NCES district or an explicitly identified legacy filter.
class AnalyticsDistrictOption {
  const AnalyticsDistrictOption({
    required this.id,
    required this.name,
    this.state,
    this.sourceYear,
    this.schoolCount = 0,
    this.legacy = false,
  });

  factory AnalyticsDistrictOption.fromJson(Map<String, dynamic> json) =>
      AnalyticsDistrictOption(
        id: json['id'].toString(),
        name: json['name']?.toString() ?? 'District unavailable',
        state: json['state']?.toString(),
        sourceYear: json['source_year']?.toString(),
        schoolCount: (json['school_count'] as num?)?.toInt() ?? 0,
        legacy: json['legacy'] == true,
      );

  final String id;
  final String name;
  final String? state;
  final String? sourceYear;
  final int schoolCount;
  final bool legacy;

  String get displayLabel => legacy
      ? '$name (unlinked)'
      : '$name · ${state ?? 'State unavailable'} · NCES ${id.replaceFirst('nces-lea:', '')}';
}
