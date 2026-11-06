// Settings over the whole screen, for when the menu column is not there to open it as a page:
// the connecting screen before the comma is found, and tests. The same SettingsPage as the
// menu's Settings (settings_page.dart)

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/settings/settings_page.dart';
import 'package:opview/selfdrive/ui/shell/app_shell.dart' show shellUnit;
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/nav/places.dart';
import 'package:opview/services/recorder/recorder.dart';
import 'package:opview/services/updater.dart';

/// [host] is the comma's address, if known, and [hostIsManual] whether it was typed
/// in; [onChangeHost] opens the address prompt. [build] names the installed build
Future<void> showSettingsDialog(
  BuildContext context,
  AppSettings settings, {
  UIState? uiState,
  String? host,
  bool hostIsManual = false,
  VoidCallback? onChangeHost,
  VoidCallback? onReconnect,
  String? build,
  Updater? updater,
  Recorder? recorder,
  SettingsCategory initial = SettingsCategory.drivingView,
  Future<String?> Function(String key)? checkMapKey,
  Future<List<Place>> Function(String query)? findPlaces,
}) {
  final state = uiState ?? UIState();
  return showDialog<void>(
    context: context,
    useSafeArea: false,
    builder: (dialogContext) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: SettingsPage(
            settings: settings,
            uiState: state,
            unit: shellUnit(constraints.biggest),
            updater: updater ?? appUpdater,
            recorder: recorder,
            host: host,
            hostIsManual: hostIsManual,
            onChangeHost: onChangeHost == null
                ? null
                : () {
                    Navigator.of(dialogContext).pop();
                    onChangeHost();
                  },
            onReconnect: onReconnect,
            checkMapKey: checkMapKey,
            findPlaces: findPlaces,
            build: build,
            initial: initial,
            onDone: () => Navigator.of(dialogContext).pop(),
          ),
        ),
      ),
    ),
  );
}
