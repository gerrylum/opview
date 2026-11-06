// Navigate: MapTiler search, the comma's GPS / route / next turn, the Navigate screen, and the
// turn banner and mini map on the driving view

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/selfdrive/ui/navigate/nav_map.dart';
import 'package:opview/selfdrive/ui/navigate/navigate_view.dart';
import 'package:opview/selfdrive/ui/navigate/turn_banner.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'package:opview/services/nav/maptiler.dart';
import 'package:opview/services/nav/places.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

const _costco = Place(name: 'Costco Wholesale', address: '2655 El Camino Real, Tustin, CA', lat: 33.7341, lon: -117.8143);
const _gas = Place(name: 'Costco Gasoline', address: '2655 El Camino Real, Tustin, CA', lat: 33.7337, lon: -117.8131);

void _screen(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// a truck on the 5 in Tustin, routing to Costco
UIState _routing() {
  final st = createMockUIState()..isMetric = false;
  st.applyGps({'latitude': 33.7175, 'longitude': -117.8311, 'bearingDeg': 45.0, 'speed': 20.0, 'hasFix': true});
  st.applyOpviewParams({'NavigationEnabled': true, 'NavDestination': {'latitude': _costco.lat, 'longitude': _costco.lon}});
  st.applyNavInstruction({
    'maneuverPrimaryText': 'Red Hill Ave',
    'maneuverType': 'turn',
    'maneuverModifier': 'right',
    'maneuverDistance': 480.0,
    'distanceRemaining': 19950.0,
    'timeRemaining': 1140.0,
  }, valid: true);
  st.applyNavRoute({
    'coordinates': [
      [33.7175, -117.8311],
      [33.7250, -117.8250],
      [33.7341, -117.8143],
    ]
  });
  return st;
}

void main() {
  group('MapTiler', () {
    test('the search request', () {
      final u = geocodingUri('costco tus', lat: 33.7, lon: -117.8, key: 'K');
      expect(u.host, 'api.maptiler.com');
      expect(u.path, '/geocoding/costco%20tus.json');
      expect(u.queryParameters['key'], 'K');
      expect(u.queryParameters['proximity'], '-117.8,33.7');
      expect(u.queryParameters['autocomplete'], 'true');
      expect(geocodingUri('x', key: 'K').queryParameters.containsKey('proximity'), isFalse);
    });

    test('the answer', () {
      final places = parseGeocoding('''{"type":"FeatureCollection","features":[
        {"text":"Costco","place_name":"Costco, 2655 El Camino Real, Tustin, California, United States","center":[-117.8143,33.7341]},
        {"text":"","place_name":"Somewhere Rd","center":[-117.0,33.0]},
        {"text":"Broken","place_name":"x","center":[1]}
      ]}''');
      expect(places.length, 2);
      expect(places[0].name, 'Costco');
      expect(places[0].address, '2655 El Camino Real, Tustin, California, United States');
      expect(places[0].lat, 33.7341);
      expect(places[0].lon, -117.8143);
      expect(places[1].name, 'Somewhere Rd');
      expect(parseGeocoding('[]'), isEmpty);
    });

    test('requests say OPRivView, which the key is restricted to', () {
      expect(mapTilerUserAgent, contains('OPRivView'));
    });

    test('tiles with the driver\'s key, dark or light', () {
      expect(mapTileUrl('K1'), 'https://api.maptiler.com/maps/streets-v2-dark/256/{z}/{x}/{y}.png?key=K1');
      expect(mapTileUrl('K1', light: true), 'https://api.maptiler.com/maps/streets-v2/256/{z}/{x}/{y}.png?key=K1');
    });

    test('a key is tried before it is saved', () async {
      Uri? asked;
      Map<String, String>? headers;
      http.Client answering(int status) => MockClient((r) async {
            asked = r.url;
            headers = r.headers;
            return http.Response('{"features":[]}', status);
          });
      expect(await checkMapTilerKey(answering(200), '  abcDEF1234567890 '), isNull);
      expect(asked!.queryParameters['key'], 'abcDEF1234567890');
      expect(headers!['User-Agent'], contains('OPRivView'));
      expect(await checkMapTilerKey(answering(403), 'abcDEF1234567890'), contains('refused the key (403)'));
      expect(await checkMapTilerKey(answering(429), 'abcDEF1234567890'), contains('free limit'));
      expect(await checkMapTilerKey(answering(200), ''), 'Enter a key');
      expect(await checkMapTilerKey(answering(200), 'not a key!'), contains("doesn't look like"));
      final offline = MockClient((_) async => throw const SocketExceptionLike());
      expect(await checkMapTilerKey(offline, 'abcDEF1234567890'), contains('Could not reach MapTiler'));
    });

    test('a refused search says why', () async {
      final c = MockClient((_) async => http.Response('', 403));
      expect(() => searchPlaces(c, 'abcDEF1234567890', 'costco'),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('refused the key'))));
    });
  });

  group('places', () {
    test('distances and times', () {
      // about 2.4 km between the truck and Costco
      expect(distanceMetres(33.7175, -117.8311, 33.7341, -117.8143), closeTo(2400, 60));
      expect(formatNavDistance(480, false), '0.3 mi');
      expect(formatNavDistance(19950, false), '12.4 mi');
      expect(formatNavDistance(100, false), '350 ft');
      expect(formatNavDistance(450, true), '450 m');
      expect(formatNavDistance(2100, true), '2.1 km');
      expect(formatNavDuration(1140), '19 min');
      expect(formatNavDuration(3900), '1 h 5 min');
      expect(formatArrival(DateTime(2026, 11, 5, 18, 2)), '6:02 PM');
    });

    test('recents: newest first, no repeats, six at most', () {
      var r = <Place>[];
      for (var i = 0; i < 8; i++) {
        r = addRecent(r, Place(name: 'p$i', address: '', lat: i.toDouble(), lon: 0));
      }
      expect(r.length, 6);
      expect(r.first.name, 'p7');
      r = addRecent(r, Place(name: 'again', address: '', lat: 3, lon: 0));
      expect(r.first.name, 'again');
      expect(r.where((p) => p.lat == 3).length, 1);
    });

    test('Home, Work and recents are remembered', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      await a.setNavHome(_costco);
      await a.addNavRecent(_gas);
      final b = AppSettings();
      await b.load();
      expect(b.navHome, _costco);
      expect(b.navWork, isNull);
      expect(b.navRecents, [_gas]);
      await b.clearNavRecents();
      expect(b.navRecents, isEmpty);
    });
  });

  group('from the comma', () {
    test('GPS, the route, the next turn and the destination', () {
      final st = _routing();
      expect(st.gpsFix, isTrue);
      expect(st.gpsBearing, 45.0);
      expect(st.navRoute.length, 3);
      expect(st.navDestination, (_costco.lat, _costco.lon));
      expect(st.navigating, isTrue);
      // stopped: the bearing is kept
      st.applyGps({'latitude': 33.7176, 'longitude': -117.8310, 'bearingDeg': 200.0, 'speed': 0.2, 'hasFix': true});
      expect(st.gpsBearing, 45.0);
      // no fix
      st.applyGps({'latitude': 0.0, 'longitude': 0.0, 'hasFix': false});
      expect(st.gpsFix, isFalse);
    });

    test('navd says there is no route; the destination is cleared', () {
      final st = _routing();
      CerealAdapter().apply(st, '{"type": "navInstruction", "valid": false, "data": {}}');
      expect(st.navValid, isFalse);
      expect(st.navigating, isFalse);
      st.applyOpviewParams({'NavDestination': null});
      expect(st.navDestination, isNull);
    });

    test('the route in navd\'s own shape too (older webrtcd)', () {
      final st = UIState();
      CerealAdapter().apply(st, '{"type": "navRoute", "data": {"coordinates": [{"latitude": 1.5, "longitude": 2.5}]}}');
      expect(st.navRoute, [(1.5, 2.5)]);
    });

    test('the comma\'s answer to a destination', () {
      final st = UIState();
      CerealAdapter().apply(st, '{"type": "navDestinationResult", "data": {"ok": false, "error": "latitude or longitude out of range"}}');
      expect(st.navDestinationError, 'latitude or longitude out of range');
      CerealAdapter().apply(st, '{"type": "navDestinationResult", "data": {"ok": true, "error": null}}');
      expect(st.navDestinationError, '');
    });
  });

  group('driving view', () {
    test('turn arrows', () {
      expect(maneuverIcon('turn', 'right'), Icons.turn_right);
      expect(maneuverIcon('turn', 'slight left'), Icons.turn_slight_left);
      expect(maneuverIcon('arrive', ''), Icons.flag);
      expect(maneuverIcon('off ramp', 'left'), Icons.ramp_left);
      expect(maneuverIcon('roundabout', 'right'), Icons.roundabout_right);
      expect(maneuverIcon('new name', 'straight'), Icons.straight);
    });

    test('heading up: the map turns against the heading', () {
      expect(headingUpRotation(90), -90);
    });

    testWidgets('navigating: the turn banner, and the mini map where the steering readout was', (tester) async {
      _screen(tester, 1920, 1080);
      final st = _routing();
      final settings = AppSettings()..mapTilerKey = 'testkey1234567890';
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: st, settings: settings, mapTiles: false)));
      expect(find.byKey(const ValueKey('turnBanner')), findsOneWidget);
      expect(find.text('0.3 mi'), findsOneWidget);
      expect(find.text('Red Hill Ave'), findsOneWidget);
      expect(find.text('19 min'), findsOneWidget);
      expect(find.byKey(const ValueKey('miniMap')), findsOneWidget);
      expect(find.byType(EnhancedSteeringPills), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without a MapTiler key: the turn banner, but no mini map', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: _routing(), settings: AppSettings(), mapTiles: false)));
      expect(find.byKey(const ValueKey('turnBanner')), findsOneWidget);
      expect(find.byKey(const ValueKey('miniMap')), findsNothing);
      expect(find.byType(EnhancedSteeringPills), findsOneWidget);
    });

    testWidgets('both can be turned off; not navigating shows neither', (tester) async {
      _screen(tester, 1920, 1080);
      final settings = AppSettings()..hiddenSections.addAll([DriveSection.turnBanner, DriveSection.miniMap]);
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: _routing(), settings: settings)));
      expect(find.byKey(const ValueKey('turnBanner')), findsNothing);
      expect(find.byKey(const ValueKey('miniMap')), findsNothing);
      expect(find.byType(EnhancedSteeringPills), findsOneWidget);
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: createMockUIState(), settings: AppSettings())));
      expect(find.byKey(const ValueKey('turnBanner')), findsNothing);
      expect(find.byKey(const ValueKey('miniMap')), findsNothing);
    });
  });

  group('Navigate screen', () {
    late List<(double, double)?> sent;
    late AppSettings settings;
    late bool closed;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      sent = [];
      settings = AppSettings();
      closed = false;
    });

    Future<void> show(WidgetTester tester, UIState st, {double w = 1770, double h = 916, bool searchable = true, VoidCallback? onAddKey}) async {
      _screen(tester, w, h);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,  // as in AppShell: the keyboard covers, nothing shrinks
          body: NavigateView(
            uiState: st,
            settings: settings,
            unit: w / 1770,
            tiles: false,
            send: (d) async {
              sent.add(d);
              return true;
            },
            onClose: () => closed = true,
            onAddKey: onAddKey,
            search: searchable ? ((q, lat, lon) async => q.toLowerCase().startsWith('cost') ? [_costco, _gas] : <Place>[]) : null,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('search, pick: the destination goes to the comma, the card waits for its route', (tester) async {
      final st = createMockUIState()
        ..isMetric = false
        ..applyGps({'latitude': 33.7175, 'longitude': -117.8311, 'bearingDeg': 45.0, 'speed': 20.0, 'hasFix': true})
        ..applyOpviewParams({'NavigationEnabled': true});
      await show(tester, st);
      expect(find.byKey(const ValueKey('navSearchPanel')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('navSearchField')), 'costco tus');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('Costco Wholesale'), findsOneWidget);
      expect(find.text('Costco Gasoline'), findsOneWidget);
      expect(find.text('1.5 mi'), findsNWidgets(2));  // from the truck
      await tester.tap(find.byKey(const ValueKey('navResult_Costco Wholesale')));
      await tester.pump();
      expect(sent, [(_costco.lat, _costco.lon)]);
      expect(settings.navRecents.first, _costco);
      expect(find.byKey(const ValueKey('navRouteCard')), findsOneWidget);
      expect(find.byKey(const ValueKey('navPlanning')), findsOneWidget);

      // navd plans it
      st.applyOpviewParams({'NavDestination': {'latitude': _costco.lat, 'longitude': _costco.lon}});
      st.applyNavInstruction({'distanceRemaining': 19950.0, 'timeRemaining': 1140.0}, valid: true);
      st.notifyNow();
      await tester.pump();
      expect(find.byKey(const ValueKey('navEta')), findsOneWidget);
      expect(find.text('19 min'), findsOneWidget);
      expect(find.text('12.4 mi'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('navStart')));
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cancel clears the destination on the comma', (tester) async {
      await show(tester, createMockUIState());
      await tester.enterText(find.byKey(const ValueKey('navSearchField')), 'costco');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('navResult_Costco Gasoline')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('navCancel')));
      await tester.pump();
      expect(sent, [(_gas.lat, _gas.lon), null]);
      expect(find.byKey(const ValueKey('navSearchPanel')), findsOneWidget);
    });

    testWidgets('Navigation off on the comma, or a refused destination, says so', (tester) async {
      final st = createMockUIState()..applyOpviewParams({'NavigationEnabled': false});
      await show(tester, st);
      await tester.enterText(find.byKey(const ValueKey('navSearchField')), 'costco');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('navResult_Costco Wholesale')));
      await tester.pump();
      expect(find.byKey(const ValueKey('navTurnOn')), findsOneWidget);
      st.navDestinationError = 'latitude or longitude out of range';
      st.notifyNow();
      await tester.pump();
      expect(find.text('latitude or longitude out of range'), findsOneWidget);
    });

    testWidgets('nothing found', (tester) async {
      await show(tester, createMockUIState());
      await tester.enterText(find.byKey(const ValueKey('navSearchField')), 'zzzz');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byKey(const ValueKey('navSearchError')), findsOneWidget);
    });

    testWidgets('already routing: the current route, End route, and a new destination', (tester) async {
      settings.navRecents = [_costco];
      await show(tester, _routing());
      expect(find.byKey(const ValueKey('navRouteCard')), findsOneWidget);
      expect(find.text('Costco Wholesale'), findsOneWidget);  // named from the recents
      expect(find.byKey(const ValueKey('navEta')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('navNewSearch')));
      await tester.pump();
      expect(find.byKey(const ValueKey('navSearchPanel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('navSearchBack')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('navEndRoute')));
      await tester.pump();
      expect(sent, [null]);
    });

    testWidgets('Home, Work and recents as chips', (tester) async {
      settings
        ..navHome = _costco
        ..navRecents = [_gas];
      await show(tester, createMockUIState());
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Costco Gasoline'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('navChip_Costco Wholesale')));
      await tester.pump();
      expect(sent, [(_costco.lat, _costco.lon)]);
    });

    testWidgets('no MapTiler key: how to get one instead of the search, and a way to Settings', (tester) async {
      var asked = 0;
      await show(tester, createMockUIState(), searchable: false, onAddKey: () => asked++);
      expect(find.byKey(const ValueKey('navNoKeyCard')), findsOneWidget);
      expect(find.byKey(const ValueKey('navSearchField')), findsNothing);
      expect(find.text('Navigation needs a MapTiler key'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('navAddKey')));
      expect(asked, 1);
      // with a key the search is back
      await settings.setMapTilerKey('abcDEF1234567890');
      await show(tester, createMockUIState(), searchable: false);
      expect(find.byKey(const ValueKey('navNoKeyCard')), findsNothing);
      expect(find.byKey(const ValueKey('navSearchField')), findsOneWidget);
    });

    testWidgets('a route the comma already has still shows without a key', (tester) async {
      settings.navRecents = [_costco];
      await show(tester, _routing(), searchable: false);
      expect(find.byKey(const ValueKey('navRouteCard')), findsOneWidget);
    });

    group('typing, with the keyboard up', () {
      void keyboard(WidgetTester tester, double height) {
        tester.view.viewInsets = FakeViewPadding(bottom: height);
        addTearDown(tester.view.resetViewInsets);
      }

      testWidgets('the search goes wide above the keyboard, results three across', (tester) async {
        await show(tester, createMockUIState()..isMetric = false);
        keyboard(tester, 450);
        await tester.pump();
        expect(find.byKey(const ValueKey('navSearchWide')), findsOneWidget);
        expect(find.byKey(const ValueKey('navSearchPanel')), findsNothing);
        // at full size, across the top
        final field = tester.getRect(find.byKey(const ValueKey('navSearchField')));
        expect(field.width, greaterThan(1300));
        expect(field.top, lessThan(40));
        await tester.enterText(find.byKey(const ValueKey('navSearchField')), 'costco');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(find.byKey(const ValueKey('navResultsGrid')), findsOneWidget);
        final a = tester.getRect(find.byKey(const ValueKey('navResult_Costco Wholesale')));
        final b = tester.getRect(find.byKey(const ValueKey('navResult_Costco Gasoline')));
        expect(b.top, a.top);  // side by side
        expect(b.left, greaterThan(a.right));
        // everything above the keyboard
        expect(a.bottom, lessThan(916 - 450));
        expect(tester.takeException(), isNull);
      });

      testWidgets('the keyboard going away brings the side panel back, with what was typed', (tester) async {
        await show(tester, createMockUIState());
        keyboard(tester, 450);
        await tester.pump();
        await tester.enterText(find.byKey(const ValueKey('navSearchField')), 'costco');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('navKeyboardCancel')));
        tester.view.resetViewInsets();
        await tester.pump();
        expect(find.byKey(const ValueKey('navSearchPanel')), findsOneWidget);
        expect(find.byKey(const ValueKey('navSearchWide')), findsNothing);
        expect(find.text('costco'), findsOneWidget);
        expect(find.byKey(const ValueKey('navResult_Costco Wholesale')), findsOneWidget);
      });

      testWidgets('picking a result goes to the route card', (tester) async {
        await show(tester, createMockUIState());
        keyboard(tester, 450);
        await tester.pump();
        await tester.enterText(find.byKey(const ValueKey('navSearchField')), 'costco');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('navResult_Costco Gasoline')));
        await tester.pump();
        expect(sent, [(_gas.lat, _gas.lon)]);
        expect(find.byKey(const ValueKey('navRouteCard')), findsOneWidget);
        expect(find.byKey(const ValueKey('navSearchWide')), findsNothing);
      });

      testWidgets('fits a short screen and a tall keyboard', (tester) async {
        settings.navHome = _costco;
        for (final (w, h, kb) in const [(1770.0, 916.0, 600.0), (1208.0, 440.0, 220.0), (944.0, 555.0, 300.0)]) {
          await show(tester, createMockUIState(), w: w, h: h);
          keyboard(tester, kb);
          await tester.pump();
          await tester.enterText(find.byKey(const ValueKey('navSearchField')), 'costco');
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
          expect(tester.takeException(), isNull, reason: '${w}x$h, keyboard $kb');
        }
      });
    });

    testWidgets('no GPS yet: the map says so', (tester) async {
      await show(tester, createMockUIState());
      expect(find.byKey(const ValueKey('navNoGps')), findsOneWidget);
    });

    testWidgets('lays out on the head unit shapes', (tester) async {
      for (final (w, h) in const [(1770.0, 916.0), (1208.0, 440.0), (944.0, 555.0)]) {
        await show(tester, _routing(), w: w, h: h);
        expect(tester.takeException(), isNull, reason: '${w}x$h');
      }
    });
  });
}

/// stands in for a network failure
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
