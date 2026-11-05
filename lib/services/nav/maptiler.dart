// MapTiler Cloud: the map tiles and address search for Navigate (free plan; claude/oprivview-map-and-search-provider-research.md)
//
// The key comes in at build time (--dart-define=MAPTILER_KEY=..., the MAPTILER_KEY repository secret in
// the GitHub builds) and is restricted on MapTiler to requests whose User-Agent contains "OPRivView".
// Requests go straight from the head unit to MapTiler (their terms allow no proxy).

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:opview/services/nav/places.dart';

const mapTilerKey = String.fromEnvironment('MAPTILER_KEY');

/// MapTiler lets this key through only with "OPRivView" in the User-Agent
const mapTilerUserAgent = 'OPRivView/0.1 (Android head unit)';
const mapTilerHeaders = {'User-Agent': mapTilerUserAgent};

/// the dark street map, 256 px raster tiles (one API request each)
const mapTileUrl = 'https://api.maptiler.com/maps/streets-v2-dark/256/{z}/{x}/{y}.png?key=$mapTilerKey';

/// shown on the map, as MapTiler's and OpenStreetMap's terms ask
const mapAttribution = '© MapTiler © OpenStreetMap contributors';

const hasMapKey = mapTilerKey != '';

/// the geocoding request for [query], ranked near [lat], [lon] when known
Uri geocodingUri(String query, {double? lat, double? lon, String key = mapTilerKey}) => Uri.https(
      'api.maptiler.com',
      // Uri.https encodes the path itself; a slash would split it
      '/geocoding/${query.trim().replaceAll('/', ' ')}.json',
      {
        'key': key,
        'autocomplete': 'true',
        'limit': '6',
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

/// search-as-you-type; throws on a network or MapTiler error
Future<List<Place>> searchPlaces(http.Client client, String query, {double? lat, double? lon}) async {
  if (!hasMapKey) throw StateError('This build has no MapTiler key');
  final r = await client.get(geocodingUri(query, lat: lat, lon: lon), headers: mapTilerHeaders).timeout(const Duration(seconds: 8));
  if (r.statusCode != 200) throw StateError('Search failed (${r.statusCode})');
  return parseGeocoding(r.body);
}
