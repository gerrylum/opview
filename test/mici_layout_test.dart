// comma four style extended layout: geometry, torque bar value, and the widget tree

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/mici/mici_extended_layout.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'package:opview/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

void _screen(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

AppSettings _mici({ClockMode clock = ClockMode.off}) {
  final s = AppSettings();
  s.layout = OnroadLayout.miciExtended;
  s.clockMode = clock;
  return s;
}

void main() {
  test('comma four pixel size fits its 536x240 screen inside any screen', () {
    expect(miciUnit(const Size(536, 240)), 1.0);
    // wide screens are limited by height, tall ones by width
    expect(miciUnit(const Size(1920, 720)), closeTo(3.0, 1e-9));
    expect(miciUnit(const Size(1024, 768)), closeTo(1024 / 536, 1e-9));
  });

  group('torqueBarValue', () {
    test('torque control: the car output torque, sign flipped', () {
      final s = UIState();
      s.applyControlsState({'lateralControlState': {'torqueState': {}}});
      s.applyCarOutput({'actuatorsOutput': {'torque': 0.4}});
      expect(s.torqueBarValue, closeTo(-0.4, 1e-9));
    });

    test('angle control: desired lateral acceleration over 3 m/s2, only while steering', () {
      final s = UIState();
      s.applyCarState({'vEgo': 20.0});
      s.applyControlsState({'desiredCurvature': 0.003, 'lateralControlState': {'angleState': {}}});
      expect(s.torqueBarValue, 0.0);
      s.applyCarControl({'latActive': true});
      expect(s.torqueBarValue, closeTo(0.003 * 400 / 3, 1e-9));
    });

    test('is limited to -1..1', () {
      final s = UIState();
      s.applyCarOutput({'actuatorsOutput': {'torque': -3.0}});
      expect(s.torqueBarValue, 1.0);
    });
  });

  test('steering angle is read from carState', () {
    final s = UIState();
    s.applyCarState({'steeringAngleDeg': -12.5});
    expect(s.steeringAngleDeg, -12.5);
  });

  group('driver monitoring', () {
    test('cone colour: green with full attention, orange once it runs down', () {
      expect(miciDriverConeColor(awarenessFull: true), const Color(0xFF00FF40));
      expect(miciDriverConeColor(awarenessFull: false), const Color(0xFFFF7300));
    });

    test('current openpilot message: policy, face, awareness and head direction', () {
      final s = UIState();
      expect(s.dmSeen, false);
      const msg = '{"type": "driverMonitoringState", "data": {"activePolicy": "vision", "isRHD": false, '
          '"visionPolicyState": {"faceDetected": true, "awarenessPercent": 80.0, "pose": {"pitch": 0.0, "yaw": 0.3}}}}';
      final adapter = CerealAdapter();
      for (var i = 0; i < 60; i++) {
        adapter.apply(s, msg);
      }
      expect(s.dmSeen, true);
      expect(s.dmActive, true);
      expect(s.dmFaceDetected, true);
      expect(s.dmAwarenessPercent, 80.0);
      expect(s.dmAwarenessUnfull, true);
      // 6 degrees of pitch are added and the yaw sign flipped, then atan2(2 * pitch, yaw)
      final expected = atan2(2 * 6 * pi / 180, -0.3) * 180 / pi;
      expect(s.dmRotationDeg, closeTo(expected, 0.5));
    });

    test('looking straight ahead points the cone up', () {
      final s = UIState();
      for (var i = 0; i < 60; i++) {
        s.applyDriverMonitoringState({
          'activePolicy': 'vision',
          'visionPolicyState': {'faceDetected': true, 'awarenessPercent': 100.0, 'pose': {'pitch': 0.0, 'yaw': 0.0}},
        });
      }
      expect(s.dmRotationDeg, closeTo(90, 0.5));
      expect(s.dmAwarenessUnfull, false);
    });

    test('a policy other than vision is not active', () {
      final s = UIState();
      s.applyDriverMonitoringState({'activePolicy': 'wheeltouch', 'visionPolicyState': {'awarenessPercent': 10.0}});
      expect(s.dmActive, false);
      expect(s.dmAwarenessUnfull, false);
    });

    test('older openpilot message with flat fields still works', () {
      final s = UIState();
      s.applyDriverMonitoringState({'faceDetected': true, 'isActiveMode': true, 'awarenessStatus': 0.5});
      expect(s.dmActive, true);
      expect(s.dmFaceDetected, true);
      expect(s.dmAwarenessPercent, 50.0);
      expect(s.dmAwarenessUnfull, true);
    });
  });

  group('confidence', () {
    test('target by engagement state', () {
      final s = UIState();
      s.brakeDisengageProb = 0.2;
      s.steerOverrideProb = 0.5;
      s.status = UIStatus.disengaged;
      expect(s.confidenceTarget, -0.5);
      s.status = UIStatus.engaged;
      expect(s.confidenceTarget, closeTo(0.8 * 0.5, 1e-9));
      s.status = UIStatus.latOnly;
      expect(s.confidenceTarget, closeTo(0.5, 1e-9));
      s.status = UIStatus.longOnly;
      expect(s.confidenceTarget, closeTo(0.8, 1e-9));
    });

    test('is read from the model message and smoothed', () {
      final s = UIState();
      s.status = UIStatus.engaged;
      expect(s.confidenceSeen, false);
      final msg = {
        'meta': {
          'disengagePredictions': {
            'brakeDisengageProbs': [0.01, 0.1, 0.05],
            'steerOverrideProbs': [0.0, 0.2],
          },
        },
      };
      s.applyModelV2(msg);
      expect(s.confidenceSeen, true);
      expect(s.brakeDisengageProb, 0.1);
      expect(s.steerOverrideProb, 0.2);
      // one step from -0.5 towards 0.72
      expect(s.confidenceFiltered, greaterThan(-0.5));
      expect(s.confidenceFiltered, lessThan(0.0));
      for (var i = 0; i < 200; i++) {
        s.applyModelV2(msg);
      }
      expect(s.confidenceFiltered, closeTo(0.9 * 0.8, 0.01));
    });

    test('a model message without the values leaves the ball unsupported', () {
      final s = UIState();
      s.applyModelV2({'position': {'x': [1.0], 'y': [0.0], 'z': [0.0]}});
      expect(s.confidenceSeen, false);
    });

    test('ball colour follows confidence only while fully engaged', () {
      expect(miciBallColors(UIStatus.engaged, confidence: 0.9)!.first, const Color(0xFF00FFCC));
      expect(miciBallColors(UIStatus.engaged, confidence: 0.4)!.first, const Color(0xFFFFC800));
      expect(miciBallColors(UIStatus.engaged, confidence: 0.1)!.first, const Color(0xFFFF0015));
      expect(miciBallColors(UIStatus.latOnly, confidence: 0.1)!.first, const Color(0xFF4D9DFF));
    });
  });

  test('colours cover every engagement state', () {
    for (final status in UIStatus.values) {
      expect(miciBorderColor(status), isNotNull);
    }
    expect(miciBallColors(UIStatus.disengaged), isNull);
    expect(miciBallColors(UIStatus.engaged), hasLength(2));
  });

  group('layout setting', () {
    test('defaults to Classic and is saved', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      expect(a.layout, OnroadLayout.classic);
      await a.setLayout(OnroadLayout.miciExtended);

      final b = AppSettings();
      await b.load();
      expect(b.layout, OnroadLayout.miciExtended);
    });

    testWidgets('Classic draws the original HUD', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(MaterialApp(
        home: AugmentedRoadView(uiState: createMockUIState(), settings: AppSettings()),
      ));
      expect(find.byType(HudRenderer), findsOneWidget);
      expect(find.byType(MiciExtendedLayout), findsNothing);
    });

    testWidgets('can be changed from the settings dialog', (tester) async {
      _screen(tester, 1920, 1080);
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => AugmentedRoadView(uiState: createMockUIState(), settings: settings),
        ),
      ));

      await tester.longPress(find.byType(AugmentedRoadView));
      await tester.pumpAndSettle();
      await tester.tap(find.text(onroadLayoutLabel(OnroadLayout.miciExtended)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(settings.layout, OnroadLayout.miciExtended);
      expect(find.byType(MiciExtendedLayout), findsOneWidget);
      expect(find.byType(HudRenderer), findsNothing);
    });
  });

  group('MiciExtendedLayout', () {
    test('the camera framing is the Classic one, without the border inset', () {
      // Classic at 1920x1080: zoom 1.1 inside a 30 px border
      final tici = deviceCameras[('tici', 'ar0231')]!.fcam;
      final classic = calcFrameTransform(
        camera: tici, calibration: viewFrameFromDeviceFrame, deviceZoom: 1.1, scale: 1.0,
        x: 30, y: 30, w: 1860, h: 1020,
      );
      final full = calcFrameTransform(
        camera: tici, calibration: viewFrameFromDeviceFrame, deviceZoom: 1.1, scale: 1.0,
        x: 0, y: 0, w: 1920, h: 1080,
      );
      expect(full.zoom, closeTo(classic.zoom, 1e-9));
      expect(full.videoWidth, closeTo(classic.videoWidth, 1e-6));
    });

    testWidgets('the camera view fills the whole screen and the speed is centred', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(MaterialApp(
        home: AugmentedRoadView(uiState: createMockUIState(), settings: _mici()),
      ));
      expect(tester.getSize(find.byType(MiciExtendedLayout)), const Size(1920, 1080));
      // 18 m/s is 64.8 km/h; the pill holding it is centred with or without MAX beside it
      final speed = tester.getRect(find.text('65'));
      final unit = tester.getRect(find.text('km/h'));
      expect((speed.left + unit.right) / 2, closeTo(960, 1.0));
      expect(speed.top, lessThan(1080 * 0.3));
    });

    testWidgets('shows speed, unit and set speed in the top row', (tester) async {
      _screen(tester, 1920, 1080);
      // 18 m/s is 64.8 km/h; cruise set at 80
      await tester.pumpWidget(MaterialApp(
        home: AugmentedRoadView(uiState: createMockUIState(), settings: _mici()),
      ));
      expect(find.byType(MiciTopRow), findsOneWidget);
      expect(find.text('65'), findsOneWidget);
      expect(find.text('km/h'), findsOneWidget);
      expect(find.text('MAX'), findsOneWidget);
      expect(find.text('80'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out without errors on every screen shape', (tester) async {
      for (final (w, h) in const [(1920.0, 1080.0), (1024.0, 768.0), (1280.0, 480.0), (844.0, 390.0), (1920.0, 720.0)]) {
        _screen(tester, w, h);
        final state = createMockUIState();
        state.paramsSeen = true;
        state.speedLimitMode = 1;
        state.speedLimitValid = true;
        state.speedLimit = 22.2;
        state.speedLimitLast = 22.2;
        state.speedLimitFinalLast = 22.2;
        state.roadNameToggle = true;
        state.roadName = 'Cam Fella Boulevard';
        await tester.pumpWidget(MaterialApp(
          home: AugmentedRoadView(uiState: state, settings: _mici(clock: ClockMode.h24)),
        ));
        expect(tester.takeException(), isNull, reason: '${w}x$h');
        expect(find.text('Cam Fella Boulevard'), findsOneWidget, reason: '${w}x$h');
      }
    });

    testWidgets('imperial units show mph, and no speed limit sign is drawn', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.isMetric = false;
      state.paramsSeen = true;
      state.speedLimitMode = 1;
      state.speedLimitValid = true;
      state.speedLimitLast = 13.4;  // 30 mph
      state.speedLimitFinalLast = 13.4;
      await tester.pumpWidget(MaterialApp(
        home: AugmentedRoadView(uiState: state, settings: _mici()),
      ));
      expect(find.text('mph'), findsOneWidget);
      expect(find.text('40'), findsOneWidget);  // 18 m/s
      expect(find.text('30'), findsNothing);
      expect(find.text('SPEED'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('driver monitoring icon appears once its data arrives, while active', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: state, settings: _mici())));
      expect(find.byIcon(Icons.person), findsNothing);

      state.applyDriverMonitoringState({'faceDetected': true, 'isDistracted': false});
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: state, settings: _mici())));
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the confidence ball rides high when confident and sinks when not', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.confidenceSeen = true;
      state.confidenceFiltered = 1.0;
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: state, settings: _mici())));
      final high = tester.getRect(find.byKey(const ValueKey('miciBall')));
      expect(high.center.dy, lessThan(1080 * 0.25));

      state.confidenceFiltered = 0.0;
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: state, settings: _mici())));
      final low = tester.getRect(find.byKey(const ValueKey('miciBall')));
      expect(low.center.dy, greaterThan(1080 * 0.75));
      expect(low.right, closeTo(high.right, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('without confidence values the ball stays at the bottom', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: createMockUIState(), settings: _mici())));
      expect(tester.getRect(find.byKey(const ValueKey('miciBall'))).center.dy, greaterThan(1080 * 0.75));
    });

    testWidgets('the clock sits in the top row beside the speed', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(MaterialApp(
        home: AugmentedRoadView(uiState: createMockUIState(), settings: _mici(clock: ClockMode.h24)),
      ));
      final clock = find.descendant(of: find.byType(MiciTopRow), matching: find.byType(ClockText));
      expect(clock, findsOneWidget);
      expect(tester.getRect(clock).left, greaterThan(tester.getRect(find.text('km/h')).right));
    });

    testWidgets('the driver icon is hidden while an alert is showing', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.applyDriverMonitoringState({'faceDetected': true});
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: state, settings: _mici())));
      expect(find.byIcon(Icons.person), findsOneWidget);
      state.alertSize = 1;
      state.alertText1 = 'Pay Attention';
      final errors = FlutterError.onError;
      FlutterError.onError = (_) {};  // the Classic alert can overflow with the test font
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: state, settings: _mici())));
      FlutterError.onError = errors;
      expect(find.byIcon(Icons.person), findsNothing);
    });

    testWidgets('disengaged hides the status ball colours but still draws', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(MaterialApp(
        home: AugmentedRoadView(
          uiState: createMockUIState(engaged: false, vCruiseCluster: 0),
          settings: _mici(),
        ),
      ));
      expect(find.byType(MiciExtendedLayout), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
