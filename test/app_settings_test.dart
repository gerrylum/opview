// viewer-side settings: storage, the clock, and the settings dialog

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _clock(ClockMode mode, DateTime time, {bool system24 = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(alwaysUse24HourFormat: system24),
      child: Stack(children: [ClockRenderer(mode: mode, scale: 1.0, now: () => time)]),
    ),
  );
}

void main() {
  group('formatClock', () {
    test('24 hour pads the hour', () {
      expect(formatClock(DateTime(2026, 10, 7, 9, 5), use24Hour: true), '09:05');
      expect(formatClock(DateTime(2026, 10, 7, 14, 30), use24Hour: true), '14:30');
      expect(formatClock(DateTime(2026, 10, 7, 0, 0), use24Hour: true), '00:00');
    });

    test('12 hour uses 12 for midnight and noon', () {
      expect(formatClock(DateTime(2026, 10, 7, 0, 7), use24Hour: false), '12:07 AM');
      expect(formatClock(DateTime(2026, 10, 7, 12, 0), use24Hour: false), '12:00 PM');
      expect(formatClock(DateTime(2026, 10, 7, 9, 5), use24Hour: false), '9:05 AM');
      expect(formatClock(DateTime(2026, 10, 7, 23, 59), use24Hour: false), '11:59 PM');
    });
  });

  group('AppSettings', () {
    test('defaults leave the original display unchanged', () {
      expect(AppSettings().clockMode, ClockMode.off);
    });

    test('saves and reloads the clock mode', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      expect(a.clockMode, ClockMode.off);
      await a.setClockMode(ClockMode.h24);

      final b = AppSettings();
      await b.load();
      expect(b.clockMode, ClockMode.h24);
    });

    test('an unknown saved value falls back to the default', () async {
      SharedPreferences.setMockInitialValues({'clock_mode': 'sundial'});
      final s = AppSettings();
      await s.load();
      expect(s.clockMode, ClockMode.off);
    });

    test('notifies listeners on change only', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppSettings();
      var calls = 0;
      s.addListener(() => calls++);
      await s.setClockMode(ClockMode.h12);
      await s.setClockMode(ClockMode.h12);
      expect(calls, 1);
    });
  });

  group('ClockRenderer', () {
    final afternoon = DateTime(2026, 10, 7, 14, 5);

    testWidgets('24 hour mode', (tester) async {
      await tester.pumpWidget(_clock(ClockMode.h24, afternoon));
      expect(find.text('14:05'), findsOneWidget);
    });

    testWidgets('12 hour mode', (tester) async {
      await tester.pumpWidget(_clock(ClockMode.h12, afternoon, system24: true));
      expect(find.text('2:05 PM'), findsOneWidget);
    });

    testWidgets('system mode follows the device setting', (tester) async {
      await tester.pumpWidget(_clock(ClockMode.system, afternoon, system24: true));
      expect(find.text('14:05'), findsOneWidget);
      await tester.pumpWidget(_clock(ClockMode.system, afternoon, system24: false));
      await tester.pump();
      expect(find.text('2:05 PM'), findsOneWidget);
    });

    testWidgets('advances without any driving data arriving', (tester) async {
      var time = DateTime(2026, 10, 7, 14, 5, 58);
      await tester.pumpWidget(MaterialApp(
        home: Stack(children: [ClockRenderer(mode: ClockMode.h24, scale: 1.0, now: () => time)]),
      ));
      expect(find.text('14:05'), findsOneWidget);
      time = DateTime(2026, 10, 7, 14, 6, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('14:06'), findsOneWidget);
    });
  });

  group('AugmentedRoadView settings', () {
    UIState connected() {
      final s = UIState();
      s.isConnected = true;
      return s;
    }

    // same full HD surface the screenshot tests use
    void fullHd(WidgetTester tester) {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('no clock unless turned on', (tester) async {
      fullHd(tester);
      final settings = AppSettings();
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: connected(), settings: settings)));
      expect(find.byType(ClockRenderer), findsNothing);

      settings.clockMode = ClockMode.h24;
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: connected(), settings: settings)));
      expect(find.byType(ClockRenderer), findsOneWidget);
    });

    testWidgets('long press opens settings and a choice takes effect', (tester) async {
      fullHd(tester);
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => AugmentedRoadView(uiState: connected(), settings: settings),
        ),
      ));

      await tester.longPress(find.byType(AugmentedRoadView));
      await tester.pumpAndSettle();
      expect(find.text('opview settings'), findsOneWidget);

      await tester.tap(find.text('On (24 hour)'));
      await tester.pumpAndSettle();
      expect(settings.clockMode, ClockMode.h24);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(ClockRenderer), findsOneWidget);
    });

    testWidgets('settings are reachable from the connecting screen', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: UIState(), settings: AppSettings())));
      expect(find.text('Settings'), findsOneWidget);
    });
  });
}
