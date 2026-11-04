// lane guard on the torque bar: what the comma sends, what the bar shows

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/lane_guard_bar.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'golden/mock_ui_state.dart';

Map<String, dynamic> _lg({
  bool enabled = true,
  bool active = true,
  String paused = 'none',
  double curvature = 0.0,
  String source = 'none',
  bool leftLine = true,
  bool rightLine = true,
  bool leftEdge = true,
  bool rightEdge = true,
}) =>
    {
      'laneGuard': {
        'enabled': enabled,
        'active': active,
        'pausedReason': paused,
        'curvature': curvature,
        'source': source,
        'leftLineGuarded': leftLine,
        'rightLineGuarded': rightLine,
        'leftEdgeGuarded': leftEdge,
        'rightEdgeGuarded': rightEdge,
        'leftGap': 0.31,
        'rightGap': -0.04,
      }
    };

/// steering at 20 m/s, with lane guard reporting [data]
UIState _state(Map<String, dynamic> data, {bool latActive = true}) {
  final st = createMockUIState(vEgo: 20.0)
    ..latActive = latActive
    ..applyCarControlSP(data);
  return st;
}

/// curvature giving [share] of the band at 20 m/s
double _curv(double share) => share * laneGuardFullScale / (20.0 * 20.0);

void main() {
  group('from the comma', () {
    test('carControlSP.laneGuard is read', () {
      final st = UIState();
      CerealAdapter().apply(st, '{"type": "carControlSP", "data": {"laneGuard": {"enabled": true, "active": true, '
          '"pausedReason": "laneChange", "curvature": 0.0004, "source": "roadEdge", "leftLineGuarded": false, '
          '"rightLineGuarded": true, "leftEdgeGuarded": true, "rightEdgeGuarded": false, "leftGap": 0.12, "rightGap": -0.03}}}');
      expect(st.laneGuardSeen, isTrue);
      expect(st.laneGuardEnabled && st.laneGuardActive, isTrue);
      expect(st.laneGuardPaused, 'laneChange');
      expect(st.laneGuardCurvature, 0.0004);
      expect(st.laneGuardSource, 'roadEdge');
      expect([st.laneGuardLeftLine, st.laneGuardRightLine, st.laneGuardLeftEdge, st.laneGuardRightEdge],
          [false, true, true, false]);
      expect(st.laneGuardLeftGap, 0.12);
      expect(st.laneGuardRightGap, -0.03);
    });

    test('a comma branch without lane guard state leaves the bar plain', () {
      final st = createMockUIState()..latActive = true;
      st.applyCarControlSP({'mads': {}});  // an older carControlSP, sent whole
      expect(st.laneGuardSeen, isFalse);
      expect(LaneGuardBar.of(st), isNull);
    });

    test('push: curvature × speed² against 0.4 m/s², positive to the right, held at ±1', () {
      expect(_state(_lg(curvature: _curv(0.5))).laneGuardPush, closeTo(0.5, 1e-9));
      expect(_state(_lg(curvature: _curv(-0.25))).laneGuardPush, closeTo(-0.25, 1e-9));
      expect(_state(_lg(curvature: _curv(3))).laneGuardPush, 1.0);
    });
  });

  group('what the bar shows', () {
    test('only while lane guard is on and openpilot steers', () {
      expect(LaneGuardBar.of(_state(_lg())), isNotNull);
      expect(LaneGuardBar.of(_state(_lg(enabled: false))), isNull);
      expect(LaneGuardBar.of(_state(_lg(), latActive: false)), isNull);
    });

    test('armed: both marks grey, no band', () {
      final b = LaneGuardBar.of(_state(_lg()))!;
      expect([b.left, b.right], [LaneGuardMark.armed, LaneGuardMark.armed]);
      expect(b.push, 0.0);
    });

    test('pushing left, away from the right lane line: amber, the right mark lit', () {
      final b = LaneGuardBar.of(_state(_lg(curvature: _curv(-0.45), source: 'laneLine')))!;
      expect(b.push, closeTo(-0.45, 1e-9));
      expect(b.color, laneGuardLineColor);
      expect([b.left, b.right], [LaneGuardMark.armed, LaneGuardMark.line]);
    });

    test('pushing right, away from the left road edge: red, the left mark lit', () {
      final b = LaneGuardBar.of(_state(_lg(curvature: _curv(0.7), source: 'roadEdge', rightLine: false, rightEdge: false)))!;
      expect(b.color, laneGuardEdgeColor);
      expect([b.left, b.right], [LaneGuardMark.edge, LaneGuardMark.unguarded]);
    });

    test('paused: dotted marks, except a side still being pushed from', () {
      for (final reason in ['driverSteering', 'laneChange', 'slow']) {
        final b = LaneGuardBar.of(_state(_lg(paused: reason, active: reason == 'laneChange')))!;
        expect([b.left, b.right], [LaneGuardMark.paused, LaneGuardMark.paused], reason: reason);
      }
      // with the blinker on the road edges are still guarded
      final b = LaneGuardBar.of(_state(_lg(paused: 'laneChange', curvature: _curv(-0.3), source: 'roadEdge')))!;
      expect([b.left, b.right], [LaneGuardMark.paused, LaneGuardMark.edge]);
    });

    test('a push too small to see lights nothing', () {
      final b = LaneGuardBar.of(_state(_lg(curvature: _curv(0.01), source: 'laneLine')))!;
      expect([b.left, b.right], [LaneGuardMark.armed, LaneGuardMark.armed]);
    });
  });

  group('drawing', () {
    test('ticks, detent and marks stand on the arc\'s radius', () {
      const arc = LaneGuardArc(Offset(500, 2000), 1000, -pi / 2, 0.07, 40);
      // the centre of the arc is straight above its circle's centre
      expect(arc.at(-pi / 2).dx, closeTo(500, 1e-9));
      expect(arc.at(-pi / 2).dy, closeTo(1000, 1e-9));
      // marks sit just past each end, mirrored
      final l = arc.markAngle(left: true), r = arc.markAngle(left: false);
      expect(l, lessThan(-pi / 2 - 0.07));
      expect(r, greaterThan(-pi / 2 + 0.07));
      expect(l + r, closeTo(-pi, 1e-12));
    });

    for (final (name, data) in [
      ('armed', _lg()),
      ('pushing from a line', _lg(curvature: _curv(-0.45), source: 'laneLine')),
      ('pushing from an edge', _lg(curvature: _curv(0.8), source: 'roadEdge')),
      ('paused', _lg(paused: 'laneChange')),
    ]) {
      testWidgets('the torque bar carries it: $name', (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final st = _state(data);
        await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: st, settings: AppSettings())));
        final painter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((p) => p.painter)
            .whereType<EnhancedTorqueBarPainter>()
            .single;
        expect(painter.laneGuard, LaneGuardBar.of(st));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('lane guard off: the plain torque bar', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: _state(_lg(enabled: false)), settings: AppSettings())));
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<EnhancedTorqueBarPainter>()
          .single;
      expect(painter.laneGuard, isNull);
    });
  });
}
