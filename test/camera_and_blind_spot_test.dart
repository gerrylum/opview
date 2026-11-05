// the camera choice, and the blind spot glow's pulse and ripples

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/settings/settings_dialog.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('camera', () {
    String target(CameraMode m, {bool long = true, double v = 3, String current = 'road'}) =>
        cameraTarget(m, longitudinalControl: long, vEgo: v, current: current);

    test('Auto: wide at low speed under openpilot speed control, road when fast', () {
      expect(target(CameraMode.auto, v: 3), 'wideRoad');
      expect(target(CameraMode.auto, v: 25), 'road');
      // in between, it keeps what is showing so it does not flicker back and forth
      expect(target(CameraMode.auto, v: 12, current: 'wideRoad'), 'wideRoad');
      expect(target(CameraMode.auto, v: 12, current: 'road'), 'road');
      // stock cruise: always the road camera
      expect(target(CameraMode.auto, long: false, v: 3), 'road');
    });

    test('Road and Wide never switch', () {
      for (final v in [0.0, 3.0, 12.0, 30.0]) {
        expect(target(CameraMode.road, v: v, current: 'wideRoad'), 'road');
        expect(target(CameraMode.wide, v: v), 'wideRoad');
      }
    });

    test('the choice is saved', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      expect(a.cameraMode, CameraMode.auto);
      await a.setCameraMode(CameraMode.road);
      final b = AppSettings();
      await b.load();
      expect(b.cameraMode, CameraMode.road);
    });

    testWidgets('chosen on the Comma device page', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      await tester.pumpWidget(MaterialApp(
        home: Material(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettingsDialog(context, settings, build: 'x'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settingsCat_comma')));
      await tester.pumpAndSettle();
      expect(find.text('CAMERA'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('choice_camera_Road')));
      await tester.pumpAndSettle();
      expect(settings.cameraMode, CameraMode.road);
      expect(tester.takeException(), isNull);
    });
  });

  group('blind spot glow', () {
    test('breathes between a soft and a strong glow', () {
      final alphas = [for (var i = 0; i <= 20; i++) BlindSpotGlowPainter.glowAlpha(i / 20)];
      expect(alphas.reduce((a, b) => a < b ? a : b), closeTo(0.35, 1e-9));
      expect(alphas.reduce((a, b) => a > b ? a : b), closeTo(0.65, 1e-9));
    });

    test('ripples are spread out, start at the edge and fade as they travel in', () {
      final r = BlindSpotGlowPainter.ripples(0.0);
      expect(r.length, blindSpotRipples);
      expect(r.map((e) => e.$1).toSet().length, blindSpotRipples);
      final first = BlindSpotGlowPainter.ripples(0.0).first;
      final later = BlindSpotGlowPainter.ripples(0.5).first;
      expect(first.$1, 0.0);
      expect(later.$1, greaterThan(first.$1));
      expect(later.$2, lessThan(first.$2));
    });
  });
}
