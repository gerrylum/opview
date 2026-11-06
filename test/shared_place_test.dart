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
    http.Client web(Map<String, http.Response Function()> answers, {List<String>? asked, List<String>? agents}) =>
        MockClient((r) async {
          asked?.add(r.url.toString());
          agents?.add('${r.url.host} ${r.headers['User-Agent']}');
          for (final e in answers.entries) {
            if (r.url.toString().startsWith(e.key)) return e.value();
          }
          return http.Response('not found', 404);
        });

    http.Response redirect(String to) => http.Response('', 302, headers: {'location': to});

    test('a short link is followed to the pin; the name comes from the share', () async {
      final asked = <String>[];
      final p = (await resolveSharedPlace(
        'Costco Wholesale\n2655 El Camino Real, Tustin, CA\nhttps://maps.app.goo.gl/AbC123',
        client: web({'https://maps.app.goo.gl/AbC123': () => redirect(_full)}, asked: asked),
      ))
          .place!;
      expect(p.name, 'Costco Wholesale');
      expect(p.address, '2655 El Camino Real, Tustin, CA');
      expect((p.lat, p.lon), (33.7341, -117.8143));
      expect(asked, ['https://maps.app.goo.gl/AbC123']);  // stopped once it had them
    });

    test('a link with the coordinates in it needs no request', () async {
      final p = (await resolveSharedPlace(_full, client: web({}))).place!;
      expect(p.name, 'Costco Wholesale');
      expect((p.lat, p.lon), (33.7341, -117.8143));
    });

    test("through Google's cookie consent page", () async {
      final consent = 'https://consent.google.com/ml?continue=${Uri.encodeComponent(_full)}&gl=GB';
      final p = (await resolveSharedPlace('https://maps.app.goo.gl/AbC123',
              client: web({'https://maps.app.goo.gl/': () => redirect(consent)})))
          .place!;
      expect((p.lat, p.lon), (33.7341, -117.8143));
      expect(p.name, 'Costco Wholesale');
    });

    test("several redirects; the page at the end is not read: its map is centred on the viewer", () async {
      expect(
        () => resolveSharedPlace('Some Cafe\nhttps://maps.app.goo.gl/AbC123',
            client: web({
              'https://maps.app.goo.gl/': () => redirect('https://goo.gl/maps/xyz'),
              'https://goo.gl/maps/': () => redirect('https://www.google.com/maps?q=Some+Cafe&ftid=0x1'),
              // Gerry's area, whatever the place: never taken as the place
              'https://www.google.com/maps': () => http.Response(
                  '<meta content="https://maps.google.com/maps/api/staticmap?center=33.2332013%2C-96.9736192">'
                  '<script>APP_INITIALIZATION_STATE=[[[13349.08,-96.9736192,33.2332013]</script>',
                  200),
            })),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('MapTiler key'))),
      );
    });

    test('no coordinates anywhere: the address is looked up with MapTiler, as matches to pick', () async {
      final asked = <String>[];
      final r = await resolveSharedPlace('Some Cafe\n123 Main St, Vancouver\nhttps://maps.app.goo.gl/AbC123',
          mapKey: 'abcDEF1234567890',
          client: web({
            'https://maps.app.goo.gl/': () => http.Response('<html>no map here</html>', 200),
            'https://api.maptiler.com/geocoding/': () => http.Response(
                '{"features":[{"text":"Some Cafe","place_name":"Some Cafe, 123 Main St, Vancouver","center":[-123.1,49.28]}]}', 200),
          }, asked: asked));
      expect(r.place, isNull);  // a lookup is never sent by itself
      final p = r.matches.single;
      expect((p.lat, p.lon), (49.28, -123.1));
      expect(p.name, 'Some Cafe');
      expect(p.address, '123 Main St, Vancouver');
      expect(r.lookedUp, 'Some Cafe, 123 Main St, Vancouver');
      expect(asked.last, contains('Some%20Cafe'));
    });

    group("Gerry's post office (2026-11-06): a link with only Google's place id", () {
      const short = 'https://maps.app.goo.gl/WU4joGu8mEP69MQj7?g_st=ac';
      const place = 'https://www.google.com/maps/place/United+States+Postal+Service/data=!4m2!3m1!1s0x864c4974e2a517b3:0x8f13584efcc38069!18m1!1e1?utm_source=mstt_1&entry=gps&g_st=ac';

      test("Google's page is the same generic one for every place (centred on the viewer): not used", () async {
        const generic = '<html><script>window.APP_INITIALIZATION_STATE=[[[13349.083878244373,-96.9736192,33.2332013]</script>'
            '<meta content="https://maps.google.com/maps/api/staticmap?center=33.2332013%2C-96.9736192"></html>';
        expect(
          () => resolveSharedPlace(short,
              client: web({
                short: () => redirect(place),
                'https://www.google.com/': () => http.Response(generic, 200),
                'https://maps.google.com/': () => http.Response(generic, 200),
              })),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('"United States Postal Service"'))),
        );
      });

      test('no location from Google at all: matches near the truck only, never Alaska', () async {
        final r = await resolveSharedPlace('United States Post Office\n$short',
            mapKey: 'abcDEF1234567890',
            lat: 33.30,
            lon: -96.98,
            client: web({
              short: () => redirect(place),
              'https://www.google.com/': () => http.Response('<html></html>', 200),
              'https://maps.google.com/': () => http.Response('<html></html>', 200),
              'https://api.maptiler.com/geocoding/': () => http.Response(
                  '{"features":['
                  '{"text":"United States Post Office","place_name":"United States Post Office, Nome, Alaska","center":[-165.4,64.5]},'
                  '{"text":"United States Post Office","place_name":"United States Post Office, Aubrey, Texas","center":[-96.9736,33.2332]}]}',
                  200),
            }));
        expect(r.place, isNull);
        expect(r.matches.single.address, 'Aubrey, Texas');
        // the fullest text: the place page's name ("Postal Service") is longer than the share's
        expect(r.lookedUp, 'United States Postal Service');
      });

      test('nothing near the truck says so', () async {
        expect(
          () => resolveSharedPlace('United States Post Office',
              mapKey: 'abcDEF1234567890',
              lat: 33.30,
              lon: -96.98,
              client: web({
                'https://api.maptiler.com/geocoding/': () => http.Response(
                    '{"features":[{"text":"United States Post Office","place_name":"x, Nome, Alaska","center":[-165.4,64.5]}]}', 200),
              })),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('near the truck'))),
        );
      });
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
