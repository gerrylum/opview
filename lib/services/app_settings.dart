// app settings — viewer-side choices that live on this device, not on the comma
// stored with shared_preferences; every default leaves the original display unchanged

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// clock on the driving display
enum ClockMode { off, system, h12, h24 }

String clockModeLabel(ClockMode mode) {
  switch (mode) {
    case ClockMode.off:
      return 'Off';
    case ClockMode.system:
      return 'On (follow this device)';
    case ClockMode.h12:
      return 'On (12 hour)';
    case ClockMode.h24:
      return 'On (24 hour)';
  }
}

const _clockModeKey = 'clock_mode';

class AppSettings extends ChangeNotifier {
  ClockMode clockMode = ClockMode.off;

  /// read saved settings; unknown or missing values keep the defaults
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    clockMode = _byName(ClockMode.values, prefs.getString(_clockModeKey), ClockMode.off);
    notifyListeners();
  }

  Future<void> setClockMode(ClockMode mode) async {
    if (mode == clockMode) return;
    clockMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_clockModeKey, mode.name);
  }
}

T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
