// MapTiler Cloud: the map tiles and address search for Navigate (free plan; claude/oprivview-map-and-search-provider-research.md)
//
// Each driver brings their own free key (Gerry 2026-11-05: no key in the builds), entered in
// Settings > Navigation and kept in AppSettings.mapTilerKey. A key can be left unrestricted or be
// restricted on MapTiler to a User-Agent containing "OPRivView", which every request here sends.
// Requests go straight from the head unit to MapTiler (their terms allow no proxy).

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:opview/services/nav/places.dart';

/// a key restricted to OPRivView needs "OPRivView" in the User-Agent
const mapTilerUserAgent = 'OPRivView/0.1 (Android head unit)';
const mapTilerHeaders = {'User-Agent': mapTilerUserAgent};

/// the street map's 256 px raster tiles (one API request each), dark or [light]
String mapTileUrl(String key, {bool light = false}) =>
    'https://api.maptiler.com/maps/${light ? 'streets-v2' : 'streets-v2-dark'}/256/{z}/{x}/{y}.png?key=${Uri.encodeQueryComponent(key)}';

/// shown on the map, as MapTiler's and OpenStreetMap's terms ask
const mapAttribution = '© MapTiler © OpenStreetMap contributors';

/// where to get a key, for Settings and Navigate
const mapTilerKeyHelp = 'Free at maptiler.com: sign up, then Account › API keys. '
    'Leave the key unrestricted, or allow the User-Agent "OPRivView".';

/// the geocoding request for [query], ranked near [lat], [lon] when known
Uri geocodingUri(String query, {required String key, double? lat, double? lon, int limit = 6}) => Uri.https(
      'api.maptiler.com',
      // Uri.https encodes the path itself; a slash would split it
      '/geocoding/${query.trim().replaceAll('/', ' ')}.json',
      {
        'key': key,
        'autocomplete': 'true',
        'limit': '$limit',
        if (lat != null && lon != null) 'proximity': '$lon,$lat',
      },
    );

/// places from a MapTiler geocoding answer (GeoJSON features: text, place_name, center [lon, lat])
List<Place> parseGeocoding(String body) {
  final j = jsonDecode(body);
  if (j is! Map) return [];
  final out = <Place>[];
  for (final f in (j['features'] as List? ?? const [])) {
    if (f is! Map) continue;
    final c = f['center'];
    if (c is! List || c.length < 2 || c[0] is! num || c[1] is! num) continue;
    final name = (f['text'] as String? ?? '').trim();
    var address = (f['place_name'] as String? ?? '').trim();
    // place_name repeats the name first: "Costco, 2655 El Camino Real, Tustin, ..."
    if (name.isNotEmpty && address.startsWith(name)) address = address.substring(name.length).replaceFirst(RegExp(r'^,\s*'), '');
    out.add(Place(name: name.isEmpty ? address : name, address: address, lat: (c[1] as num).toDouble(), lon: (c[0] as num).toDouble()));
  }
  return out;
}

/// what a refusal from MapTiler means, for the driver
String mapTilerRefusal(int status) => switch (status) {
      400 || 401 || 403 => 'MapTiler refused the key ($status): check it, and that it allows the User-Agent "OPRivView"',
      429 => 'The MapTiler key is over its free limit for now (429)',
      _ => 'MapTiler answered $status',
    };

/// search-as-you-type with [key]; throws on a network or MapTiler error
Future<List<Place>> searchPlaces(http.Client client, String key, String query, {double? lat, double? lon}) async {
  final r = await client
      .get(geocodingUri(query, key: key, lat: lat, lon: lon), headers: mapTilerHeaders)
      .timeout(const Duration(seconds: 8));
  if (r.statusCode != 200) throw StateError('Search failed: ${mapTilerRefusal(r.statusCode)}');
  return parseGeocoding(r.body);
}

/// whether [key] works: one small search. Null when it does, otherwise why not
Future<String?> checkMapTilerKey(http.Client client, String key) async {
  final k = key.trim();
  if (k.isEmpty) return 'Enter a key';
  if (!RegExp(r'^[A-Za-z0-9_-]{10,}$').hasMatch(k)) return "That doesn't look like a MapTiler key: letters and digits, no spaces";
  try {
    final r = await client.get(geocodingUri('Main Street', key: k, limit: 1), headers: mapTilerHeaders).timeout(const Duration(seconds: 8));
    return r.statusCode == 200 ? null : mapTilerRefusal(r.statusCode);
  } catch (_) {
    return 'Could not reach MapTiler: is the head unit online?';
  }
}
