// app settings — viewer-side choices that live on this device, not on the comma
// stored with shared_preferences

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/nav/places.dart';
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
enum DriveSection { speed, roadName, driver, confidence, steering, lead, torque, turnBanner, miniMap, statusBar }

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
    case DriveSection.turnBanner:
      return 'Turn banner (navigating)';
    case DriveSection.miniMap:
      return 'Map (navigating)';
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
const _clockKey = 'clock_mode';
const _keepScreenOnKey = 'keep_screen_on';
const _mapStyleKey = 'map_style';

/// Navigate's map: MapTiler's dark or light street map
enum MapStyle { dark, streets }

String mapStyleLabel(MapStyle s) => switch (s) { MapStyle.dark => 'Dark', MapStyle.streets => 'Streets' };
const _detailsOpenKey = 'details_open';
const _recordBufferKey = 'record_buffer_s';
const _navHomeKey = 'nav_home';
const _navWorkKey = 'nav_work';
const _navRecentsKey = 'nav_recents';
const _storageLimitKey = 'record_storage_gb';
const _recordExplainedKey = 'record_explained';

/// Record's "Keep the last" choices, in seconds (0: off)
const recordBufferChoices = [0, 30, 60, 120];

/// Record's storage limit choices, in GB
const storageLimitChoices = [5, 10, 20];

String recordBufferLabel(int s) => switch (s) { 0 => 'Off', 30 => '30 s', 60 => '1 min', 120 => '2 min', _ => '$s s' };
const _roadNameKey = 'show_road_name';
const _brightnessKey = 'screen_brightness';

/// the dimmest the brightness slider goes: still readable at night
const minBrightness = 0.05;

class AppSettings extends ChangeNotifier {
  /// the clock is always shown, in 12 hour time; no longer a setting
  ClockMode clockMode = ClockMode.h12;

  /// keep the head unit's screen on while connected to the comma
  bool keepScreenOn = true;

  MapStyle mapStyle = MapStyle.dark;
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

  /// the Details view is showing instead of the full camera view (remembered between runs)
  bool detailsOpen = false;

  /// Record keeps this many seconds from before a tap (0: no buffer)
  int recordBufferSeconds = 60;

  /// over this many GB the oldest unstarred clips are removed
  int storageLimitGb = 10;

  /// the Record explainer has been shown and accepted once
  bool recordExplained = false;

  /// Navigate's saved places
  Place? navHome;
  Place? navWork;
  List<Place> navRecents = const [];

  /// read saved settings; unknown or missing values keep the defaults
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    speedLimitDisplay = _byName(SpeedLimitDisplay.values, prefs.getString(_speedLimitKey), SpeedLimitDisplay.auto);
    final clock = _byName(ClockMode.values, prefs.getString(_clockKey), ClockMode.h12);
    clockMode = clock == ClockMode.h24 ? ClockMode.h24 : ClockMode.h12;  // the settings offer these two
    keepScreenOn = prefs.getBool(_keepScreenOnKey) ?? true;
    mapStyle = _byName(MapStyle.values, prefs.getString(_mapStyleKey), MapStyle.dark);
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
    detailsOpen = prefs.getBool(_detailsOpenKey) ?? false;
    final buffer = prefs.getInt(_recordBufferKey);
    recordBufferSeconds = recordBufferChoices.contains(buffer) ? buffer! : 60;
    final limit = prefs.getInt(_storageLimitKey);
    storageLimitGb = storageLimitChoices.contains(limit) ? limit! : 10;
    recordExplained = prefs.getBool(_recordExplainedKey) ?? false;
    navHome = _place(prefs.getString(_navHomeKey));
    navWork = _place(prefs.getString(_navWorkKey));
    navRecents = (prefs.getStringList(_navRecentsKey) ?? const []).map(_place).whereType<Place>().toList();
    notifyListeners();
  }

  Future<void> setSpeedLimitDisplay(SpeedLimitDisplay value) async {
    if (value == speedLimitDisplay) return;
    speedLimitDisplay = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_speedLimitKey, value.name);
  }

  Future<void> setClockMode(ClockMode value) async {
    if (value == clockMode) return;
    clockMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_clockKey, value.name);
  }

  Future<void> setKeepScreenOn(bool value) async {
    if (value == keepScreenOn) return;
    keepScreenOn = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepScreenOnKey, value);
  }

  Future<void> setMapStyle(MapStyle value) async {
    if (value == mapStyle) return;
    mapStyle = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mapStyleKey, value.name);
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

  Future<void> setDetailsOpen(bool value) async {
    if (value == detailsOpen) return;
    detailsOpen = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_detailsOpenKey, value);
  }

  Future<void> setRecordBufferSeconds(int value) async {
    if (value == recordBufferSeconds) return;
    recordBufferSeconds = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_recordBufferKey, value);
  }

  Future<void> setStorageLimitGb(int value) async {
    if (value == storageLimitGb) return;
    storageLimitGb = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_storageLimitKey, value);
  }

  /// [place] null clears it
  Future<void> setNavHome(Place? place) async {
    navHome = place;
    notifyListeners();
    await _savePlace(_navHomeKey, place);
  }

  Future<void> setNavWork(Place? place) async {
    navWork = place;
    notifyListeners();
    await _savePlace(_navWorkKey, place);
  }

  /// a destination was picked: first in the recents
  Future<void> addNavRecent(Place place) async {
    navRecents = addRecent(navRecents, place);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_navRecentsKey, [for (final p in navRecents) jsonEncode(p.toJson())]);
  }

  Future<void> clearNavRecents() async {
    navRecents = const [];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_navRecentsKey);
  }

  Future<void> _savePlace(String key, Place? place) async {
    final prefs = await SharedPreferences.getInstance();
    if (place == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(place.toJson()));
    }
  }

  Future<void> setRecordExplained(bool value) async {
    if (value == recordExplained) return;
    recordExplained = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_recordExplainedKey, value);
  }
}

Place? _place(String? json) {
  if (json == null) return null;
  try {
    return Place.fromJson(jsonDecode(json));
  } catch (_) {
    return null;
  }
}

T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
