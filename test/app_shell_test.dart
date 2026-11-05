// the app's one screen: menu column, camera view, status bar

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/shell/app_shell.dart';
import 'package:opview/selfdrive/ui/shell/menu_rail.dart';
import 'package:opview/selfdrive/ui/shell/status_bar.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opview/services/recorder/recorder.dart';
import 'golden/mock_ui_state.dart';
import 'support/fake_recorder.dart';

void _screen(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _shell(UIState state, AppSettings settings, {VoidCallback? onExit, Recorder? recorder}) => MaterialApp(
      home: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => AppShell(uiState: state, settings: settings, onExit: onExit, recorder: recorder),
      ),
    );

UIState _withDevice() {
  final st = createMockUIState()
    ..deviceSeen = true
    ..cpuTempC = 61.4
    ..memoryUsagePercent = 48
    ..freeSpacePercent = 28
    ..networkStrength = 'good'
    ..powerDrawW = 6.08
    ..calStatus = 'calibrated'
    ..gearShifter = 'drive';
  return st;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('mockup pixels scale to fit the screen', () {
    expect(shellUnit(const Size(1920, 1000)), 1.0);
    expect(shellUnit(const Size(1920, 1080)), 1.0);  // limited by width
    expect(shellUnit(const Size(1280, 480)), closeTo(0.48, 1e-9));  // limited by height
  });

  test('recording time', () {
    expect(formatRecordingTime(const Duration(seconds: 134)), '2:14');
    expect(formatRecordingTime(const Duration(seconds: 5)), '0:05');
    expect(formatRecordingTime(const Duration(hours: 1, minutes: 2, seconds: 14)), '1:02:14');
  });

  test('status bar figures', () {
    final f = statusBarFigures(_withDevice());
    expect(f.map((e) => e.$1).toList(), ['CPU', 'MEM', 'DISK', 'POWER', 'CALIB', 'GEAR']);
    expect(f.map((e) => e.$2).toList(), ['61°C', '48%', '72%', '6.1 W', '100%', 'D']);
    // nothing from the comma yet: dashes, not zeros
    final none = statusBarFigures(UIState());
    expect(none.take(4).every((e) => e.$2 == '–'), isTrue);
  });

  group('screen', () {
    testWidgets('menu on the left, camera view, status bar underneath', (tester) async {
      _screen(tester, 1920, 1000);
      await tester.pumpWidget(_shell(_withDevice(), AppSettings()));
      final rail = tester.getRect(find.byKey(const ValueKey('menuRail')));
      final camera = tester.getRect(find.byType(AugmentedRoadView));
      final bar = tester.getRect(find.byKey(const ValueKey('statusBar')));
      expect(rail.left, 0);
      expect(rail.width, closeTo(menuRailWidth, 0.01));
      expect(rail.height, 1000);
      expect(camera.left, closeTo(rail.right, 0.01));
      expect(camera.right, 1920);
      expect(bar.top, closeTo(camera.bottom, 0.01));
      expect(bar.height, closeTo(statusBarHeight, 0.01));
      expect(bar.left, closeTo(camera.left, 0.01));
      expect(find.byType(EnhancedLayout), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the menu: logo, then every item, Exit last', (tester) async {
      _screen(tester, 1920, 1000);
      await tester.pumpWidget(_shell(_withDevice(), AppSettings()));
      expect(find.byKey(const ValueKey('menuLogo')), findsOneWidget);
      final tops = [for (final i in MenuItem.values) tester.getRect(find.byKey(ValueKey('menu_${i.name}'))).top];
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i], greaterThan(tops[i - 1]), reason: MenuItem.values[i].name);
      }
      expect(tester.getRect(find.byKey(const ValueKey('menu_exit'))).bottom, greaterThan(1000 * 0.9));
      for (final i in MenuItem.values) {
        expect(find.text(menuItemLabel(i)), findsOneWidget);
      }
    });

    testWidgets('the status bar has the clock and the comma\'s figures', (tester) async {
      _screen(tester, 1920, 1000);
      await tester.pumpWidget(_shell(_withDevice(), AppSettings()));
      final bar = find.byKey(const ValueKey('statusBar'));
      expect(find.descendant(of: bar, matching: find.byType(ClockText)), findsOneWidget);
      for (final t in ['CPU', '61°C', 'MEM', '48%', 'DISK', '72%', 'WI-FI', 'POWER', '6.1 W', 'CALIB', '100%', 'GEAR', 'D']) {
        expect(find.descendant(of: bar, matching: find.text(t)), findsOneWidget, reason: t);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('turning the status bar off gives its space to the camera', (tester) async {
      _screen(tester, 1920, 1000);
      final settings = AppSettings()..hiddenSections.add(DriveSection.statusBar);
      await tester.pumpWidget(_shell(_withDevice(), settings));
      expect(find.byKey(const ValueKey('statusBar')), findsNothing);
      expect(tester.getRect(find.byType(AugmentedRoadView)).bottom, 1000);
    });

    testWidgets('Settings in the menu opens Settings in the camera area; Done goes back', (tester) async {
      _screen(tester, 1920, 1000);
      await tester.pumpWidget(_shell(_withDevice(), AppSettings()));
      await tester.tap(find.byKey(const ValueKey('menu_settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settingsPage')), findsOneWidget);
      expect(tester.widget<MenuRail>(find.byType(MenuRail)).active, MenuItem.settings);
      // beside the menu, above the status bar
      final page = tester.getRect(find.byKey(const ValueKey('settingsPage')));
      expect(page.left, tester.getRect(find.byType(MenuRail)).right);
      expect(page.bottom, tester.getRect(find.byKey(const ValueKey('statusBar'))).top);
      await tester.tap(find.byKey(const ValueKey('settingsDone')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settingsPage')), findsNothing);
      expect(tester.widget<MenuRail>(find.byType(MenuRail)).active, isNull);
    });

    testWidgets('Settings on the connecting screen opens the same page', (tester) async {
      _screen(tester, 1920, 1000);
      await tester.pumpWidget(_shell(UIState(), AppSettings()));
      await tester.tap(find.descendant(of: find.byType(AugmentedRoadView), matching: find.text('Settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settingsPage')), findsOneWidget);
      expect(tester.widget<MenuRail>(find.byType(MenuRail)).active, MenuItem.settings);
    });

    testWidgets('a section switched off in the settings disappears from the screen', (tester) async {
      _screen(tester, 1920, 1000);
      final settings = AppSettings();
      await tester.pumpWidget(_shell(_withDevice(), settings));
      expect(find.byType(EnhancedSteeringPills), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('menu_settings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('section_steering')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('section_steering')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settingsDone')));
      await tester.pumpAndSettle();
      expect(settings.shows(DriveSection.steering), isFalse);
      expect(find.byType(EnhancedSteeringPills), findsNothing);
    });

    testWidgets('Navigate without a connection to send to says so', (tester) async {
      _screen(tester, 1920, 1000);
      await tester.pumpWidget(_shell(_withDevice(), AppSettings()));
      await tester.tap(find.byKey(const ValueKey('menu_navigate')));
      await tester.pump();
      expect(find.text('Navigate is not available'), findsOneWidget);
    });

    group('Record and Gallery', () {
      testWidgets('connected the first time: the explainer, then the buffer; Record runs a clip', (tester) async {
        _screen(tester, 1920, 1000);
        final settings = AppSettings();
        final st = _withDevice()..isConnected = true;
        final platform = FakeRecorderPlatform(dir: null);
        final recorder = Recorder(platform: platform, settings: settings, uiState: st);
        await tester.pumpWidget(_shell(st, settings, recorder: recorder));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('recordExplainer')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('explainerContinue')));
        await tester.pumpAndSettle();
        expect(settings.recordExplained, isTrue);
        expect(platform.calls, contains('start'));
        // the crop is everything right of the menu
        expect(platform.crop, const Rect.fromLTWH(menuRailWidth, 0, 1920 - menuRailWidth, 1000));
        expect(find.text('last 1:00'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('menu_record')));
        await tester.pump();
        await tester.pump();
        expect(recorder.recording, isTrue);
        expect(find.text('of 5:00'), findsOneWidget);
        expect(find.byKey(const ValueKey('recordTime')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        recorder.dispose();
      });

      testWidgets('Not now: no buffer, and Record asks again', (tester) async {
        _screen(tester, 1920, 1000);
        final settings = AppSettings();
        final st = _withDevice()..isConnected = true;
        final platform = FakeRecorderPlatform(dir: null);
        final recorder = Recorder(platform: platform, settings: settings, uiState: st);
        await tester.pumpWidget(_shell(st, settings, recorder: recorder));
        await tester.pump();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('explainerNotNow')));
        await tester.pumpAndSettle();
        expect(platform.calls, isEmpty);
        await tester.tap(find.byKey(const ValueKey('menu_record')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('recordExplainer')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        recorder.dispose();
      });

      testWidgets('Gallery takes the camera area and pauses the recording; tapping it again goes back', (tester) async {
        _screen(tester, 1920, 1000);
        final settings = AppSettings()..recordExplained = true;
        final st = _withDevice()..isConnected = true;
        final platform = FakeRecorderPlatform(dir: null);
        final recorder = Recorder(platform: platform, settings: settings, uiState: st);
        await tester.pumpWidget(_shell(st, settings, recorder: recorder));
        await tester.pumpAndSettle();
        expect(recorder.state, RecordState.buffering);
        await tester.tap(find.byKey(const ValueKey('menu_gallery')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('galleryView')), findsOneWidget);
        expect(platform.paused, isTrue);
        expect(platform.pauseReason, 'Gallery open on the head unit');
        expect(find.byKey(const ValueKey('statusBar')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('menu_gallery')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('galleryView')), findsNothing);
        expect(platform.paused, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        recorder.dispose();
      });

      testWidgets('Navigate takes the camera area, is highlighted, pauses recording; Start goes back', (tester) async {
        _screen(tester, 1920, 1000);
        final settings = AppSettings()..recordExplained = true;
        final st = _withDevice()..isConnected = true;
        final platform = FakeRecorderPlatform(dir: null);
        final recorder = Recorder(platform: platform, settings: settings, uiState: st);
        await tester.pumpWidget(MaterialApp(
          home: ListenableBuilder(
            listenable: settings,
            builder: (context, _) => AppShell(
              uiState: st,
              settings: settings,
              recorder: recorder,
              sendNavDestination: (_) async => true,
            ),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('menu_navigate')));
        await tester.pump();
        expect(find.byKey(const ValueKey('navigateView')), findsOneWidget);
        expect(tester.widget<MenuRail>(find.byType(MenuRail)).active, MenuItem.navigate);
        expect(platform.paused, isTrue);
        expect(platform.pauseReason, 'Navigate open on the head unit');
        // the Gallery replaces it
        await tester.tap(find.byKey(const ValueKey('menu_gallery')));
        await tester.pump();
        expect(find.byKey(const ValueKey('navigateView')), findsNothing);
        expect(find.byKey(const ValueKey('galleryView')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('menu_gallery')));
        await tester.pump();
        expect(platform.paused, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        recorder.dispose();
      });

      testWidgets('Settings pauses the recording too, and says so in the clip; Record goes back to the camera', (tester) async {
        _screen(tester, 1920, 1000);
        final settings = AppSettings()..recordExplained = true;
        final st = _withDevice()..isConnected = true;
        final platform = FakeRecorderPlatform(dir: null);
        final recorder = Recorder(platform: platform, settings: settings, uiState: st);
        await tester.pumpWidget(_shell(st, settings, recorder: recorder));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('menu_settings')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('settingsPage')), findsOneWidget);
        expect(platform.paused, isTrue);
        expect(platform.pauseReason, 'Settings open on the head unit');
        await tester.tap(find.byKey(const ValueKey('menu_record')));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('settingsPage')), findsNothing);
        expect(platform.paused, isFalse);
        expect(recorder.recording, isTrue);
        expect(find.byKey(const ValueKey('recordPaused')), findsNothing);
        expect(find.text('of 5:00'), findsOneWidget);
        // a page opened mid-clip: the rail says the clip is paused, under its time
        await tester.tap(find.byKey(const ValueKey('menu_settings')));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('recordPaused')), findsOneWidget);
        expect(find.text('paused'), findsOneWidget);
        expect(find.text('of 5:00'), findsNothing);
        expect(find.byKey(const ValueKey('recordTime')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('settingsDone')));
        await tester.pump();
        expect(find.byKey(const ValueKey('recordPaused')), findsNothing);
        await tester.pumpWidget(const SizedBox());
        recorder.dispose();
      });

      testWidgets('without a recorder Record says so', (tester) async {
        _screen(tester, 1920, 1000);
        await tester.pumpWidget(_shell(_withDevice(), AppSettings()));
        await tester.tap(find.byKey(const ValueKey('menu_record')));
        await tester.pump();
        expect(find.text('Recording is not available'), findsOneWidget);
      });
    });

    testWidgets('Exit asks first, and Cancel stays', (tester) async {
      _screen(tester, 1920, 1000);
      var exits = 0;
      await tester.pumpWidget(_shell(_withDevice(), AppSettings(), onExit: () => exits++));
      await tester.tap(find.byKey(const ValueKey('menu_exit')));
      await tester.pumpAndSettle();
      expect(find.text('Exit OPRivView?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('exitCancel')));
      await tester.pumpAndSettle();
      expect(exits, 0);
      await tester.tap(find.byKey(const ValueKey('menu_exit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('exitConfirm')));
      await tester.pumpAndSettle();
      expect(exits, 1);
    });

    testWidgets('lays out on every head unit shape without errors', (tester) async {
      for (final (w, h) in const [(1920.0, 1000.0), (1920.0, 1080.0), (1920.0, 720.0), (1280.0, 480.0), (1024.0, 600.0)]) {
        _screen(tester, w, h);
        await tester.pumpWidget(_shell(_withDevice(), AppSettings()));
        expect(tester.takeException(), isNull, reason: '${w}x$h');
      }
    });

    testWidgets('connecting: the camera view says so, the menu and status bar stay', (tester) async {
      _screen(tester, 1920, 1000);
      await tester.pumpWidget(_shell(UIState(), AppSettings()));
      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.byKey(const ValueKey('menuRail')), findsOneWidget);
      expect(find.byKey(const ValueKey('statusBar')), findsOneWidget);
    });
  });
}
