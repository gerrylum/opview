// the Details screen: four cards of the comma's figures, the camera in a small window

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/details/details_view.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/pip_layout.dart';
import 'package:opview/selfdrive/ui/shell/app_shell.dart';
import 'package:opview/selfdrive/ui/shell/menu_rail.dart';
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

Widget _shell(UIState state, AppSettings settings) => MaterialApp(
      home: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => AppShell(uiState: state, settings: settings),
      ),
    );

Widget _details(UIState state) => MaterialApp(
      home: AugmentedRoadView(uiState: state, settings: AppSettings(), details: true),
    );

const _cards = ['STEERING', 'LONGITUDINAL', 'LEAD', 'DRIVER & ROAD'];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the angle scale runs -45° to +45° and stops at the ends', () {
    expect(SteeringAngleScalePainter.xFor(0, 400), 200);
    expect(SteeringAngleScalePainter.xFor(-45, 400), 0);
    expect(SteeringAngleScalePainter.xFor(45, 400), 400);
    expect(SteeringAngleScalePainter.xFor(90, 400), 400);
    expect(SteeringAngleScalePainter.xFor(-22.5, 400), 100);
  });

  test('the gap bar runs 0 to 3 s', () {
    expect(FollowingGapPainter.xFor(0, 300), 0);
    expect(FollowingGapPainter.xFor(1.5, 300), 150);
    expect(FollowingGapPainter.xFor(5, 300), 300);
  });

  test('unit fits the camera area', () {
    expect(detailsUnit(const Size(detailsRefWidth, detailsRefHeight)), 1.0);
    expect(detailsUnit(const Size(885, 916)), closeTo(0.5, 1e-9));
  });

  group('screen', () {
    for (final (w, h) in const [(1920.0, 1000.0), (1920.0, 1080.0), (1920.0, 720.0), (1280.0, 480.0), (1024.0, 600.0)]) {
      testWidgets('four cards and the camera window at ${w.toInt()}x${h.toInt()}', (tester) async {
        _screen(tester, w, h);
        await tester.pumpWidget(_details(createMockUIState()));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('detailsView')), findsOneWidget);
        for (final c in _cards) {
          expect(find.byKey(ValueKey('detailsCard_$c')), findsOneWidget, reason: c);
        }
        final camera = find.byKey(const ValueKey('detailsCamera'));
        expect(find.descendant(of: camera, matching: find.byType(PipLayout)), findsOneWidget);
        expect(find.byType(EnhancedLayout), findsNothing);
      });
    }

    testWidgets('the camera window is 16:9, top right', (tester) async {
      _screen(tester, 1770, 916);
      await tester.pumpWidget(_details(createMockUIState()));
      final cam = tester.getRect(find.byKey(const ValueKey('detailsCamera')));
      expect(cam.width / cam.height, closeTo(16 / 9, 0.01));
      expect(cam.right, closeTo(1770 - 20, 0.5));
      expect(cam.top, closeTo(20, 0.5));
    });

    testWidgets('no lead: dashes in the lead card', (tester) async {
      _screen(tester, 1920, 1000);
      await tester.pumpWidget(_details(createMockUIState(engaged: false)));
      final lead = find.byKey(const ValueKey('detailsCard_LEAD'));
      expect(find.descendant(of: lead, matching: find.text(enhancedNoLeadValue)), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing from the comma yet still lays out', (tester) async {
      _screen(tester, 1920, 1000);
      await tester.pumpWidget(_details(UIState()));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('detailsView')), findsOneWidget);
      expect(find.text('Connecting…'), findsWidgets);
    });
  });

  group('from the menu', () {
    testWidgets('Details opens, is highlighted, and a second tap goes back', (tester) async {
      _screen(tester, 1920, 1000);
      final settings = AppSettings();
      await tester.pumpWidget(_shell(createMockUIState(), settings));
      expect(find.byType(EnhancedLayout), findsOneWidget);
      expect(tester.widget<MenuRail>(find.byType(MenuRail)).active, isNull);

      await tester.tap(find.byKey(const ValueKey('menu_details')));
      await tester.pump();
      expect(settings.detailsOpen, isTrue);
      expect(find.byType(DetailsView), findsOneWidget);
      expect(find.byType(EnhancedLayout), findsNothing);
      expect(tester.widget<MenuRail>(find.byType(MenuRail)).active, MenuItem.details);
      // the menu and the status bar stay
      expect(find.byKey(const ValueKey('statusBar')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('menu_details')));
      await tester.pump();
      expect(settings.detailsOpen, isFalse);
      expect(find.byType(DetailsView), findsNothing);
      expect(find.byType(EnhancedLayout), findsOneWidget);
    });

    testWidgets('opens where it was left', (tester) async {
      _screen(tester, 1920, 1000);
      final first = AppSettings();
      await first.setDetailsOpen(true);
      final settings = AppSettings();
      await settings.load();
      await tester.pumpWidget(_shell(createMockUIState(), settings));
      expect(find.byType(DetailsView), findsOneWidget);
    });
  });
}
