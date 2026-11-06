// A place shared from Google Maps on the head unit (Share › OPRivView), or a Maps link pasted into
// Navigate's search (Gerry 2026-11-06). The comma only needs the latitude and longitude, which
// Google's links carry: Maps shares the place's name and address and a short maps.app.goo.gl link,
// which redirects to the full google.com/maps link with the pin's coordinates in it. A link
// without coordinates falls back to looking the address up with the driver's MapTiler key.
//
// The Android side (ShareActivity.kt) passes the shared text on; SharedPlaces holds it until the
// app's screen takes it.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:opview/services/nav/maptiler.dart';
import 'package:opview/services/nav/places.dart';

/// the text of the latest share, waiting for the screen (AppShell) to take it; it may arrive while
/// the screen is not built yet (starting up, or in a picture-in-picture window)
class SharedPlaces extends ChangeNotifier {
  String? _waiting;

  void add(String text) {
    if (text.trim().isEmpty) return;
    _waiting = text;
    notifyListeners();
  }

  /// the waiting share, once
  String? take() {
    final t = _waiting;
    _waiting = null;
    return t;
  }
}

const _shareChannel = MethodChannel('org.dragonpilot.opview/share');

/// connects [into] to Android: a share that started the app, and every one after
void listenForShares(SharedPlaces into) {
  _shareChannel.setMethodCallHandler((call) async {
    if (call.method == 'shared' && call.arguments is String) into.add(call.arguments as String);
    return null;
  });
  _takeStarting(into);
}

Future<void> _takeStarting(SharedPlaces into) async {
  try {
    final t = await _shareChannel.invokeMethod<String>('takeShared');
    if (t != null) into.add(t);
  } on MissingPluginException {
    // not on Android
  } on PlatformException {
    // nothing waiting that can be read
  }
}

// -- reading what Maps shared --

final _urlPattern = RegExp(r'''(https?://[^\s<>"']+|geo:[^\s<>"']+)''', caseSensitive: false);

/// a Google Maps link (or geo: link) in [text], for Navigate's search box
bool looksLikeMapsLink(String text) {
  final m = _urlPattern.firstMatch(text);
  if (m == null) return false;
  final u = m.group(0)!.toLowerCase();
  return u.startsWith('geo:') ||
      u.contains('maps.app.goo.gl') ||
      u.contains('goo.gl/maps') ||
      u.contains('google.com/maps') ||
      u.contains('maps.google.') ||
      RegExp(r'google\.[a-z.]+/maps').hasMatch(u);
}

/// what a share says: its link, and the name and address written above it
class SharedText {
  final String? url;
  final String name;
  final String address;
  const SharedText({this.url, this.name = '', this.address = ''});
}

