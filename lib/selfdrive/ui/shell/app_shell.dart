// the app's one screen: the menu column on the left, the camera view (augmented road
// view) in the middle, and the status bar along the bottom under it
//
// laid out from the redesign mockup, a 1920x1000 screen; `unit` scales its pixels

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/shell/menu_rail.dart';
import 'package:opview/selfdrive/ui/shell/status_bar.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';

const shellRefWidth = 1920.0;
const shellRefHeight = 1000.0;

/// mockup pixel size on a screen of [size]
double shellUnit(Size size) => min(size.width / shellRefWidth, size.height / shellRefHeight);

class AppShell extends StatelessWidget {
  final UIState uiState;
  final AppSettings settings;
  final RTCVideoRenderer? videoRenderer;
  final Future<String?> Function()? loadManualHost;
  final Future<void> Function(String? host)? onSetManualHost;
  final String? Function()? currentHost;

  /// leaves the app; replaceable in tests
  final VoidCallback? onExit;

  const AppShell({
    super.key,
    required this.uiState,
    required this.settings,
    this.videoRenderer,
    this.loadManualHost,
    this.onSetManualHost,
    this.currentHost,
    this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, constraints) {
        final unit = shellUnit(constraints.biggest);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MenuRail(unit: unit, onSelect: (item) => _onMenu(context, item)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: AugmentedRoadView(
                        uiState: uiState,
                        videoRenderer: videoRenderer,
                        loadManualHost: loadManualHost,
                        onSetManualHost: onSetManualHost,
                        currentHost: currentHost,
                        settings: settings,
                      ),
                    ),
                    if (settings.shows(DriveSection.statusBar))
                      StatusBar(uiState: uiState, clockMode: settings.clockMode, unit: unit),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  void _onMenu(BuildContext context, MenuItem item) {
    switch (item) {
      case MenuItem.settings:
        openSettingsMenu(context, settings,
            loadManualHost: loadManualHost, onSetManualHost: onSetManualHost, currentHost: currentHost);
      case MenuItem.exit:
        _confirmExit(context);
      case MenuItem.navigate:
      case MenuItem.details:
      case MenuItem.record:
      case MenuItem.gallery:
        // not built yet: the redesign adds these one at a time
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('${menuItemLabel(item)} is coming in a later build'),
            duration: const Duration(seconds: 2),
          ));
    }
  }

  Future<void> _confirmExit(BuildContext context) async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16171A),
        title: const Text('Exit OPRivView?'),
        content: const Text('The stream from the comma stops. openpilot keeps driving on the comma as usual.'),
        actions: [
          TextButton(
            key: const ValueKey('exitCancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('exitConfirm'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC92231)),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    if (leave != true) return;
    final exit = onExit;
    if (exit != null) {
      exit();
    } else {
      SystemNavigator.pop();
    }
  }
}
