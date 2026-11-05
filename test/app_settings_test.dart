// viewer-side settings: storage, the clock, and the settings dialog

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/settings/settings_dialog.dart';
import 'package:opview/selfdrive/ui/settings/settings_page.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/nav/places.dart';
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
    test('defaults: a 12 hour clock, the speed limit on Auto, Details closed', () {
      final s = AppSettings();
      expect(s.clockMode, ClockMode.h12);
      expect(s.speedLimitDisplay, SpeedLimitDisplay.auto);
      expect(s.detailsOpen, isFalse);
    });

    test('a clock setting saved by an older build is ignored', () async {
      SharedPreferences.setMockInitialValues({'clock_mode': 'off'});
      final s = AppSettings();
      await s.load();
      expect(s.clockMode, ClockMode.h12);
    });

    test('saves and reloads the speed limit choice', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      await a.setSpeedLimitDisplay(SpeedLimitDisplay.off);

      final b = AppSettings();
      await b.load();
      expect(b.speedLimitDisplay, SpeedLimitDisplay.off);
    });

    test('an unknown saved value falls back to the default', () async {
      SharedPreferences.setMockInitialValues({'speed_limit_display': 'sometimes'});
      final s = AppSettings();
      await s.load();
      expect(s.speedLimitDisplay, SpeedLimitDisplay.auto);
    });

    test('notifies listeners on change only', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppSettings();
      var calls = 0;
      s.addListener(() => calls++);
      await s.setSpeedLimitDisplay(SpeedLimitDisplay.always);
      await s.setSpeedLimitDisplay(SpeedLimitDisplay.always);
      expect(calls, 1);
    });

    test('a road name hidden by an earlier build stays hidden', () async {
      SharedPreferences.setMockInitialValues({'show_road_name': false});
      final s = AppSettings();
      await s.load();
      expect(s.showRoadName, isFalse);
      expect(s.shows(DriveSection.roadName), isFalse);
      expect(s.shows(DriveSection.speed), isTrue);
    });

    test('road name: shown by default, can be hidden, remembered', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      expect(a.showRoadName, isTrue);
      await a.setShowRoadName(false);
      final b = AppSettings();
      await b.load();
      expect(b.showRoadName, isFalse);
    });

    test('the road name follows the app setting, not the comma one', () {
      final st = UIState()
        ..roadName = 'Main St'
        ..roadNameToggle = false;
      expect(st.showRoadName, isTrue);
      st.roadNameEnabled = false;
      expect(st.showRoadName, isFalse);
      st
        ..roadNameEnabled = true
        ..roadName = '';
      expect(st.showRoadName, isFalse);  // no name from the maps
    });

    test('whether Details is open is remembered', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      await a.setDetailsOpen(true);
      final b = AppSettings();
      await b.load();
      expect(b.detailsOpen, isTrue);
    });
  });

  group('ClockText', () {
    testWidgets('can draw AM/PM separately, for a smaller style', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: ClockText(
            mode: ClockMode.h12,
            style: const TextStyle(fontSize: 24),
            suffixStyle: const TextStyle(fontSize: 11),
            suffixGap: 5,
            now: () => DateTime(2026, 10, 7, 14, 5),
          ),
        ),
      ));
      expect(find.text('2:05'), findsOneWidget);
      expect(find.text('PM'), findsOneWidget);
      expect(tester.getRect(find.text('PM')).left, greaterThan(tester.getRect(find.text('2:05')).right));
    });

    testWidgets('24 hour time has no suffix to split off', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: ClockText(
            mode: ClockMode.h24,
            style: const TextStyle(fontSize: 24),
            suffixStyle: const TextStyle(fontSize: 11),
            now: () => DateTime(2026, 10, 7, 14, 5),
          ),
        ),
      ));
      expect(find.text('14:05'), findsOneWidget);
    });
  });

  group('settings menu', () {
    test('short names, in the order offered', () {
      expect(SpeedLimitDisplay.values.map(speedLimitDisplayLabel).toList(), ['Auto', 'Always', 'Off']);
      expect(DriveSection.values.map(driveSectionLabel).toList(), [
        'Speed and MAX', 'Road name', 'Driver monitoring', 'Confidence ball',
        'Steering details', 'Lead car details', 'Torque bar', 'Turn banner (navigating)', 'Map (navigating)', 'Status bar',
      ]);
    });

    Future<AppSettings> open(WidgetTester tester,
        {String? host, bool manual = false, VoidCallback? onChange, SettingsCategory? page = SettingsCategory.comma, UIState? uiState}) async {
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
              onPressed: () => showSettingsDialog(context, settings,
                  uiState: uiState, host: host, hostIsManual: manual, onChangeHost: onChange, build: 'abc1234'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (page != null) {
        await tester.tap(find.byKey(ValueKey('settingsCat_${page.name}')));
        await tester.pumpAndSettle();
      }
      return settings;
    }

    testWidgets('opens on Driving view: the picture and a switch for every part', (tester) async {
      await open(tester, page: null);
      for (final c in SettingsCategory.values) {
        expect(find.byKey(ValueKey('settingsCat_${c.name}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('drivingViewPicture')), findsOneWidget);
      for (final s in DriveSection.values) {
        expect(find.byKey(ValueKey('section_${s.name}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('section_speedLimit')), findsOneWidget);
      expect(find.text('SPEED LIMIT SIGN'), findsOneWidget);
      expect(find.text('BRIGHTNESS'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a section switch hides it and is remembered', (tester) async {
      await open(tester, page: null);
      await tester.ensureVisible(find.byKey(const ValueKey('section_torque')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('section_torque')));
      await tester.pumpAndSettle();
      final again = AppSettings();
      await again.load();
      expect(again.shows(DriveSection.torque), isFalse);
      expect(again.shows(DriveSection.speed), isTrue);
    });

    testWidgets('tapping a part of the picture does the same as its switch', (tester) async {
      final settings = await open(tester, page: null);
      await tester.tap(find.byKey(const ValueKey('preview_driver')));
      await tester.pumpAndSettle();
      expect(settings.shows(DriveSection.driver), isFalse);
      expect(find.text('\u2715 Driver'), findsOneWidget);
      // the speed limit sign is the speed limit choice: off, and back to Auto
      await tester.tap(find.byKey(const ValueKey('preview_speedLimit')));
      await tester.pumpAndSettle();
      expect(settings.speedLimitDisplay, SpeedLimitDisplay.off);
      await tester.tap(find.byKey(const ValueKey('section_speedLimit')));
      await tester.pumpAndSettle();
      expect(settings.speedLimitDisplay, SpeedLimitDisplay.auto);
    });

    testWidgets('Display: the clock and keeping the screen on', (tester) async {
      final settings = await open(tester, page: SettingsCategory.display);
      await tester.tap(find.byKey(const ValueKey('choice_clock_24 h')));
      await tester.pumpAndSettle();
      expect(settings.clockMode, ClockMode.h24);
      expect(settings.keepScreenOn, isTrue);
      await tester.tap(find.byKey(const ValueKey('keepScreenOn')));
      await tester.pumpAndSettle();
      final again = AppSettings();
      await again.load();
      expect(again.clockMode, ClockMode.h24);
      expect(again.keepScreenOn, isFalse);
    });

    testWidgets('Navigation: map style, and Home cleared', (tester) async {
      final settings = await open(tester, page: null);
      await settings.setNavHome(const Place(name: 'Home', address: '1 Main St', lat: 49.2, lon: -123.1));
      await tester.tap(find.byKey(const ValueKey('settingsCat_navigation')));
      await tester.pumpAndSettle();
      expect(find.text('1 Main St'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('clearHome')));
      await tester.pumpAndSettle();
      expect(settings.navHome, isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('choice_mapStyle_Streets')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('choice_mapStyle_Streets')));
      await tester.pumpAndSettle();
      expect(settings.mapStyle, MapStyle.streets);
    });

    testWidgets('shows the comma address, how it was found, and the build', (tester) async {
      await open(tester, host: '192.168.1.50');
      expect(find.text('192.168.1.50'), findsOneWidget);
      expect(find.text('found automatically'), findsOneWidget);
      expect(find.text('OPRivView \u00B7 abc1234'), findsOneWidget);
      expect(find.byKey(const ValueKey('changeHost')), findsNothing);  // no way to change it was given
      expect(tester.takeException(), isNull);
    });

    testWidgets('the comma\'s own settings, read from it', (tester) async {
      final state = UIState()
        ..laneGuardSeen = true
        ..laneGuardEnabled = true
        ..navigationEnabled = false;
      await open(tester, host: '192.168.1.50', uiState: state);
      expect(find.text('Lane guard'), findsOneWidget);
      expect(find.text('on'), findsOneWidget);
      expect(find.text('off'), findsOneWidget);
    });

    testWidgets('says when the address was typed in, and when there is none yet; Done closes', (tester) async {
      await open(tester, host: '10.0.0.5', manual: true);
      expect(find.text('entered by hand'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settingsDone')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settingsPage')), findsNothing);

      await open(tester);
      expect(find.text('Not found yet'), findsOneWidget);
      expect(find.text('searching the network'), findsOneWidget);
    });

    testWidgets('Change closes Settings and asks for the address', (tester) async {
      var asked = 0;
      await open(tester, host: '192.168.1.50', onChange: () => asked++);
      await tester.tap(find.byKey(const ValueKey('changeHost')));
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(find.byKey(const ValueKey('settingsPage')), findsNothing);
    });

    for (final c in SettingsCategory.values) {
      testWidgets('${settingsCategoryLabel(c)} fits a screen as short as the comma four shape', (tester) async {
        await open(tester, host: '192.168.1.50', onChange: () {}, page: c);
        tester.view.physicalSize = const Size(1072, 480);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = const Size(1280, 720);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
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
}
