// places for Navigate: search results, Home / Work and recent destinations

import 'dart:math';

class Place {
  final String name;
  final String address;
  final double lat;
  final double lon;

  const Place({required this.name, required this.address, required this.lat, required this.lon});

  /// the same place under another name
  Place named(String newName) => Place(name: newName, address: address, lat: lat, lon: lon);

  Map<String, dynamic> toJson() => {'name': name, 'address': address, 'lat': lat, 'lon': lon};

  static Place? fromJson(Object? j) {
    if (j is! Map) return null;
    final lat = j['lat'], lon = j['lon'];
    if (lat is! num || lon is! num) return null;
    return Place(name: j['name'] as String? ?? '', address: j['address'] as String? ?? '', lat: lat.toDouble(), lon: lon.toDouble());
  }

  /// the same spot (to ~1 m)
  bool sameSpot(Place o) => (lat - o.lat).abs() < 1e-5 && (lon - o.lon).abs() < 1e-5;

  @override
  bool operator ==(Object other) => other is Place && other.name == name && other.address == address && sameSpot(other);

  @override
  int get hashCode => Object.hash(name, address, (lat * 1e5).round(), (lon * 1e5).round());
}

/// metres between two points (haversine)
double distanceMetres(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = pow(sin(dLat / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLon / 2), 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}

/// "0.3 mi", "12.4 mi", "800 ft"; metric "450 m", "2.1 km"
String formatNavDistance(double metres, bool metric) {
  if (metric) {
    if (metres < 1000) return '${(metres / 10).round() * 10} m';
    return '${(metres / 1000).toStringAsFixed(metres < 100000 ? 1 : 0)} km';
  }
  final miles = metres / 1609.344;
  if (miles < 0.1) return '${(metres * 3.28084 / 50).round() * 50} ft';
  return '${miles.toStringAsFixed(miles < 100 ? 1 : 0)} mi';
}

/// "19 min", "1 h 5 min"
String formatNavDuration(double seconds) {
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  return '${m ~/ 60} h ${m % 60} min';
}

/// "6:02 PM"
String formatArrival(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// recent destinations, newest first, without repeats, at most [max]
List<Place> addRecent(List<Place> recents, Place p, {int max = 6}) =>
    [p, ...recents.where((r) => !r.sameSpot(p))].take(max).toList();
