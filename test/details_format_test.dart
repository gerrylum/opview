// the figures behind the Details view: formatting, and the data they are read from

import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/details/details_format.dart';
import 'package:opview/selfdrive/ui/onroad/top_row.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/impl/cereal_adapter.dart';

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
      expect(formatNextLimitDistance(644, false), '0.4 mi');
      expect(formatNextLimitDistance(100, false), '350 ft');
      expect(formatNextLimitDistance(1500, true), '1.5 km');
      expect(formatNextLimitDistance(340, true), '350 m');
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
      expect(speedLimitToShow(s), isNull);
      s.speedLimitLastValid = true;
      s.speedLimitLast = 20;
      expect(speedLimitToShow(s), 20);
      s.speedLimitValid = true;
      s.speedLimit = 25;
      expect(speedLimitToShow(s), 25);
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

}
