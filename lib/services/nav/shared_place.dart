// A place shared from Google Maps on the head unit (Share › OPRivView), or a Maps link pasted into
// Navigate's search (Gerry 2026-11-06). The comma only needs the latitude and longitude, which
// Google's links carry: Maps shares the place's name (and sometimes its address) and a short
// maps.app.goo.gl link. That redirects to a google.com/maps link, which may hold the pin's
// coordinates; if not, Google's page for it does, read as a desktop browser would (or the page
// for the place's id, maps?cid=). Only when Google gives no location at all is the place looked up
// by name with the driver's MapTiler key, near the truck, and then the driver picks the match:
// a guess is never sent to the comma by itself (a share of a post office went to Alaska).
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

/// the place's coordinates in a Google Maps (or geo:) link, best first: the pin (!3d…!4d…), a
/// query or destination of coordinates, geo:'s own, then the map's centre (@…)
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

/// the place's coordinates in a Google Maps page (as a desktop browser gets it): the pin, the
/// map's starting view (APP_INITIALIZATION_STATE=[[[scale, longitude, latitude]: longitude
/// first), or the preview image's centre. Pages carry other numbers, so nothing looser
(double, double)? coordinatesInPage(String page) {
  final body = page.length > 600000 ? page.substring(0, 600000) : page;
  final pin = RegExp('!3d$_num!4d$_num').firstMatch(body);
  if (pin != null) {
    final p = _pair(pin.group(1)!, pin.group(2)!);
    if (p != null) return p;
  }
  final start = RegExp(r'APP_INITIALIZATION_STATE=\[\[\[(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)\]').firstMatch(body);
  if (start != null) {
    final p = _pair(start.group(3)!, start.group(2)!);
    if (p != null) return p;
  }
  final centre = RegExp('center=$_num(?:%2C|,)$_num').firstMatch(body);
  if (centre != null) return _pair(centre.group(1)!, centre.group(2)!);
  return null;
}

/// Google's own id for a place, from its feature id (0x…:0x… in a link's !1s or ftid=): the
/// second half as a decimal, for maps.google.com/maps?cid=
String? placeCid(String s) {
  final m = RegExp(r'0x[0-9a-fA-F]+:0x([0-9a-fA-F]+)').firstMatch(s);
  if (m == null) return null;
  return BigInt.parse(m.group(1)!, radix: 16).toString();  // past a signed 64-bit int
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

/// what a share comes to: the [place] where Google itself puts it (safe to send at once), or,
/// when Google gives no location, [matches] found by name near the truck, for the driver to
/// choose from
class SharedResolution {
  final Place? place;
  final List<Place> matches;

  /// what the matches were looked up by
  final String lookedUp;

  const SharedResolution.exact(Place this.place)
      : matches = const [],
        lookedUp = '';
  const SharedResolution.matches(this.matches, this.lookedUp) : place = null;
}

/// a name lookup ignores places farther than this from the truck
const sharedMatchRadiusMetres = 300000.0;

/// Google answers a plain request with a page that carries no location; as a desktop browser
/// it gets the full page (Gerry's share, 2026-11-06). MapTiler requests keep OPRivView's own
const googleHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
  'Accept-Language': 'en',
};

/// the place in a share: from the link's coordinates (following a short link to Google's full
/// one and reading its page, then Google's place id page), else looked up by name near [lat],
/// [lon] with MapTiler. Throws a StateError saying why not
Future<SharedResolution> resolveSharedPlace(
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
  var cid = url == null ? null : placeCid(_decoded(url));

  if (at == null && url != null && url.toLowerCase().startsWith('http')) {
    final followed = await _follow(client, Uri.parse(url));
    at = followed.at;
    if (linkName.isEmpty) linkName = followed.name;
    cid ??= followed.cid;
    // Google's page for its id of the place, when the link's own page had no location
    if (at == null && cid != null) {
      at = (await _follow(client, Uri.parse('https://maps.google.com/maps?cid=$cid&hl=en'))).at;
    }
  }
  if (name.isEmpty && linkName.isNotEmpty) {
    final comma = linkName.indexOf(',');
    name = comma > 0 ? linkName.substring(0, comma).trim() : linkName;
    if (address.isEmpty && comma > 0) address = linkName.substring(comma + 1).trim();
  }
  if (at != null) {
    return SharedResolution.exact(Place(name: name.isEmpty ? 'Shared place' : name, address: address, lat: at.$1, lon: at.$2));
  }

  // no location anywhere: look it up by the fullest text there is, near the truck
  final query = [
    [name, address].where((s) => s.isNotEmpty).join(', '),
    linkName,
  ].reduce((a, b) => b.length > a.length ? b : a);
  if (query.isEmpty) throw StateError("That isn't a place from Google Maps");
  if (mapKey == null) {
    throw StateError('Google Maps did not say where "$query" is. Add a MapTiler key in Settings › Navigation to look it up');
  }
  var found = await searchPlaces(client, mapKey, query, lat: lat, lon: lon);
  if (lat != null && lon != null) {
    found = [for (final f in found) if (distanceMetres(lat, lon, f.lat, f.lon) <= sharedMatchRadiusMetres) f];
  }
  if (found.isEmpty) throw StateError('Could not find "$query"${lat != null ? ' near the truck' : ''}');
  return SharedResolution.matches(found.take(5).toList(), query);
}

/// a google.com/maps page asked for in English, the way the page was read when tested
Uri _english(Uri u) {
  final google = u.host.contains('google.') && u.path.startsWith('/maps');
  if (!google || u.queryParameters.containsKey('hl')) return u;
  return u.replace(queryParameters: {...u.queryParametersAll, 'hl': ['en']});
}

/// follows a short link's redirects (and Google's cookie-consent page) to a link or page with
/// coordinates; also any place name and Google place id met on the way
Future<({(double, double)? at, String name, String? cid})> _follow(http.Client client, Uri start) async {
  var uri = start;
  var name = '';
  String? cid;
  try {
    for (var hop = 0; hop < 8; hop++) {
      uri = _english(uri);
      final req = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll(googleHeaders);
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
        cid ??= placeCid(_decoded(s));
        final at = coordinatesIn(s);
        if (at != null) return (at: at, name: name, cid: cid);
        continue;
      }
      // the end of the redirects: the page may carry them (the map's view, its preview image)
      final body = r.statusCode == 200 ? await r.stream.bytesToString() : '';
      if (r.statusCode != 200) await r.stream.drain<void>();
      final cont = uri.queryParameters['continue'];
      if (uri.host.startsWith('consent.') && cont != null) {
        uri = Uri.parse(cont);
        final at = coordinatesIn(cont);
        if (at != null) return (at: at, name: name.isEmpty ? nameInLink(cont) : name, cid: cid);
        continue;
      }
      return (at: body.isEmpty ? null : coordinatesInPage(body), name: name, cid: cid);
    }
  } catch (e) {
    if (e is StateError) rethrow;
    throw StateError('Could not reach Google Maps: is the head unit online?');
  }
  return (at: null, name: name, cid: cid);
}
