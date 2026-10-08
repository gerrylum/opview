// Detailed layout: its data, formatting, and the widget tree

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/detailed/detailed_layout.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'golden/mock_ui_state.dart';

void _screen(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

AppSettings _detailed({ClockMode clock = ClockMode.off}) {
  final s = AppSettings();
  s.layout = OnroadLayout.detailed;
  s.clockMode = clock;
  return s;
}

Widget _app(UIState state, AppSettings settings) =>
    MaterialApp(home: AugmentedRoadView(uiState: state, settings: settings));

void main() {
  group('formatting', () {
    test('acceleration, never -0.00', () {
      expect(formatAccel(-0.4249), '-0.42 m/s²');
      expect(formatAccel(-0.001), '0.00 m/s²');
      expect(formatAccelPair(0.824, -0.001), '0.82 / 0.00');
    });

    test('personality and gear', () {
      expect(formatPersonality('standard'), 'Standard');
      expect(formatPersonality(''), detailedNoValue);
      expect(formatGear('drive'), 'D');
      expect(formatGear('park'), 'P');
      expect(formatGear('unknown'), detailedNoValue);
      expect(formatGear('sport'), 'SPORT');
    });

    test('distance to the next speed limit', () {
      expect(formatAheadDistance(644, false), '0.4 mi');
      expect(formatAheadDistance(100, false), '350 ft');
      expect(formatAheadDistance(1500, true), '1.5 km');
      expect(formatAheadDistance(340, true), '350 m');
    });

    test('time to the lead only while closing', () {
      expect(timeToLead(30, -5), closeTo(6.0, 1e-9));
      expect(timeToLead(30, 0), isNull);
      expect(timeToLead(30, 2), isNull);
    });

    test('network bars', () {
      expect(networkBars('great'), 4);
      expect(networkBars('poor'), 1);
      expect(networkBars('unknown'), 0);
    });
  });

  group('data', () {
    test('speed limit: current, else the last known, else none', () {
      final s = UIState();
      expect(detailedSpeedLimit(s), isNull);
      s.speedLimitLastValid = true;
      s.speedLimitLast = 20;
      expect(detailedSpeedLimit(s), 20);
      s.speedLimitValid = true;
      s.speedLimit = 25;
      expect(detailedSpeedLimit(s), 25);
    });

    test('new car, control and device fields are read', () {
      final s = UIState();
      final a = CerealAdapter();
      a.apply(s, '{"type": "carState", "data": {"aEgo": -0.4, "steeringRateDeg": 3.2, "steeringTorque": 0.5, '
          '"gasPressed": true, "brakePressed": false, "gearShifter": "drive", "cruiseState": {"enabled": true}}}');
      a.apply(s, '{"type": "carControl", "data": {"latActive": true, "longActive": true, '
          '"actuators": {"accel": -0.6, "steeringAngleDeg": 4.0}}}');
      a.apply(s, '{"type": "selfdriveState", "data": {"enabled": true, "personality": "relaxed"}}');
      a.apply(s, '{"type": "controlsState", "data": {"curvature": 0.002, "desiredCurvature": 0.003, '
          '"lateralControlState": {"torqueState": {"saturated": true}}}}');
      a.apply(s, '{"type": "deviceState", "data": {"cpuTempC": [55.0, 61.5, 58.0], "memoryUsagePercent": 48, '
          '"freeSpacePercent": 28.0, "networkStrength": "good", "powerDrawW": 6.1}}');
      a.apply(s, '{"type": "liveCalibration", "data": {"calStatus": "calibrating", "calPerc": 42}}');
      expect(s.aEgo, -0.4);
      expect(s.steeringRateDeg, 3.2);
      expect(s.gasPressed, true);
      expect(s.gearShifter, 'drive');
      expect(s.cruiseEnabled, true);
      expect(s.longActive, true);
      expect(s.accelCommand, -0.6);
      expect(s.personality, 'relaxed');
      expect(s.lateralSaturated, true);
      expect(s.cpuTempC, 61.5);
      expect(s.memoryUsagePercent, 48);
      expect(s.networkStrength, 'good');
      expect(s.calPerc, 42);
    });

    test('radar match is held for a second so the badge does not flicker', () {
      var now = DateTime(2026, 10, 9, 12);
      final s = UIState()..clock = () => now;
      Map<String, dynamic> lead(bool radar) => {'leadOne': {'present': true, 'dRel': 30.0, 'radar': radar}};
      expect(s.leadRadarRecent, false);
      s.applyRadarState(lead(true));
      expect(s.leadRadarRecent, true);
      // the match drops out briefly: still shown as radar
      now = now.add(const Duration(milliseconds: 400));
      s.applyRadarState(lead(false));
      expect(s.leadRadarRecent, true);
      // a full second without a match: vision only
      now = now.add(const Duration(milliseconds: 700));
      s.applyRadarState(lead(false));
      expect(s.leadRadarRecent, false);
      // and never with no lead at all
      s.applyRadarState(lead(true));
      s.applyRadarState({'leadOne': {'present': false}});
      expect(s.leadRadarRecent, false);
    });

    test('sideways acceleration comes from the curvatures', () {
      final s = UIState()
        ..vEgo = 20
        ..curvature = 0.002
        ..desiredCurvature = 0.0025;
      expect(s.latAccelGot, closeTo(0.8, 1e-9));
      expect(s.latAccelWant, closeTo(1.0, 1e-9));
    });

    test('history keeps ten seconds, newest last', () {
      final s = UIState();
      for (var i = 0; i < UIState.historyLength + 30; i++) {
        s.aEgo = i.toDouble();
        s.applyModelV2({});
      }
      expect(s.accelActualHistory.length, UIState.historyLength);
      expect(s.accelActualHistory.last, (UIState.historyLength + 29).toDouble());
      // nothing commanded while openpilot is not in control of speed
      expect(s.accelCommandHistory.every((v) => v == 0), true);
    });
  });

  group('screen', () {
    testWidgets('draws every panel, on wide and short screens, without errors', (tester) async {
      for (final size in const [Size(1920, 1080), Size(1920, 720), Size(1280, 800)]) {
        _screen(tester, size.width, size.height);
        await tester.pumpWidget(_app(createMockUIState(), _detailed(clock: ClockMode.h12)));
        expect(find.byType(DetailedLayout), findsOneWidget);
        expect(find.text('STEERING'), findsOneWidget);
        expect(find.text('DRIVER'), findsOneWidget);
        expect(find.text('LONGITUDINAL'), findsOneWidget);
        expect(find.text('LEAD'), findsOneWidget);
        expect(find.byKey(const ValueKey('detailedClock')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });

    testWidgets('mode badge: experimental or chill', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(experimentalMode: true), _detailed()));
      expect(find.byKey(const ValueKey('detailedExperimental')), findsOneWidget);
      await tester.pumpWidget(_app(createMockUIState(), _detailed()));
      expect(find.byKey(const ValueKey('detailedChill')), findsOneWidget);
    });

    testWidgets('speed limit pill: limit, next limit, or dashes', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.isMetric = false;
      await tester.pumpWidget(_app(state, _detailed()));
      final pill = find.byKey(const ValueKey('detailedSpeedLimit'));
      expect(find.descendant(of: pill, matching: find.text('– –')), findsOneWidget);
      expect(find.descendant(of: pill, matching: find.byKey(const ValueKey('detailedSpeedLimitOutline'))), findsOneWidget);
      expect(find.byKey(const ValueKey('detailedNextLimit')), findsNothing);

      state
        ..speedLimitValid = true
        ..speedLimit = 45 / msToMph
        ..speedLimitAheadValid = true
        ..speedLimitAhead = 35 / msToMph
        ..speedLimitAheadDistance = 644;
      await tester.pumpWidget(_app(state, _detailed()));
      expect(find.descendant(of: pill, matching: find.text('45')), findsOneWidget);
      expect(find.byKey(const ValueKey('detailedNextLimit')), findsOneWidget);
      // set speed and speed limit are narrower than Enhanced's, and the same width
      final unit = enhancedUnit(const Size(1920, 1080));
      expect(tester.getSize(pill).width, closeTo(detailedSidePillWidth * unit, 0.01));
      expect(tester.getSize(find.byKey(const ValueKey('detailedSetSpeed'))).width, closeTo(detailedSidePillWidth * unit, 0.01));
    });

    testWidgets('lead panel: filled in with a lead, dashes while disengaged', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(), _detailed()));
      final panel = find.byType(DetailedLeadPanel);
      // mock: 18 m/s, lead 30 m ahead
      expect(find.descendant(of: panel, matching: find.text('1.7 s')), findsOneWidget);
      await tester.pumpWidget(_app(createMockUIState(engaged: false), _detailed()));
      expect(find.descendant(of: panel, matching: find.text(enhancedNoLeadValue)), findsNWidgets(6));
    });

    testWidgets('path is drawn like Enhanced: more solid and further out', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(), _detailed()));
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<ModelRendererPainter>()
          .single;
      expect(painter.pathOpacity, enhancedPathOpacity);
      expect(painter.maxPathDistance, enhancedPathDistance);
      expect(painter.pathFadeStop, enhancedPathFadeStop);
    });

    testWidgets('alerts still show over the panels', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(alertText1: 'Pay Attention', alertSize: 1), _detailed()));
      expect(find.byKey(const ValueKey('enhancedAlertCard')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
