// comma four style extended layout: geometry, torque bar value, and the widget tree

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/mici/mici_extended_layout.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
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
  group('MiciGeometry', () {
    test('16:9 screen: full width, panel below', () {
      final g = MiciGeometry.compute(const Size(1920, 1080));
      expect(g.infoVertical, false);
      expect(g.device.left, 0);
      expect(g.device.top, 0);
      expect(g.device.width, 1920);
      expect(g.device.height, closeTo(1920 * 240 / 536, 0.01));
      expect(g.info.top, closeTo(g.device.bottom, 0.01));
      expect(g.info.bottom, closeTo(1080, 0.01));
      expect(g.unit, closeTo(g.device.height / 240, 1e-9));
    });

    test('4:3 screen: panel below gets the larger share', () {
      final g = MiciGeometry.compute(const Size(1024, 768));
      expect(g.infoVertical, false);
      expect(g.info.height, closeTo(768 - 1024 * 240 / 536, 0.01));
    });

    test('very wide screen: panel at the side, at least a fifth of the width', () {
      final g = MiciGeometry.compute(const Size(1280, 480));
      expect(g.infoVertical, true);
      expect(g.info.width, closeTo(256, 0.01));
      expect(g.info.height, 480);
      expect(g.device.width, closeTo(1024, 0.01));
      expect(g.device.width / g.device.height, closeTo(536 / 240, 1e-6));
      // centred vertically
      expect(g.device.top, closeTo(480 - g.device.bottom, 0.01));
    });

    test('the device area keeps the comma four shape and stays on screen', () {
      for (final size in const [Size(1920, 1080), Size(1024, 768), Size(1280, 480), Size(844, 390), Size(1920, 720)]) {
        final g = MiciGeometry.compute(size);
        expect(g.device.width / g.device.height, closeTo(536 / 240, 1e-6), reason: '$size');
        expect(g.device.right, lessThanOrEqualTo(size.width + 0.01), reason: '$size');
        expect(g.device.bottom, lessThanOrEqualTo(size.height + 0.01), reason: '$size');
        expect(g.info.width, greaterThan(0), reason: '$size');
        expect(g.info.height, greaterThan(0), reason: '$size');
      }
    });
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
    testWidgets('shows speed, set speed and unit in the information panel', (tester) async {
      _screen(tester, 1920, 1080);
      // 18 m/s is 64.8 km/h; cruise set at 80
      await tester.pumpWidget(MaterialApp(
        home: AugmentedRoadView(uiState: createMockUIState(), settings: _mici()),
      ));
      expect(find.byType(MiciInfoPanel), findsOneWidget);
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
