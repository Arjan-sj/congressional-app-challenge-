import 'hazard_report.dart';
import '../services/hazard_codec.dart';

enum ModerationQueue {
  pending('Pending'),
  flagged('Flagged'),
  verified('Verified'),
  resolved('Resolved'),
  rejected('Rejected'),
  all('All');

  const ModerationQueue(this.label);
  final String label;
}

enum ModerationOrder {
  priority('Priority first'),
  oldest('Oldest first'),
  newest('Newest first');

  const ModerationOrder(this.label);
  final String label;
}

class ModerationScope {
  const ModerationScope({
    required this.id,
    required this.name,
    this.state = '',
    this.city = '',
    this.districtName = '',
  });
  factory ModerationScope.fromJson(Map<String, dynamic> json) =>
      ModerationScope(
        id: json['id'] as String,
        name: json['name'] as String,
        state: json['state'] as String? ?? '',
        city: json['city'] as String? ?? '',
        districtName: json['district_name'] as String? ?? '',
      );
  final String id, name, state, city, districtName;
}

class ModerationScopePage {
  ModerationScopePage.fromJson(Map<String, dynamic> json)
    : items = (json['items'] as List)
          .map(
            (r) =>
                ModerationScope.fromJson(Map<String, dynamic>.from(r as Map)),
          )
          .toList(),
      hasMore = json['has_more'] == true,
      cursor = json['next_cursor'] as String?;
  final List<ModerationScope> items;
  final bool hasMore;
  final String? cursor;
}

class ModerationQueueItem {
  ModerationQueueItem.fromJson(Map<String, dynamic> json)
    : report = HazardCodec.fromRow(
        Map<String, dynamic>.from(json['report'] as Map),
      ),
      schoolCity = json['school_city'] as String? ?? '',
      schoolState = json['school_state'] as String? ?? '',
      districtName =
          json['district_name'] as String? ?? 'Unassigned/Independent',
      openFlags = (json['open_flags'] as num? ?? 0).toInt();
  final HazardReport report;
  final String schoolCity, schoolState, districtName;
  final int openFlags;
}

class ModerationQueuePage {
  ModerationQueuePage.fromJson(Map<String, dynamic> json)
    : items = (json['items'] as List)
          .map(
            (r) => ModerationQueueItem.fromJson(
              Map<String, dynamic>.from(r as Map),
            ),
          )
          .toList(),
      counts = (json['counts'] as Map).map(
        (k, v) => MapEntry(k.toString(), (v as num).toInt()),
      ),
      total = (json['total'] as num).toInt(),
      offset = (json['offset'] as num).toInt(),
      limit = (json['limit'] as num).toInt(),
      hasMore = json['has_more'] == true;
  final List<ModerationQueueItem> items;
  final Map<String, int> counts;
  final int total, offset, limit;
  final bool hasMore;
}
