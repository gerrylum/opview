// app settings — viewer-side choices that live on this device, not on the comma
// stored with shared_preferences; every default leaves the original display unchanged

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// clock on the driving display
enum ClockMode { off, system, h12, h24 }

/// short names for the settings menu; Auto follows this device's own 12/24 hour setting
String clockModeLabel(ClockMode mode) {
  switch (mode) {
    case ClockMode.off:
      return 'Off';
    case ClockMode.h12:
      return '12 hour';
    case ClockMode.h24:
      return '24 hour';
    case ClockMode.system:
      return 'Auto';
  }
}

/// the order the clock choices are offered in
const clockModeChoices = [ClockMode.off, ClockMode.h12, ClockMode.h24, ClockMode.system];

/// which driving display to draw
enum OnroadLayout { classic, enhanced, detailed }

String onroadLayoutLabel(OnroadLayout layout) {
  switch (layout) {
    case OnroadLayout.classic:
      return 'Classic';
    case OnroadLayout.enhanced:
      return 'Enhanced';
    case OnroadLayout.detailed:
      return 'Detailed';
  }
}

/// what the Enhanced layout was saved as before it was renamed
const _legacyLayoutNames = {'miciExtended': OnroadLayout.enhanced};

const _clockModeKey = 'clock_mode';
const _layoutKey = 'onroad_layout';

class AppSettings extends ChangeNotifier {
  ClockMode clockMode = ClockMode.off;
  OnroadLayout layout = OnroadLayout.classic;

  /// read saved settings; unknown or missing values keep the defaults
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    clockMode = _byName(ClockMode.values, prefs.getString(_clockModeKey), ClockMode.off);
    final savedLayout = prefs.getString(_layoutKey);
    layout = _legacyLayoutNames[savedLayout] ?? _byName(OnroadLayout.values, savedLayout, OnroadLayout.classic);
    notifyListeners();
  }

  Future<void> setClockMode(ClockMode mode) async {
    if (mode == clockMode) return;
    clockMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_clockModeKey, mode.name);
  }

  Future<void> setLayout(OnroadLayout value) async {
    if (value == layout) return;
    layout = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_layoutKey, value.name);
  }
}

T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
