// app settings — viewer-side choices that live on this device, not on the comma
// stored with shared_preferences

import 'package:flutter/foundation.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/system_service.dart' as system;
import 'package:shared_preferences/shared_preferences.dart';

/// clock on the driving display
enum ClockMode { off, system, h12, h24 }

/// speed limit choices, in the order the settings menu offers them
String speedLimitDisplayLabel(SpeedLimitDisplay d) {
  switch (d) {
    case SpeedLimitDisplay.auto:
      return 'Auto';
    case SpeedLimitDisplay.always:
      return 'Always';
    case SpeedLimitDisplay.off:
      return 'Off';
  }
}

/// the parts of the driving screen that can be shown or hidden (Settings > Display)
enum DriveSection { speed, roadName, driver, confidence, steering, lead, torque, statusBar }

/// what each section is called in the settings menu, in the order it lists them
String driveSectionLabel(DriveSection s) {
  switch (s) {
    case DriveSection.speed:
      return 'Speed and MAX';
    case DriveSection.roadName:
      return 'Road name';
    case DriveSection.driver:
      return 'Driver monitoring';
    case DriveSection.confidence:
      return 'Confidence ball';
    case DriveSection.steering:
      return 'Steering details';
    case DriveSection.lead:
      return 'Lead car details';
    case DriveSection.torque:
      return 'Torque bar';
    case DriveSection.statusBar:
      return 'Status bar';
  }
}

const _hiddenSectionsKey = 'hidden_sections';

/// which comma camera to stream: Auto switches to the wide camera at low speed while
/// openpilot controls speed, as the comma's own screen does; the others never switch
enum CameraMode { auto, road, wide }

String cameraModeLabel(CameraMode m) => switch (m) { CameraMode.auto => 'Auto', CameraMode.road => 'Road', CameraMode.wide => 'Wide' };

const _cameraModeKey = 'camera_mode';
const _speedLimitKey = 'speed_limit_display';
const _collapsedKey = 'detailed_collapsed_panels';
const _roadNameKey = 'show_road_name';
const _brightnessKey = 'screen_brightness';

/// the dimmest the brightness slider goes: still readable at night
const minBrightness = 0.05;

class AppSettings extends ChangeNotifier {
  /// the clock is always shown, in 12 hour time; no longer a setting
  ClockMode clockMode = ClockMode.h12;
  SpeedLimitDisplay speedLimitDisplay = SpeedLimitDisplay.auto;
  CameraMode cameraMode = CameraMode.auto;

  /// sections of the driving screen turned off in Settings > Display; everything is on to start
  final Set<DriveSection> hiddenSections = {};

  bool shows(DriveSection s) => !hiddenSections.contains(s);

  /// the road name pill, whatever the comma's own road name setting
  bool get showRoadName => shows(DriveSection.roadName);

  /// this app's screen brightness while it is open, 0.05..1; null follows the head unit
  double? brightness;

  /// the last brightness set by hand, for the slider while Auto is on
  double manualBrightness = 0.6;

  /// Detailed panels the driver has tapped shut, by name
  final Set<String> collapsedPanels = {};

  /// read saved settings; unknown or missing values keep the defaults
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    speedLimitDisplay = _byName(SpeedLimitDisplay.values, prefs.getString(_speedLimitKey), SpeedLimitDisplay.auto);
    cameraMode = _byName(CameraMode.values, prefs.getString(_cameraModeKey), CameraMode.auto);
    hiddenSections.clear();
    final savedHidden = prefs.getStringList(_hiddenSectionsKey);
    if (savedHidden != null) {
      for (final name in savedHidden) {
        for (final s in DriveSection.values) {
          if (s.name == name) hiddenSections.add(s);
        }
      }
    } else if (prefs.getBool(_roadNameKey) == false) {
      // the road name switch of earlier builds
      hiddenSections.add(DriveSection.roadName);
    }
    final savedBrightness = prefs.getDouble(_brightnessKey);
    brightness = savedBrightness == null || savedBrightness < 0 ? null : savedBrightness.clamp(minBrightness, 1.0).toDouble();
    if (savedBrightness != null && savedBrightness >= 0) manualBrightness = brightness!;
    system.setAppBrightness(brightness);
    collapsedPanels
      ..clear()
      ..addAll(prefs.getStringList(_collapsedKey) ?? const []);
    notifyListeners();
  }

  Future<void> setSpeedLimitDisplay(SpeedLimitDisplay value) async {
    if (value == speedLimitDisplay) return;
    speedLimitDisplay = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_speedLimitKey, value.name);
  }

  Future<void> setCameraMode(CameraMode value) async {
    if (value == cameraMode) return;
    cameraMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cameraModeKey, value.name);
  }

  /// [value] null: follow the head unit's brightness (Auto)
  Future<void> setBrightness(double? value) async {
    final v = value?.clamp(minBrightness, 1.0).toDouble();
    if (v == brightness) return;
    brightness = v;
    if (v != null) manualBrightness = v;
    notifyListeners();
    system.setAppBrightness(v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_brightnessKey, v ?? -1);
  }

  /// show or hide one section of the driving screen
  Future<void> setShows(DriveSection section, bool value) async {
    if (value == shows(section)) return;
    value ? hiddenSections.remove(section) : hiddenSections.add(section);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenSectionsKey, [for (final s in DriveSection.values) if (hiddenSections.contains(s)) s.name]);
  }

  Future<void> setShowRoadName(bool value) => setShows(DriveSection.roadName, value);

  /// open a collapsed Detailed panel, or collapse an open one
  Future<void> togglePanel(String name) async {
    if (!collapsedPanels.remove(name)) collapsedPanels.add(name);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_collapsedKey, collapsedPanels.toList()..sort());
  }
}

T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
