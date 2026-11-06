// a place shared from Google Maps on the head unit: reading the share, Google's links, and
// following a short link to the coordinates

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/services/nav/shared_place.dart';

const _full = 'https://www.google.com/maps/place/Costco+Wholesale/@33.7345,-117.8160,17z/data=!3m1!4b1!4m6!3m5!1s0x80dcdb:0x1!8m2!3d33.7341!4d-117.8143!16s%2Fg%2F1tf';

void main() {
  group('reading a share', () {
    test('name, address and link on their own lines', () {
      final s = parseSharedText('Costco Wholesale\n2655 El Camino Real, Tustin, CA 92782\n\nhttps://maps.app.goo.gl/AbC123');
      expect(s.name, 'Costco Wholesale');
      expect(s.address, '2655 El Camino Real, Tustin, CA 92782');
      expect(s.url, 'https://maps.app.goo.gl/AbC123');
    });

    test('name and address on one line', () {
      final s = parseSharedText('Costco Wholesale, 2655 El Camino Real, Tustin https://maps.app.goo.gl/AbC123');
      expect(s.name, 'Costco Wholesale');
      expect(s.address, '2655 El Camino Real, Tustin');
    });

    test('a street address alone stays whole', () {
      final s = parseSharedText('2655 El Camino Real, Tustin\nhttps://maps.app.goo.gl/x');
      expect(s.name, '2655 El Camino Real, Tustin');
      expect(s.address, '');
    });

    test('only a link', () {
      final s = parseSharedText('  https://maps.app.goo.gl/AbC123  ');
      expect(s.url, 'https://maps.app.goo.gl/AbC123');
      expect(s.name, '');
    });

    test('Google Maps links are recognised, other links are not', () {
      expect(looksLikeMapsLink('https://maps.app.goo.gl/AbC123'), isTrue);
      expect(looksLikeMapsLink(_full), isTrue);
      expect(looksLikeMapsLink('https://www.google.co.uk/maps/place/x'), isTrue);
      expect(looksLikeMapsLink('https://maps.google.com/?q=33.7,-117.8'), isTrue);
      expect(looksLikeMapsLink('geo:33.7,-117.8'), isTrue);
      expect(looksLikeMapsLink('https://example.com/maps'), isFalse);
      expect(looksLikeMapsLink('costco tustin'), isFalse);
    });
  });

  group('coordinates in a link', () {
    test('the pin, before the map centre', () {
      expect(coordinatesIn(_full), (33.7341, -117.8143));
    });

    test('a query, a search, geo:, the map centre', () {
      expect(coordinatesIn('https://maps.google.com/?q=33.7341,-117.8143'), (33.7341, -117.8143));
      expect(coordinatesIn('https://www.google.com/maps/search/33.7341,+-117.8143?entry=tts'), (33.7341, -117.8143));
      expect(coordinatesIn('geo:33.7341,-117.8143?q=33.7341,-117.8143(Costco)'), (33.7341, -117.8143));
      expect(coordinatesIn('https://www.google.com/maps/@33.7,-117.8,15z'), (33.7, -117.8));
      expect(coordinatesIn('https://www.google.com/maps/dir/?api=1&destination=33.7341%2C-117.8143'), (33.7341, -117.8143));
    });

    test('none: an address query, geo:0,0, out of range', () {
      expect(coordinatesIn('https://maps.google.com/maps?q=Costco+Wholesale,+2655+El+Camino+Real&ftid=0x80dc:0x1'), isNull);
      expect(coordinatesIn('geo:0,0?q=2655+El+Camino+Real'), isNull);
      expect(coordinatesIn('https://www.google.com/maps/@133.7,-117.8,15z'), isNull);
      expect(coordinatesIn('https://maps.google.com/?q=%E0%A4%A'), isNull);  // a broken escape
    });

    test('a name in the link', () {
      expect(nameInLink(_full), 'Costco Wholesale');
      expect(nameInLink('geo:33.7,-117.8?q=33.7,-117.8(Costco Wholesale)'), 'Costco Wholesale');
      expect(nameInLink('https://maps.google.com/maps?q=Costco+Wholesale,+Tustin&ftid=1'), 'Costco Wholesale, Tustin');
      expect(nameInLink('https://www.google.com/maps/search/33.7341,+-117.8143'), '');
    });
  });

  group('resolving', () {
    /// answers by URL: a redirect, a page, or MapTiler's geocoding
    http.Client web(Map<String, http.Response Function()> answers, {List<String>? asked}) =>
        MockClient((r) async {
          asked?.add(r.url.toString());
          for (final e in answers.entries) {
            if (r.url.toString().startsWith(e.key)) return e.value();
          }
          return http.Response('not found', 404);
        });

    http.Response redirect(String to) => http.Response('', 302, headers: {'location': to});

    test('a short link is followed to the pin; the name comes from the share', () async {
      final asked = <String>[];
      final p = await resolveSharedPlace(
        'Costco Wholesale\n2655 El Camino Real, Tustin, CA\nhttps://maps.app.goo.gl/AbC123',
        client: web({'https://maps.app.goo.gl/AbC123': () => redirect(_full)}, asked: asked),
      );
      expect(p.name, 'Costco Wholesale');
      expect(p.address, '2655 El Camino Real, Tustin, CA');
      expect((p.lat, p.lon), (33.7341, -117.8143));
      expect(asked, ['https://maps.app.goo.gl/AbC123']);  // stopped once it had them
    });

    test('a link with the coordinates in it needs no request', () async {
      final p = await resolveSharedPlace(_full, client: web({}));
      expect(p.name, 'Costco Wholesale');
      expect((p.lat, p.lon), (33.7341, -117.8143));
    });

    test("through Google's cookie consent page", () async {
      final consent = 'https://consent.google.com/ml?continue=${Uri.encodeComponent(_full)}&gl=GB';
      final p = await resolveSharedPlace('https://maps.app.goo.gl/AbC123',
          client: web({'https://maps.app.goo.gl/': () => redirect(consent)}));
      expect((p.lat, p.lon), (33.7341, -117.8143));
      expect(p.name, 'Costco Wholesale');
    });

    test('several redirects, then a page with a map image centred on it', () async {
      final p = await resolveSharedPlace('Some Cafe\nhttps://maps.app.goo.gl/AbC123', client: web({
        'https://maps.app.goo.gl/': () => redirect('https://goo.gl/maps/xyz'),
        'https://goo.gl/maps/': () => redirect('https://www.google.com/maps?q=Some+Cafe&ftid=0x1'),
        'https://www.google.com/maps': () =>
            http.Response('<meta content="https://maps.google.com/maps/api/staticmap?center=49.2827%2C-123.1207&amp;zoom=15">', 200),
      }));
      expect((p.lat, p.lon), (49.2827, -123.1207));
      expect(p.name, 'Some Cafe');
    });

    test('no coordinates anywhere: the address is looked up with MapTiler', () async {
      final asked = <String>[];
      final p = await resolveSharedPlace('Some Cafe\n123 Main St, Vancouver\nhttps://maps.app.goo.gl/AbC123',
          mapKey: 'abcDEF1234567890',
          client: web({
            'https://maps.app.goo.gl/': () => http.Response('<html>no map here</html>', 200),
            'https://api.maptiler.com/geocoding/': () => http.Response(
                '{"features":[{"text":"Some Cafe","place_name":"Some Cafe, 123 Main St, Vancouver","center":[-123.1,49.28]}]}', 200),
          }, asked: asked));
      expect((p.lat, p.lon), (49.28, -123.1));
      expect(p.name, 'Some Cafe');
      expect(p.address, '123 Main St, Vancouver');
      expect(asked.last, contains('Some%20Cafe'));
    });

    test('no coordinates and no MapTiler key says so', () async {
      expect(
        () => resolveSharedPlace('Some Cafe\nhttps://maps.app.goo.gl/AbC123',
            client: web({'https://maps.app.goo.gl/': () => http.Response('<html></html>', 200)})),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('MapTiler key'))),
      );
    });

    test('offline says so', () async {
      expect(
        () => resolveSharedPlace('https://maps.app.goo.gl/AbC123', client: MockClient((_) async => throw Exception('no network'))),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Could not reach Google Maps'))),
      );
    });

    test('text with no place in it says so', () async {
      expect(() => resolveSharedPlace('   ', client: web({})), throwsA(isA<StateError>()));
    });
  });

  test('SharedPlaces keeps the latest share until it is taken, once', () {
    final s = SharedPlaces();
    var told = 0;
    s.addListener(() => told++);
    s.add('   ');
    expect(told, 0);
    s.add('a');
    s.add('b');
    expect(told, 2);
    expect(s.take(), 'b');
    expect(s.take(), isNull);
  });
}
