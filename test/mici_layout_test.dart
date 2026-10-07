// comma four style extended layout: geometry, torque bar value, and the widget tree

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
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

  test('road zoom follows speed as on the device', () {
    expect(miciRoadZoom(0), 0.8);
    expect(miciRoadZoom(10), 0.8);
    expect(miciRoadZoom(20), closeTo(0.9, 1e-9));
    expect(miciRoadZoom(40), 1.0);
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

  test('driver monitoring arc colour', () {
    expect(miciDriverArcColor(faceDetected: true, distracted: false), const Color(0xFF17C653));
    expect(miciDriverArcColor(faceDetected: true, distracted: true), const Color(0xFFFF7300));
    expect(miciDriverArcColor(faceDetected: false, distracted: false), const Color(0xFF8C8C8C));
  });

  test('driver monitoring state is read through the adapter', () {
    final s = UIState();
    expect(s.dmSeen, false);
    CerealAdapter().apply(s, '{"type": "driverMonitoringState", "data": {"faceDetected": true, "isDistracted": true}}');
    expect(s.dmSeen, true);
    expect(s.dmFaceDetected, true);
    expect(s.dmDistracted, true);
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

    testWidgets('imperial units use the US sign and mph', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.isMetric = false;
      state.paramsSeen = true;
      state.speedLimitMode = 1;
      state.speedLimitValid = true;
      state.speedLimitLast = 17.88;  // 40 mph
      state.speedLimitFinalLast = 17.88;
      await tester.pumpWidget(MaterialApp(
        home: AugmentedRoadView(uiState: state, settings: _mici()),
      ));
      expect(find.text('mph'), findsOneWidget);
      expect(find.text('SPEED'), findsOneWidget);
      expect(find.text('40'), findsWidgets);
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