/// Maps shares "Name\nAddress\nhttps://maps.app.goo.gl/…" (sometimes only the link, or the name
/// and address on one line)
SharedText parseSharedText(String text) {
  final url = _urlPattern.firstMatch(text)?.group(0);
  final lines = [
    for (final l in text.replaceAll(_urlPattern, '').split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  if (lines.isEmpty) return SharedText(url: url);
  if (lines.length == 1) {
    // "Costco Wholesale, 2655 El Camino Real, Tustin, CA": the name, then the address
    final one = lines.first;
    final comma = one.indexOf(',');
    if (comma > 0 && RegExp(r'^\D').hasMatch(one)) {
      return SharedText(url: url, name: one.substring(0, comma).trim(), address: one.substring(comma + 1).trim());
    }
    return SharedText(url: url, name: one);
  }
  return SharedText(url: url, name: lines.first, address: lines.skip(1).join(', '));
}

(double, double)? _pair(String a, String b) {
  final lat = double.tryParse(a), lon = double.tryParse(b);
  if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return null;
  if (lat == 0 && lon == 0) return null;  // geo:0,0?q=address means "no coordinates"
  return (lat, lon);
}

const _num = r'(-?\d{1,3}(?:\.\d+)?)';

/// [s] with its %-escapes and +s decoded, or as it is when an escape is broken
String _decoded(String s) {
  final spaced = s.replaceAll('+', ' ');
  try {
    return Uri.decodeFull(spaced);
  } catch (_) {
    return spaced;
  }
}

/// the place's coordinates in a Google Maps (or geo:) link or page, best first: the pin
/// (!3d…!4d…), a query or destination of coordinates, geo:'s own, then the map's centre (@…)
(double, double)? coordinatesIn(String s) {
  final text = _decoded(s);
  for (final re in [
    RegExp('!3d$_num!4d$_num'),
    RegExp('[?&](?:q|query|ll|daddr|destination|center)=$_num,\\s*$_num'),
    RegExp('^geo:$_num,$_num', caseSensitive: false),
    RegExp('/maps/(?:place|search|dir)/$_num,\\s*$_num'),
    RegExp('@$_num,$_num'),
    RegExp('center=$_num(?:%2C|,)$_num'),
  ]) {
    final m = re.firstMatch(text);
    if (m == null) continue;
    final p = _pair(m.group(1)!, m.group(2)!);
    if (p != null) return p;
  }
  return null;
}

/// a name in the link itself, for a share that is only a link: `/maps/place/<name>/`, geo:'s
/// (label), or a query that is not coordinates
String nameInLink(String url) {
  final text = _decoded(url);
  final place = RegExp(r'/maps/place/([^/@?]+)').firstMatch(text)?.group(1);
  if (place != null && coordinatesIn('/maps/place/$place') == null) return place.trim();
  final label = RegExp(r'\(([^)]+)\)\s*$').firstMatch(text)?.group(1);
  if (label != null) return label.trim();
  final q = RegExp(r'[?&](?:q|query)=([^&]+)').firstMatch(text)?.group(1);
  if (q != null && coordinatesIn('?q=$q') == null) return q.trim();
  return '';
}

/// the place in a share: from the link's coordinates (following a short link to Google's full
/// one), else looked up by its address with MapTiler. Throws a StateError saying why not
Future<Place> resolveSharedPlace(
  String text, {
  required http.Client client,
  String? mapKey,
  double? lat,
  double? lon,
}) async {
  final shared = parseSharedText(text);
  final url = shared.url;
  var name = shared.name;
  var address = shared.address;
  (double, double)? at = url == null ? null : coordinatesIn(url);
  var linkName = url == null ? '' : nameInLink(url);

  if (at == null && url != null && url.toLowerCase().startsWith('http')) {
    final followed = await _follow(client, Uri.parse(url));
    at = followed.$1;
    if (linkName.isEmpty) linkName = followed.$2;
  }
  if (name.isEmpty && linkName.isNotEmpty) {
    final comma = linkName.indexOf(',');
    name = comma > 0 ? linkName.substring(0, comma).trim() : linkName;
    if (address.isEmpty && comma > 0) address = linkName.substring(comma + 1).trim();
  }
  if (at != null) {
    return Place(name: name.isEmpty ? 'Shared place' : name, address: address, lat: at.$1, lon: at.$2);
  }

  // no coordinates anywhere: look the place up by what the share says
  final query = [name, address].where((s) => s.isNotEmpty).join(', ');
  if (query.isEmpty) throw StateError("That isn't a place from Google Maps");
  if (mapKey == null) {
    throw StateError('That link has no location in it. Add a MapTiler key in Settings › Navigation to look up its address');
  }
  final found = await searchPlaces(client, mapKey, query, lat: lat, lon: lon);
  if (found.isEmpty) throw StateError('Could not find "$query"');
  final f = found.first;
  return Place(name: name.isEmpty ? f.name : name, address: address.isEmpty ? f.address : address, lat: f.lat, lon: f.lon);
}

/// follows a short link's redirects (and Google's cookie-consent page) to a link or page with
/// coordinates; also any place name met on the way
Future<((double, double)?, String)> _follow(http.Client client, Uri start) async {
  var uri = start;
  var name = '';
  try {
    for (var hop = 0; hop < 8; hop++) {
      final req = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll(mapTilerHeaders);
      final r = await client.send(req).timeout(const Duration(seconds: 8));
      final location = r.headers['location'];
      if (r.statusCode >= 300 && r.statusCode < 400 && location != null) {
        await r.stream.drain<void>();
        uri = uri.resolve(location);
        // consent.google.com/…?continue=<the real link>
        final cont = uri.queryParameters['continue'];
        if (uri.host.startsWith('consent.') && cont != null) uri = Uri.parse(cont);
        final s = uri.toString();
        if (name.isEmpty) name = nameInLink(s);
        final at = coordinatesIn(s);
        if (at != null) return (at, name);
        continue;
      }
      // the end of the redirects: the page may carry them (a map image's centre, the pin)
      final body = r.statusCode == 200 ? await r.stream.bytesToString() : '';
      if (r.statusCode != 200) await r.stream.drain<void>();
      final cont = uri.queryParameters['continue'];
      if (uri.host.startsWith('consent.') && cont != null) {
        uri = Uri.parse(cont);
        final at = coordinatesIn(cont);
        if (at != null) return (at, name.isEmpty ? nameInLink(cont) : name);
        continue;
      }
      return (body.isEmpty ? null : coordinatesIn(body.length > 400000 ? body.substring(0, 400000) : body), name);
    }
  } catch (e) {
    if (e is StateError) rethrow;
    throw StateError('Could not reach Google Maps: is the head unit online?');
  }
  return (null, name);
}
