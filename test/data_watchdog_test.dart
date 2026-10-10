// telemetry watchdog: flags a stalled data channel, then rebuilds the session

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/data_watchdog.dart';

void main() {
  group('DataWatchdog', () {
    late DateTime now;
    late DataWatchdog w;
    void wait(int ms) => now = now.add(Duration(milliseconds: ms));

    setUp(() {
      now = DateTime(2026, 10, 10, 20);
      w = DataWatchdog(now: () => now);
      w.connected();
    });

    test('quiet while data flows', () {
      for (var i = 0; i < 20; i++) {
        wait(500);
        w.onData();
        expect(w.check(), WatchdogAction.none);
      }
      expect(w.stale, false);
    });

    test('flags stale after 1.5 s, once, then rebuilds at 4 s', () {
      wait(1000);
      expect(w.check(), WatchdogAction.none);
      wait(600);
      expect(w.check(), WatchdogAction.stale);
      expect(w.stale, true);
      wait(500);
      expect(w.check(), WatchdogAction.none);  // already flagged
      wait(1900);
      expect(w.check(), WatchdogAction.restart);
      expect(w.restarts, 1);
    });

    test('rebuilds that bring nothing back wait longer each time, up to 30 s', () {
      final gaps = <int>[];
      for (var i = 0; i < 6; i++) {
        var waited = 0;
        while (w.check() != WatchdogAction.restart) {
          wait(500);
          waited += 500;
        }
        gaps.add(waited);
        w.connected();
      }
      expect(gaps, [4000, 8000, 16000, 30000, 30000, 30000]);
    });

    test('data coming back clears the flag and the backoff', () {
      wait(4000);
      expect(w.check(), WatchdogAction.restart);
      w.connected();
      expect(w.onData(), true);  // ends a stale spell
      expect(w.stale, false);
      expect(w.restarts, 0);
      expect(w.currentRestartAfter, DataWatchdog.restartAfter);
      expect(w.onData(), false);
    });
  });

  testWidgets('the tag shows only while connected and stale', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = UIState()..isConnected = true;
    for (final layout in OnroadLayout.values) {
      final settings = AppSettings()..layout = layout;
      state.dataStale = false;
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: state, settings: settings)));
      expect(find.byKey(const ValueKey('dataPausedTag')), findsNothing);
      state.dataStale = true;
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: state, settings: settings)));
      expect(find.byKey(const ValueKey('dataPausedTag')), findsOneWidget, reason: '$layout');
      expect(tester.takeException(), isNull);
    }
  });
}
