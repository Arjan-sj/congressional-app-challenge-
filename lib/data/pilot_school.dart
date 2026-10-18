import 'package:latlong2/latlong.dart';

/// Pilot school only. Approximate campus map position, not an entrance
/// coordinate, walking route, or a verified point of access.
///
/// Source: public school directory coordinates for Schaumburg High School,
/// 1100 W Schaumburg Rd, Schaumburg, IL 60194.
/// https://www.usacitymap.com/schaumburg-high-school-173045003167-school-detail.html
class PilotSchool {
  static const id = 'sample-school';
  static const name = 'Schaumburg High School';
  static const address = '1100 W Schaumburg Rd, Schaumburg, IL';

  // Converted from 42°01′38.6976″N 88°06′23.8752″W.
  static const double latitude = 42.027416;
  static const double longitude = -88.106632;

  static const LatLng location = LatLng(latitude, longitude);
}
